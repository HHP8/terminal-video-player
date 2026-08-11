use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::Result;
use crossbeam_channel::{Receiver, TryRecvError};

use super::clock::WallClock;
use super::scheduler::{is_due, is_late};
use crate::audio::{AUDIO_CHANNELS, AUDIO_SAMPLE_RATE, AudioDevice, AudioOutput};
use crate::cli::Cli;
use crate::media::{
    DecoderErrorTail, FfmpegPaths, ImageSource, ProbeInfo, ProcessWorker, VideoEvent, VideoPipe,
    bounded_dimensions, is_probably_image, load_image_source, probe, spawn_audio, spawn_video,
};
use crate::platform::windows::Job;
use crate::render::{AnsiRenderer, ColorCapability, DisplayMode, RgbFrame, sample_cells_with_mode};
use crate::terminal::{InputEvent, TerminalSession, poll_event};
use unicode_width::UnicodeWidthChar;

const MAX_DECODE_WIDTH: u32 = 640;
const MAX_DECODE_HEIGHT: u32 = 360;
const EVENT_POLL: Duration = Duration::from_millis(4);
const AUDIO_PREBUFFER_TIMEOUT: Duration = Duration::from_secs(2);
const AUDIO_PREBUFFER_CHUNKS: usize = 2;
const LOCAL_VIDEO_FRAMES: usize = 3;

struct PlaybackRenderer {
    ansi: AnsiRenderer,
    display_mode: DisplayMode,
}

impl PlaybackRenderer {
    fn reset(&mut self) {
        self.ansi.reset();
    }
}

pub enum PreparedMedia {
    Image(ImageSource),
    Video {
        input: PathBuf,
        paths: FfmpegPaths,
        info: ProbeInfo,
    },
}

impl PreparedMedia {
    pub fn is_video(&self) -> bool {
        matches!(self, Self::Video { .. })
    }
}

pub fn prepare(input: &Path, cli: &Cli) -> Result<PreparedMedia> {
    if is_probably_image(input) {
        return Ok(PreparedMedia::Image(load_image_source(input)?));
    }

    let paths = FfmpegPaths::resolve(cli.ffmpeg_dir.as_deref())?;
    paths.validate_runtime()?;
    let info = probe(&paths, input)?;
    if info.width == 0 || info.height == 0 {
        anyhow::bail!("ffprobe reported invalid video dimensions");
    }
    Ok(PreparedMedia::Video {
        input: input.to_path_buf(),
        paths,
        info,
    })
}

pub fn play(
    media: PreparedMedia,
    cli: &Cli,
    display_mode: DisplayMode,
    cancelled: &Arc<AtomicBool>,
    terminal: &mut TerminalSession,
) -> Result<()> {
    let color = ColorCapability::resolve(cli.color);
    let mut renderer = PlaybackRenderer {
        ansi: AnsiRenderer::new(cli.renderer.into(), color),
        display_mode,
    };
    match media {
        PreparedMedia::Image(source) => play_image(source, cli, cancelled, terminal, &mut renderer),
        PreparedMedia::Video { input, paths, info } => play_video(
            &input,
            &paths,
            &info,
            cli,
            cancelled,
            terminal,
            &mut renderer,
        ),
    }
}

fn play_image(
    source: ImageSource,
    cli: &Cli,
    cancelled: &AtomicBool,
    terminal: &mut TerminalSession,
    renderer: &mut PlaybackRenderer,
) -> Result<()> {
    match source {
        ImageSource::Still(frame) => {
            let mut dirty = true;
            while !cancelled.load(Ordering::Relaxed) {
                if dirty {
                    render(
                        terminal,
                        renderer,
                        &frame,
                        cli.cell_aspect,
                        "still image  q/Esc quit",
                    )?;
                    dirty = false;
                }
                match poll_event(Duration::from_millis(50))? {
                    InputEvent::Quit => break,
                    InputEvent::Resize(_, _) => {
                        renderer.reset();
                        dirty = true;
                    }
                    _ => {}
                }
            }
        }
        ImageSource::Gif(frames) => {
            let total = frames
                .last()
                .map(|frame| frame.frame.pts.saturating_add(frame.delay))
                .unwrap_or_default();
            let mut clock = WallClock::new(Duration::ZERO);
            let mut last_index = None;
            let mut dirty = true;
            while !cancelled.load(Ordering::Relaxed) {
                let mut position = clock.position();
                if position >= total {
                    if cli.r#loop {
                        clock.seek(Duration::ZERO);
                        position = Duration::ZERO;
                        last_index = None;
                    } else {
                        break;
                    }
                }
                let index = frames
                    .partition_point(|frame| frame.frame.pts <= position)
                    .saturating_sub(1)
                    .min(frames.len() - 1);
                if last_index != Some(index) || dirty {
                    render(
                        terminal,
                        renderer,
                        &frames[index].frame,
                        cli.cell_aspect,
                        &format!(
                            "GIF  {}  {}  q/Esc quit",
                            format_position(position, Some(total)),
                            if clock.is_paused() {
                                "paused"
                            } else {
                                "playing"
                            }
                        ),
                    )?;
                    last_index = Some(index);
                    dirty = false;
                }
                match poll_event(EVENT_POLL)? {
                    InputEvent::Quit => break,
                    InputEvent::TogglePause => {
                        clock.set_paused(!clock.is_paused());
                        dirty = true;
                    }
                    InputEvent::SeekRelative(seconds) => {
                        clock.seek(relative_seek(position, seconds, Some(total)));
                        dirty = true;
                    }
                    InputEvent::Resize(_, _) => {
                        renderer.reset();
                        dirty = true;
                    }
                    _ => {}
                }
            }
        }
    }
    Ok(())
}

fn play_video(
    input: &Path,
    paths: &FfmpegPaths,
    info: &ProbeInfo,
    cli: &Cli,
    cancelled: &AtomicBool,
    terminal: &mut TerminalSession,
    renderer: &mut PlaybackRenderer,
) -> Result<()> {
    let fps = cli
        .fps
        .map(f64::from)
        .unwrap_or(info.frame_rate.clamp(1.0, 30.0));
    let (width, height) =
        bounded_dimensions(info.width, info.height, MAX_DECODE_WIDTH, MAX_DECODE_HEIGHT);
    let frame_interval = Duration::from_secs_f64(1.0 / fps);
    let audio_enabled = info.has_audio && !cli.no_audio;

    let mut generation_id = 0_u64;
    let mut target = Duration::ZERO;
    let mut paused = false;
    let mut muted = cli.start_muted;
    let mut dropped = 0_u64;

    'restart: loop {
        let mut generation = DecoderGeneration::start(
            paths,
            input,
            info,
            target,
            fps,
            width,
            height,
            generation_id,
            audio_enabled,
            paused,
            muted,
            cancelled,
        )?;
        let mut frames = VecDeque::with_capacity(LOCAL_VIDEO_FRAMES);
        let mut last_frame = None;
        let mut ended = false;
        let mut decoder_error = None;
        let mut dirty = true;
        let mut redraw_last = false;

        while !cancelled.load(Ordering::Relaxed) {
            let position = generation.position();
            drain_video_events(
                &generation.video.events,
                generation_id,
                &mut frames,
                &mut ended,
                &mut decoder_error,
            );

            while frames.len() > 1
                && frames
                    .front()
                    .is_some_and(|frame| is_late(frame.pts, position, frame_interval))
            {
                frames.pop_front();
                dropped += 1;
            }

            if frames
                .front()
                .is_some_and(|frame| is_due(frame.pts, position, frame_interval))
            {
                let frame = frames.pop_front().expect("front frame exists");
                render(
                    terminal,
                    renderer,
                    &frame,
                    cli.cell_aspect,
                    &format!(
                        "{}  {}  dropped {}  {}{}",
                        codec_label(info),
                        format_position(position, info.duration),
                        dropped,
                        if paused { "paused" } else { "playing" },
                        if muted { " muted" } else { "" }
                    ),
                )?;
                last_frame = Some(frame);
                dirty = false;
                redraw_last = false;
            } else if redraw_last && last_frame.is_some() {
                let frame = last_frame.as_ref().expect("last frame exists");
                render(
                    terminal,
                    renderer,
                    frame,
                    cli.cell_aspect,
                    &format!(
                        "{}  {}  dropped {}  {}{}",
                        codec_label(info),
                        format_position(position, info.duration),
                        dropped,
                        if paused { "paused" } else { "playing" },
                        if muted { " muted" } else { "" }
                    ),
                )?;
                dirty = false;
                redraw_last = false;
            } else if dirty {
                let status = format!(
                    "{}  {}  {}{}",
                    codec_label(info),
                    format_position(position, info.duration),
                    if paused { "paused" } else { "buffering" },
                    if muted { " muted" } else { "" }
                );
                write_status(terminal, &status)?;
                dirty = false;
            }

            if let Some(error) = generation.audio_error() {
                generation.stop();
                anyhow::bail!(
                    "audio output failed: {error}. Reconnect the device or retry with --no-audio"
                );
            }
            if generation.audio_decoder_failed() {
                let details = generation.decoder_details();
                generation.stop();
                anyhow::bail!("audio decoder failed{details}");
            }
            if let Some(error) = decoder_error.take() {
                let details = generation.decoder_details();
                generation.stop();
                anyhow::bail!("{error}{details}");
            }
            if ended && frames.is_empty() {
                generation.stop();
                if cli.r#loop {
                    target = Duration::ZERO;
                    generation_id = generation_id.wrapping_add(1);
                    renderer.reset();
                    continue 'restart;
                }
                return Ok(());
            }

            match poll_event(EVENT_POLL)? {
                InputEvent::None => {}
                InputEvent::Quit => {
                    generation.stop();
                    return Ok(());
                }
                InputEvent::TogglePause => {
                    paused = !paused;
                    generation.set_paused(paused)?;
                    dirty = true;
                }
                InputEvent::ToggleMute => {
                    muted = !muted;
                    generation.set_muted(muted);
                    dirty = true;
                }
                InputEvent::SeekRelative(seconds) => {
                    target = relative_seek(position, seconds, info.duration);
                    generation.stop();
                    generation_id = generation_id.wrapping_add(1);
                    renderer.reset();
                    continue 'restart;
                }
                InputEvent::Resize(_, _) => {
                    renderer.reset();
                    dirty = true;
                    redraw_last = true;
                }
                InputEvent::Confirm
                | InputEvent::SelectDisplayMode(_)
                | InputEvent::InvalidSelection => {}
            }
        }
        generation.stop();
        return Ok(());
    }
}

fn drain_video_events(
    events: &Receiver<VideoEvent>,
    generation: u64,
    frames: &mut VecDeque<crate::render::RgbFrame>,
    ended: &mut bool,
    decoder_error: &mut Option<String>,
) {
    while frames.len() < LOCAL_VIDEO_FRAMES {
        match events.try_recv() {
            Ok(VideoEvent::Frame(frame)) if frame.generation == generation => {
                frames.push_back(frame);
            }
            Ok(VideoEvent::Frame(_)) => {}
            Ok(VideoEvent::End) => {
                *ended = true;
                break;
            }
            Ok(VideoEvent::Error(error)) => {
                *decoder_error = Some(error);
                break;
            }
            Err(TryRecvError::Empty) => break,
            Err(TryRecvError::Disconnected) if *ended => break,
            Err(TryRecvError::Disconnected) => {
                *decoder_error = Some("video decoder worker disconnected unexpectedly".to_owned());
                break;
            }
        }
    }
}

struct DecoderGeneration {
    local_cancelled: Arc<AtomicBool>,
    job: Job,
    video: VideoPipe,
    video_worker: ProcessWorker,
    audio_worker: Option<ProcessWorker>,
    audio_done: Option<Arc<AtomicBool>>,
    audio_failed: Option<Arc<AtomicBool>>,
    audio_errors: Option<DecoderErrorTail>,
    audio: Option<AudioOutput>,
    wall_clock: WallClock,
    audio_exhausted: bool,
}

impl DecoderGeneration {
    #[allow(clippy::too_many_arguments)]
    fn start(
        paths: &FfmpegPaths,
        input: &Path,
        info: &ProbeInfo,
        start: Duration,
        fps: f64,
        width: u32,
        height: u32,
        generation: u64,
        audio_enabled: bool,
        initially_paused: bool,
        initially_muted: bool,
        externally_cancelled: &AtomicBool,
    ) -> Result<Self> {
        let audio_device = if audio_enabled && info.has_audio {
            Some(AudioDevice::open()?)
        } else {
            None
        };
        let local_cancelled = Arc::new(AtomicBool::new(false));
        let mut job = Job::new()?;
        let (video, mut video_worker) = spawn_video(
            paths,
            input,
            start,
            fps,
            width,
            height,
            generation,
            &job,
            Arc::clone(&local_cancelled),
        )?;

        let mut audio_worker = None;
        let mut audio_done = None;
        let mut audio_failed = None;
        let mut audio_errors = None;
        let mut audio = None;
        if let Some(device) = audio_device {
            let (pipe, mut worker) = match spawn_audio(
                paths,
                input,
                start,
                AUDIO_SAMPLE_RATE,
                AUDIO_CHANNELS,
                &job,
                Arc::clone(&local_cancelled),
            ) {
                Ok(started) => started,
                Err(error) => {
                    local_cancelled.store(true, Ordering::Release);
                    job.terminate();
                    video_worker.join();
                    return Err(error);
                }
            };
            let deadline = Instant::now() + AUDIO_PREBUFFER_TIMEOUT;
            while pipe.samples.len() < AUDIO_PREBUFFER_CHUNKS
                && !pipe.done.load(Ordering::Acquire)
                && !externally_cancelled.load(Ordering::Relaxed)
                && Instant::now() < deadline
            {
                thread::sleep(Duration::from_millis(5));
            }
            audio_done = Some(Arc::clone(&pipe.done));
            audio_failed = Some(Arc::clone(&pipe.failed));
            audio_errors = Some(pipe.errors.clone());
            audio = match device.start(pipe.samples, start, initially_paused, initially_muted) {
                Ok(output) => Some(output),
                Err(error) => {
                    local_cancelled.store(true, Ordering::Release);
                    job.terminate();
                    video_worker.join();
                    worker.join();
                    return Err(error);
                }
            };
            audio_worker = Some(worker);
        }

        Ok(Self {
            local_cancelled,
            job,
            video,
            video_worker,
            audio_worker,
            audio_done,
            audio_failed,
            audio_errors,
            audio,
            wall_clock: WallClock::new(start),
            audio_exhausted: false,
        })
    }

    fn position(&mut self) -> Duration {
        if let Some(audio) = &self.audio {
            if !self.audio_exhausted && audio.is_drained() {
                let position = audio.position();
                self.wall_clock.seek(position);
                self.wall_clock.set_paused(audio.is_paused());
                self.audio_exhausted = true;
            }
            if !self.audio_exhausted {
                return audio.position();
            }
        }
        self.wall_clock.position()
    }

    fn set_paused(&mut self, paused: bool) -> Result<()> {
        if let Some(audio) = &self.audio {
            audio.set_paused(paused)?;
        }
        self.wall_clock.set_paused(paused);
        Ok(())
    }

    fn set_muted(&self, muted: bool) {
        if let Some(audio) = &self.audio {
            audio.set_muted(muted);
        }
    }

    fn audio_error(&self) -> Option<String> {
        self.audio.as_ref()?.take_error()
    }

    fn audio_decoder_failed(&self) -> bool {
        self.audio_done
            .as_ref()
            .is_some_and(|done| done.load(Ordering::Acquire))
            && self
                .audio_failed
                .as_ref()
                .is_some_and(|failed| failed.load(Ordering::Acquire))
    }

    fn decoder_details(&self) -> String {
        let mut lines = self.video.errors.lines();
        if let Some(errors) = &self.audio_errors {
            lines.extend(errors.lines());
        }
        if lines.is_empty() {
            String::new()
        } else {
            format!("\nFFmpeg diagnostics:\n{}", lines.join("\n"))
        }
    }

    fn stop(&mut self) {
        self.local_cancelled.store(true, Ordering::Release);
        self.audio.take();
        self.job.terminate();
        self.video_worker.join();
        if let Some(worker) = &mut self.audio_worker {
            worker.join();
        }
        self.audio_worker = None;
        let _ = self.audio_done.take();
        let _ = self.audio_failed.take();
    }
}

impl Drop for DecoderGeneration {
    fn drop(&mut self) {
        self.stop();
    }
}

fn render(
    terminal: &mut TerminalSession,
    renderer: &mut PlaybackRenderer,
    frame: &RgbFrame,
    cell_aspect: f64,
    status: &str,
) -> Result<()> {
    let (columns, rows) = terminal.size()?;
    let image_rows = rows.saturating_sub(1).max(1);
    let grid = sample_cells_with_mode(
        frame,
        columns.max(1),
        image_rows,
        cell_aspect,
        renderer.display_mode,
    );
    let mut bytes = renderer.ansi.encode(&grid);
    append_status(&mut bytes, rows, columns, status);
    terminal.write_frame(&bytes)
}

fn write_status(terminal: &mut TerminalSession, status: &str) -> Result<()> {
    let (columns, rows) = terminal.size()?;
    let mut bytes = Vec::new();
    append_status(&mut bytes, rows, columns, status);
    terminal.write_frame(&bytes)
}

fn append_status(bytes: &mut Vec<u8>, row: u16, columns: u16, status: &str) {
    bytes.extend_from_slice(format!("\x1b[{};1H\x1b[0m\x1b[2K", row.max(1)).as_bytes());
    let mut width = 0_usize;
    let visible = status
        .chars()
        .take_while(|character| {
            let character_width = character.width().unwrap_or(0);
            if width + character_width > columns as usize {
                false
            } else {
                width += character_width;
                true
            }
        })
        .collect::<String>();
    bytes.extend_from_slice(visible.as_bytes());
}

fn relative_seek(current: Duration, seconds: i64, duration: Option<Duration>) -> Duration {
    let sought = if seconds >= 0 {
        current.saturating_add(Duration::from_secs(seconds as u64))
    } else {
        current.saturating_sub(Duration::from_secs(seconds.unsigned_abs()))
    };
    duration.map_or(sought, |end| sought.min(end))
}

fn codec_label(info: &ProbeInfo) -> String {
    match (&info.video_codec, &info.audio_codec) {
        (Some(video), Some(audio)) => format!("{video}/{audio}"),
        (Some(video), None) => video.clone(),
        _ => "video".to_owned(),
    }
}

fn format_position(position: Duration, duration: Option<Duration>) -> String {
    match duration {
        Some(duration) => format!(
            "{}/{}",
            format_duration(position.min(duration)),
            format_duration(duration)
        ),
        None => format_duration(position),
    }
}

fn format_duration(duration: Duration) -> String {
    let seconds = duration.as_secs();
    format!("{:02}:{:02}", seconds / 60, seconds % 60)
}

#[cfg(test)]
mod tests {
    use crossbeam_channel::unbounded;

    use super::*;

    #[test]
    fn relative_seek_saturates_and_clamps() {
        assert_eq!(
            relative_seek(Duration::from_secs(2), -5, Some(Duration::from_secs(9))),
            Duration::ZERO
        );
        assert_eq!(
            relative_seek(Duration::from_secs(8), 5, Some(Duration::from_secs(9))),
            Duration::from_secs(9)
        );
    }

    #[test]
    fn unicode_status_is_truncated_on_character_boundaries() {
        let mut output = Vec::new();
        append_status(&mut output, 20, 3, "\u{67e}\u{62e}\u{634} media");
        assert!(output.starts_with(b"\x1b[20;1H\x1b[0m\x1b[2K"));
        assert!(std::str::from_utf8(&output).is_ok());
    }

    #[test]
    fn decoder_drain_never_unbounds_the_local_frame_queue() {
        let (sender, receiver) = unbounded();
        for index in 0..10 {
            sender
                .send(VideoEvent::Frame(crate::render::RgbFrame {
                    generation: 4,
                    index,
                    pts: Duration::from_millis(index),
                    width: 1,
                    height: 1,
                    rgb: vec![0, 0, 0].into_boxed_slice(),
                }))
                .unwrap();
        }
        let mut frames = VecDeque::new();
        let mut ended = false;
        let mut error = None;
        drain_video_events(&receiver, 4, &mut frames, &mut ended, &mut error);
        assert_eq!(frames.len(), LOCAL_VIDEO_FRAMES);
        assert_eq!(receiver.len(), 10 - LOCAL_VIDEO_FRAMES);
        assert!(!ended);
        assert!(error.is_none());
    }
}
