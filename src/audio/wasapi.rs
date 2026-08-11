use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Device, OutputCallbackInfo, SampleFormat, Stream, SupportedStreamConfig};
use crossbeam_channel::{Receiver, TryRecvError};

use super::clock::{AudioClockSnapshot, AudioClockState};
use crate::error::AppError;

pub const AUDIO_SAMPLE_RATE: u32 = 48_000;
pub const AUDIO_CHANNELS: u16 = 2;

pub struct AudioDevice {
    device: Device,
    config: SupportedStreamConfig,
}

pub struct AudioOutput {
    stream: Stream,
    clock: Arc<AudioClockState>,
    sample_rate: u32,
    error: Arc<Mutex<Option<String>>>,
    drained: Arc<AtomicBool>,
}

impl AudioDevice {
    pub fn open() -> Result<Self> {
        let host = cpal::default_host();
        let device = host.default_output_device().ok_or_else(|| {
            AppError::AudioUnavailable(
                "Windows has no default output device. Connect or enable one, or retry with --no-audio."
                    .to_owned(),
            )
        })?;
        let configs = device
            .supported_output_configs()
            .context("querying WASAPI output formats")?;

        let mut compatible = configs
            .filter(|range| {
                range.channels() == AUDIO_CHANNELS
                    && matches!(
                        range.sample_format(),
                        SampleFormat::F32 | SampleFormat::I16 | SampleFormat::U16
                    )
            })
            .filter_map(|range| range.try_with_sample_rate(AUDIO_SAMPLE_RATE))
            .collect::<Vec<_>>();
        compatible.sort_by_key(|config| sample_format_rank(config.sample_format()));
        let config = compatible.into_iter().next().ok_or_else(|| {
            AppError::AudioUnavailable(
                "the default device does not expose 48 kHz stereo PCM as f32, i16, or u16. Retry with --no-audio."
                    .to_owned(),
            )
        })?;

        Ok(Self { device, config })
    }

    pub fn start(
        self,
        samples: Receiver<Box<[i16]>>,
        base: Duration,
        initially_paused: bool,
        initially_muted: bool,
    ) -> Result<AudioOutput> {
        let clock = Arc::new(AudioClockState::new(base));
        clock.set_muted(initially_muted);
        let error = Arc::new(Mutex::new(None));
        let drained = Arc::new(AtomicBool::new(false));
        let consumer = AudioConsumer::new(samples);
        let stream_config = self.config.config();
        let sample_format = self.config.sample_format();
        let callback_clock = Arc::clone(&clock);
        let callback_error = Arc::clone(&error);
        let callback_drained = Arc::clone(&drained);

        let stream = match sample_format {
            SampleFormat::I16 => {
                let mut consumer = consumer;
                self.device.build_output_stream(
                    stream_config,
                    move |output: &mut [i16], info| {
                        write_output(
                            output,
                            info,
                            &mut consumer,
                            &callback_clock,
                            &callback_drained,
                            0_i16,
                            |sample| sample,
                        )
                    },
                    move |stream_error| store_stream_error(&callback_error, stream_error),
                    None,
                )
            }
            SampleFormat::F32 => {
                let mut consumer = consumer;
                self.device.build_output_stream(
                    stream_config,
                    move |output: &mut [f32], info| {
                        write_output(
                            output,
                            info,
                            &mut consumer,
                            &callback_clock,
                            &callback_drained,
                            0.0_f32,
                            |sample| f32::from(sample) / 32_768.0,
                        )
                    },
                    move |stream_error| store_stream_error(&callback_error, stream_error),
                    None,
                )
            }
            SampleFormat::U16 => {
                let mut consumer = consumer;
                self.device.build_output_stream(
                    stream_config,
                    move |output: &mut [u16], info| {
                        write_output(
                            output,
                            info,
                            &mut consumer,
                            &callback_clock,
                            &callback_drained,
                            32_768_u16,
                            |sample| (i32::from(sample) + 32_768) as u16,
                        )
                    },
                    move |stream_error| store_stream_error(&callback_error, stream_error),
                    None,
                )
            }
            unsupported => {
                return Err(AppError::AudioUnavailable(format!(
                    "unsupported negotiated WASAPI sample format {unsupported}; retry with --no-audio"
                ))
                .into());
            }
        }
        .context("opening the WASAPI output stream")?;
        if initially_paused {
            let now = stream.now().as_nanos().min(u128::from(u64::MAX)) as u64;
            clock.set_paused(true, now, AUDIO_SAMPLE_RATE);
        } else {
            stream.play().context("starting WASAPI audio playback")?;
        }

        Ok(AudioOutput {
            stream,
            clock,
            sample_rate: AUDIO_SAMPLE_RATE,
            error,
            drained,
        })
    }
}

impl AudioOutput {
    pub fn snapshot(&self) -> AudioClockSnapshot {
        let now = self.stream.now().as_nanos().min(u128::from(u64::MAX)) as u64;
        self.clock.snapshot(now, self.sample_rate)
    }

    pub fn position(&self) -> Duration {
        self.snapshot().position
    }

    pub fn set_paused(&self, paused: bool) -> Result<()> {
        if paused {
            self.stream.pause().context("pausing WASAPI output")?;
            let now = self.stream.now().as_nanos().min(u128::from(u64::MAX)) as u64;
            self.clock.set_paused(true, now, self.sample_rate);
            Ok(())
        } else {
            let now = self.stream.now().as_nanos().min(u128::from(u64::MAX)) as u64;
            self.clock.set_paused(false, now, self.sample_rate);
            if let Err(error) = self.stream.play().context("resuming WASAPI output") {
                let now = self.stream.now().as_nanos().min(u128::from(u64::MAX)) as u64;
                self.clock.set_paused(true, now, self.sample_rate);
                return Err(error);
            }
            Ok(())
        }
    }

    pub fn is_paused(&self) -> bool {
        self.clock.is_paused()
    }

    pub fn set_muted(&self, muted: bool) {
        self.clock.set_muted(muted);
    }

    pub fn is_muted(&self) -> bool {
        self.clock.is_muted()
    }

    pub fn take_error(&self) -> Option<String> {
        self.error.lock().ok()?.take()
    }

    pub fn is_drained(&self) -> bool {
        self.drained.load(Ordering::Acquire)
    }
}

fn sample_format_rank(format: SampleFormat) -> u8 {
    match format {
        SampleFormat::F32 => 0,
        SampleFormat::I16 => 1,
        SampleFormat::U16 => 2,
        _ => 3,
    }
}

fn store_stream_error(error: &Mutex<Option<String>>, stream_error: cpal::Error) {
    if let Ok(mut slot) = error.lock() {
        *slot = Some(stream_error.to_string());
    }
}

fn write_output<T: Copy>(
    output: &mut [T],
    info: &OutputCallbackInfo,
    consumer: &mut AudioConsumer,
    clock: &AudioClockState,
    drained: &AtomicBool,
    silence: T,
    convert: impl Fn(i16) -> T,
) {
    output.fill(silence);
    if clock.is_paused() {
        return;
    }

    let muted = clock.is_muted();
    let start = clock.begin_callback();
    let requested_frames = output.len() / usize::from(AUDIO_CHANNELS);
    let mut consumed = 0_u64;
    for frame in output.chunks_exact_mut(usize::from(AUDIO_CHANNELS)) {
        let Some([left, right]) = consumer.next_frame() else {
            break;
        };
        if !muted {
            frame[0] = convert(left);
            frame[1] = convert(right);
        }
        consumed += 1;
    }
    let playback_nanos = info
        .timestamp()
        .playback
        .as_nanos()
        .min(u128::from(u64::MAX)) as u64;
    clock.finish_callback(start, consumed, playback_nanos, requested_frames as u64);
    if consumed < requested_frames as u64 && consumer.disconnected {
        drained.store(true, Ordering::Release);
    }
}

struct AudioConsumer {
    receiver: Receiver<Box<[i16]>>,
    current: Option<Box<[i16]>>,
    cursor: usize,
    disconnected: bool,
}

impl AudioConsumer {
    fn new(receiver: Receiver<Box<[i16]>>) -> Self {
        Self {
            receiver,
            current: None,
            cursor: 0,
            disconnected: false,
        }
    }

    fn next_frame(&mut self) -> Option<[i16; 2]> {
        loop {
            if let Some(current) = self.current.as_ref()
                && self.cursor + 1 < current.len()
            {
                let frame = [current[self.cursor], current[self.cursor + 1]];
                self.cursor += 2;
                return Some(frame);
            }
            match self.receiver.try_recv() {
                Ok(next) => {
                    self.current = Some(next);
                    self.cursor = 0;
                }
                Err(TryRecvError::Empty) => return None,
                Err(TryRecvError::Disconnected) => {
                    self.disconnected = true;
                    return None;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use crossbeam_channel::bounded;

    use super::*;

    #[test]
    fn consumer_crosses_chunk_boundaries_without_reordering() {
        let (sender, receiver) = bounded(2);
        sender.send(vec![-1, 1].into_boxed_slice()).unwrap();
        sender.send(vec![-2, 2, -3, 3].into_boxed_slice()).unwrap();
        drop(sender);
        let mut consumer = AudioConsumer::new(receiver);
        assert_eq!(consumer.next_frame(), Some([-1, 1]));
        assert_eq!(consumer.next_frame(), Some([-2, 2]));
        assert_eq!(consumer.next_frame(), Some([-3, 3]));
        assert_eq!(consumer.next_frame(), None);
        assert!(consumer.disconnected);
    }
}
