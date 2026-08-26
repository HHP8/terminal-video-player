use std::collections::VecDeque;
use std::io::{self, BufRead, BufReader, Read};
use std::mem::size_of;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use anyhow::{Context, Result};
use crossbeam_channel::{Receiver, SendTimeoutError, bounded};

use super::FfmpegPaths;
use crate::platform::windows::{Job, configure_hidden};
use crate::render::RgbFrame;

const STDERR_LINES: usize = 32;
const VIDEO_QUEUE: usize = 2;
const AUDIO_QUEUE: usize = 8;
const AUDIO_CHUNK_BYTES: usize = 16 * 1024;

#[derive(Debug)]
pub enum VideoEvent {
    Frame(RgbFrame),
    End,
    Error(String),
}

#[derive(Debug)]
pub struct AudioPipe {
    pub samples: Receiver<Box<[i16]>>,
    pub done: Arc<AtomicBool>,
    pub failed: Arc<AtomicBool>,
    pub errors: DecoderErrorTail,
}

#[derive(Debug)]
pub struct VideoPipe {
    pub events: Receiver<VideoEvent>,
    pub errors: DecoderErrorTail,
}

#[derive(Debug, Clone, Default)]
pub struct DecoderErrorTail(Arc<Mutex<VecDeque<String>>>);

impl DecoderErrorTail {
    pub fn lines(&self) -> Vec<String> {
        self.0
            .lock()
            .map(|lines| lines.iter().cloned().collect())
            .unwrap_or_default()
    }

    fn push(&self, line: String) {
        let Ok(mut lines) = self.0.lock() else {
            return;
        };
        if lines.len() == STDERR_LINES {
            lines.pop_front();
        }
        lines.push_back(line);
    }
}

#[derive(Debug)]
pub struct ProcessWorker {
    join: Option<JoinHandle<()>>,
}

struct AudioWorkerCompletion {
    done: Arc<AtomicBool>,
    failed: Arc<AtomicBool>,
    errors: DecoderErrorTail,
}

impl Drop for AudioWorkerCompletion {
    fn drop(&mut self) {
        if thread::panicking() {
            self.errors
                .push("audio decoder worker panicked unexpectedly".to_owned());
            self.failed.store(true, Ordering::Release);
        }
        self.done.store(true, Ordering::Release);
    }
}

impl ProcessWorker {
    pub fn join(&mut self) {
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

impl Drop for ProcessWorker {
    fn drop(&mut self) {
        self.join();
    }
}

pub fn build_video_command(
    paths: &FfmpegPaths,
    media: &Path,
    start: Duration,
    fps: f64,
    width: u32,
    height: u32,
) -> Command {
    let mut command = Command::new(&paths.ffmpeg);
    command
        .arg("-hide_banner")
        .arg("-loglevel")
        .arg("warning")
        .arg("-nostdin")
        .arg("-ss")
        .arg(format_seconds(start))
        .arg("-protocol_whitelist")
        .arg("file,pipe")
        .arg("-i")
        .arg(media)
        .arg("-map")
        .arg("0:v:0")
        .arg("-an")
        .arg("-sn")
        .arg("-dn")
        .arg("-vf")
        .arg(format!(
            "fps={fps:.6},scale={width}:{height}:flags=fast_bilinear,setpts=PTS-STARTPTS"
        ))
        .arg("-pix_fmt")
        .arg("rgb24")
        .arg("-f")
        .arg("rawvideo")
        .arg("pipe:1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    configure_hidden(&mut command);
    command
}

pub fn build_audio_command(
    paths: &FfmpegPaths,
    media: &Path,
    start: Duration,
    sample_rate: u32,
    channels: u16,
) -> Command {
    let mut command = Command::new(&paths.ffmpeg);
    command
        .arg("-hide_banner")
        .arg("-loglevel")
        .arg("warning")
        .arg("-nostdin")
        .arg("-ss")
        .arg(format_seconds(start))
        .arg("-protocol_whitelist")
        .arg("file,pipe")
        .arg("-i")
        .arg(media)
        .arg("-map")
        .arg("0:a:0")
        .arg("-vn")
        .arg("-sn")
        .arg("-dn")
        .arg("-ac")
        .arg(channels.to_string())
        .arg("-ar")
        .arg(sample_rate.to_string())
        .arg("-acodec")
        .arg("pcm_s16le")
        .arg("-f")
        .arg("s16le")
        .arg("pipe:1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    configure_hidden(&mut command);
    command
}

#[allow(clippy::too_many_arguments)]
pub fn spawn_video(
    paths: &FfmpegPaths,
    media: &Path,
    start: Duration,
    fps: f64,
    width: u32,
    height: u32,
    generation: u64,
    job: &Job,
    cancelled: Arc<AtomicBool>,
) -> Result<(VideoPipe, ProcessWorker)> {
    let mut child = build_video_command(paths, media, start, fps, width, height)
        .spawn()
        .with_context(|| format!("starting video decoder for {}", media.display()))?;
    job.assign(&mut child)?;
    let stdout = child
        .stdout
        .take()
        .context("video decoder stdout missing")?;
    let stderr = child
        .stderr
        .take()
        .context("video decoder stderr missing")?;
    let errors = DecoderErrorTail::default();
    let error_reader = spawn_error_reader(stderr, errors.clone());
    let (sender, receiver) = bounded(VIDEO_QUEUE);
    let frame_bytes = width as usize * height as usize * 3;
    let errors_for_worker = errors.clone();

    let join = thread::Builder::new()
        .name("ffmpeg-video".to_owned())
        .spawn(move || {
            let mut stdout = BufReader::new(stdout);
            let mut buffer = vec![0u8; frame_bytes];
            let mut index = 0u64;
            let mut terminal_event = None;
            loop {
                if cancelled.load(Ordering::Relaxed) {
                    break;
                }
                match read_exact_frame(&mut stdout, &mut buffer) {
                    Ok(false) => {
                        terminal_event = Some(VideoEvent::End);
                        break;
                    }
                    Ok(true) => {
                        let frame = RgbFrame {
                            generation,
                            index,
                            pts: start + Duration::from_secs_f64(index as f64 / fps),
                            width,
                            height,
                            rgb: buffer.clone().into_boxed_slice(),
                        };
                        let mut pending = VideoEvent::Frame(frame);
                        loop {
                            match sender.send_timeout(pending, Duration::from_millis(25)) {
                                Ok(()) => break,
                                Err(SendTimeoutError::Timeout(returned))
                                    if !cancelled.load(Ordering::Relaxed) =>
                                {
                                    pending = returned;
                                }
                                Err(_) => return,
                            }
                        }
                        index += 1;
                    }
                    Err(error) => {
                        let message = format!("video pipe failed: {error}");
                        errors_for_worker.push(message.clone());
                        terminal_event = Some(VideoEvent::Error(message));
                        break;
                    }
                }
            }
            let status = child.wait();
            let _ = error_reader.join();
            if !cancelled.load(Ordering::Relaxed) {
                let event = match status {
                    Ok(status) if status.success() => terminal_event.unwrap_or(VideoEvent::End),
                    Ok(status) => {
                        let message = format!("video decoder exited with {status}");
                        errors_for_worker.push(message.clone());
                        VideoEvent::Error(message)
                    }
                    Err(error) => {
                        let message = format!("waiting for video decoder failed: {error}");
                        errors_for_worker.push(message.clone());
                        VideoEvent::Error(message)
                    }
                };
                let mut pending = event;
                loop {
                    match sender.send_timeout(pending, Duration::from_millis(25)) {
                        Ok(()) => break,
                        Err(SendTimeoutError::Timeout(returned))
                            if !cancelled.load(Ordering::Relaxed) =>
                        {
                            pending = returned;
                        }
                        Err(_) => break,
                    }
                }
            }
        })
        .context("spawning video reader thread")?;

    Ok((
        VideoPipe {
            events: receiver,
            errors,
        },
        ProcessWorker { join: Some(join) },
    ))
}

#[allow(clippy::too_many_arguments)]
pub fn spawn_audio(
    paths: &FfmpegPaths,
    media: &Path,
    start: Duration,
    sample_rate: u32,
    channels: u16,
    job: &Job,
    cancelled: Arc<AtomicBool>,
) -> Result<(AudioPipe, ProcessWorker)> {
    let mut child = build_audio_command(paths, media, start, sample_rate, channels)
        .spawn()
        .with_context(|| format!("starting audio decoder for {}", media.display()))?;
    job.assign(&mut child)?;
    let mut stdout = child
        .stdout
        .take()
        .context("audio decoder stdout missing")?;
    let stderr = child
        .stderr
        .take()
        .context("audio decoder stderr missing")?;
    let errors = DecoderErrorTail::default();
    let error_reader = spawn_error_reader(stderr, errors.clone());
    let (sender, receiver) = bounded(AUDIO_QUEUE);
    let done = Arc::new(AtomicBool::new(false));
    let done_for_worker = Arc::clone(&done);
    let failed = Arc::new(AtomicBool::new(false));
    let failed_for_worker = Arc::clone(&failed);
    let errors_for_worker = errors.clone();

    let join = thread::Builder::new()
        .name("ffmpeg-audio".to_owned())
        .spawn(move || {
            let _completion = AudioWorkerCompletion {
                done: Arc::clone(&done_for_worker),
                failed: Arc::clone(&failed_for_worker),
                errors: errors_for_worker.clone(),
            };
            let mut bytes = vec![0u8; AUDIO_CHUNK_BYTES];
            let mut carry = Vec::with_capacity(usize::from(channels) * 2);
            loop {
                if cancelled.load(Ordering::Relaxed) {
                    break;
                }
                let read = match stdout.read(&mut bytes) {
                    Ok(0) => break,
                    Ok(read) => read,
                    Err(error) => {
                        errors_for_worker.push(format!("audio pipe failed: {error}"));
                        failed_for_worker.store(true, Ordering::Release);
                        break;
                    }
                };
                let samples = pcm_bytes_to_samples(&bytes[..read], &mut carry, channels);
                if samples.is_empty() {
                    continue;
                }
                let mut pending = samples.into_boxed_slice();
                loop {
                    match sender.send_timeout(pending, Duration::from_millis(25)) {
                        Ok(()) => break,
                        Err(SendTimeoutError::Timeout(returned))
                            if !cancelled.load(Ordering::Relaxed) =>
                        {
                            pending = returned;
                        }
                        Err(_) => {
                            return;
                        }
                    }
                }
            }
            if !cancelled.load(Ordering::Relaxed) && !carry.is_empty() {
                errors_for_worker.push(format!(
                    "audio pipe ended with {} bytes of an incomplete PCM frame",
                    carry.len()
                ));
                failed_for_worker.store(true, Ordering::Release);
            }
            match child.wait() {
                Ok(status) if !status.success() && !cancelled.load(Ordering::Relaxed) => {
                    errors_for_worker.push(format!("audio decoder exited with {status}"));
                    failed_for_worker.store(true, Ordering::Release);
                }
                Err(error) if !cancelled.load(Ordering::Relaxed) => {
                    errors_for_worker.push(format!("waiting for audio decoder failed: {error}"));
                    failed_for_worker.store(true, Ordering::Release);
                }
                _ => {}
            }
            let _ = error_reader.join();
        })
        .context("spawning audio reader thread")?;

    Ok((
        AudioPipe {
            samples: receiver,
            done,
            failed,
            errors,
        },
        ProcessWorker { join: Some(join) },
    ))
}

pub fn read_exact_frame<R: Read>(reader: &mut R, buffer: &mut [u8]) -> io::Result<bool> {
    let mut offset = 0usize;
    while offset < buffer.len() {
        match reader.read(&mut buffer[offset..]) {
            Ok(0) if offset == 0 => return Ok(false),
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    format!(
                        "truncated raw frame: received {offset} of {} bytes",
                        buffer.len()
                    ),
                ));
            }
            Ok(read) => offset += read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(true)
}

fn pcm_bytes_to_samples(bytes: &[u8], carry: &mut Vec<u8>, channels: u16) -> Vec<i16> {
    carry.extend_from_slice(bytes);
    let bytes_per_frame = usize::from(channels.max(1)) * size_of::<i16>();
    let complete_bytes = carry.len() - carry.len() % bytes_per_frame;
    let samples = carry[..complete_bytes]
        .chunks_exact(2)
        .map(|sample| i16::from_le_bytes([sample[0], sample[1]]))
        .collect();
    carry.drain(..complete_bytes);
    samples
}

fn spawn_error_reader(
    stderr: impl Read + Send + 'static,
    errors: DecoderErrorTail,
) -> JoinHandle<()> {
    thread::spawn(move || {
        for line in BufReader::new(stderr).lines() {
            match line {
                Ok(line) if !line.trim().is_empty() => errors.push(line),
                Ok(_) => {}
                Err(error) => {
                    errors.push(format!("reading decoder stderr failed: {error}"));
                    break;
                }
            }
        }
    })
}

fn format_seconds(duration: Duration) -> String {
    format!("{:.6}", duration.as_secs_f64())
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;
    use std::io::Cursor;

    use super::*;

    #[test]
    fn exact_frame_distinguishes_eof_and_truncation() {
        let mut buffer = [0u8; 4];
        assert!(!read_exact_frame(&mut Cursor::new(Vec::<u8>::new()), &mut buffer).unwrap());
        assert!(read_exact_frame(&mut Cursor::new(vec![1, 2, 3, 4]), &mut buffer).unwrap());
        let error = read_exact_frame(&mut Cursor::new(vec![1, 2]), &mut buffer).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::UnexpectedEof);
    }

    #[test]
    fn pcm_conversion_preserves_stereo_frame_alignment() {
        let mut carry = Vec::new();
        assert_eq!(
            pcm_bytes_to_samples(&[1, 0, 2], &mut carry, 2),
            Vec::<i16>::new()
        );
        assert_eq!(carry, vec![1, 0, 2]);
        assert_eq!(pcm_bytes_to_samples(&[0], &mut carry, 2), vec![1, 2]);
        assert!(carry.is_empty());
        assert_eq!(
            pcm_bytes_to_samples(&[3, 0, 4, 0, 5], &mut carry, 2),
            vec![3, 4]
        );
        assert_eq!(carry, vec![5]);
    }

    #[test]
    fn command_keeps_unicode_path_as_one_argument() {
        let directory = Path::new("C:\\bundle");
        let paths = FfmpegPaths {
            directory: directory.to_path_buf(),
            ffmpeg: directory.join("ffmpeg.exe"),
            ffprobe: directory.join("ffprobe.exe"),
        };
        let media = Path::new(
            "C:\\\u{648}\u{6cc}\u{62f}\u{6cc}\u{648} \u{647}\u{627}\u{6cc} \u{645}\u{646}\\\u{646}\u{645}\u{648}\u{646}\u{647} \u{641}\u{6cc}\u{644}\u{645}.mp4",
        );
        let command = build_video_command(&paths, media, Duration::ZERO, 30.0, 640, 360);
        let expected = OsString::from(media);
        assert!(command.get_args().any(|argument| argument == expected));
    }

    #[test]
    fn decoder_commands_restrict_nested_input_protocols() {
        let directory = Path::new("C:\\ffmpeg");
        let paths = FfmpegPaths {
            directory: directory.to_path_buf(),
            ffmpeg: directory.join("ffmpeg.exe"),
            ffprobe: directory.join("ffprobe.exe"),
        };
        let media = Path::new("movie.mp4");

        for command in [
            build_video_command(&paths, media, Duration::ZERO, 30.0, 640, 360),
            build_audio_command(&paths, media, Duration::ZERO, 48_000, 2),
        ] {
            let arguments = command.get_args().map(OsString::from).collect::<Vec<_>>();
            let expected = [
                OsString::from("-protocol_whitelist"),
                OsString::from("file,pipe"),
                OsString::from("-i"),
                OsString::from(media),
            ];
            assert!(
                arguments
                    .windows(expected.len())
                    .any(|window| window == expected),
                "decoder input is missing the local-only protocol policy: {arguments:?}"
            );
        }
    }
}
