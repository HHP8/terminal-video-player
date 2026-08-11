use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

#[derive(Debug)]
pub(crate) struct AudioClockState {
    base_micros: AtomicU64,
    consumed_frames: AtomicU64,
    anchor_media_frame: AtomicU64,
    anchor_valid_frames: AtomicU64,
    anchor_playback_nanos: AtomicU64,
    anchor_sequence: AtomicU64,
    anchor_valid: AtomicBool,
    paused: AtomicBool,
    paused_frame: AtomicU64,
    muted: AtomicBool,
    underruns: AtomicU64,
}

#[derive(Debug, Clone, Copy)]
pub struct AudioClockSnapshot {
    pub position: Duration,
    pub consumed_frames: u64,
    pub underruns: u64,
    pub paused: bool,
    pub muted: bool,
}

impl AudioClockState {
    pub(crate) fn new(base: Duration) -> Self {
        Self {
            base_micros: AtomicU64::new(duration_to_micros(base)),
            consumed_frames: AtomicU64::new(0),
            anchor_media_frame: AtomicU64::new(0),
            anchor_valid_frames: AtomicU64::new(0),
            anchor_playback_nanos: AtomicU64::new(0),
            anchor_sequence: AtomicU64::new(0),
            anchor_valid: AtomicBool::new(false),
            paused: AtomicBool::new(false),
            paused_frame: AtomicU64::new(0),
            muted: AtomicBool::new(false),
            underruns: AtomicU64::new(0),
        }
    }

    pub(crate) fn begin_callback(&self) -> u64 {
        self.consumed_frames.load(Ordering::Acquire)
    }

    pub(crate) fn finish_callback(
        &self,
        start_frame: u64,
        consumed_frames: u64,
        playback_nanos: u64,
        requested_frames: u64,
    ) {
        if self.paused.load(Ordering::Acquire) {
            return;
        }
        if consumed_frames < requested_frames {
            self.underruns.fetch_add(1, Ordering::Relaxed);
        }
        self.anchor_sequence.fetch_add(1, Ordering::AcqRel);
        self.consumed_frames.store(
            start_frame.saturating_add(consumed_frames),
            Ordering::Release,
        );
        self.anchor_media_frame
            .store(start_frame, Ordering::Relaxed);
        self.anchor_valid_frames
            .store(consumed_frames, Ordering::Relaxed);
        self.anchor_playback_nanos
            .store(playback_nanos, Ordering::Relaxed);
        self.anchor_valid.store(true, Ordering::Release);
        self.anchor_sequence.fetch_add(1, Ordering::Release);
    }

    pub(crate) fn set_paused(&self, paused: bool, now_nanos: u64, sample_rate: u32) {
        if paused {
            let frame = self.position_frames(now_nanos, sample_rate);
            self.paused_frame.store(frame, Ordering::Release);
            self.paused.store(true, Ordering::Release);
        } else {
            self.paused.store(false, Ordering::Release);
            self.anchor_valid.store(false, Ordering::Release);
        }
    }

    pub(crate) fn is_paused(&self) -> bool {
        self.paused.load(Ordering::Acquire)
    }

    pub(crate) fn set_muted(&self, muted: bool) {
        self.muted.store(muted, Ordering::Release);
    }

    pub(crate) fn is_muted(&self) -> bool {
        self.muted.load(Ordering::Acquire)
    }

    pub(crate) fn snapshot(&self, now_nanos: u64, sample_rate: u32) -> AudioClockSnapshot {
        let frame = self.position_frames(now_nanos, sample_rate);
        let base = Duration::from_micros(self.base_micros.load(Ordering::Acquire));
        AudioClockSnapshot {
            position: base.saturating_add(frames_to_duration(frame, sample_rate)),
            consumed_frames: self.consumed_frames.load(Ordering::Acquire),
            underruns: self.underruns.load(Ordering::Relaxed),
            paused: self.is_paused(),
            muted: self.is_muted(),
        }
    }

    fn position_frames(&self, now_nanos: u64, sample_rate: u32) -> u64 {
        if self.is_paused() {
            return self.paused_frame.load(Ordering::Acquire);
        }
        if !self.anchor_valid.load(Ordering::Acquire) {
            return self.paused_frame.load(Ordering::Acquire);
        }

        for _ in 0..8 {
            let before = self.anchor_sequence.load(Ordering::Acquire);
            if !before.is_multiple_of(2) {
                std::hint::spin_loop();
                continue;
            }
            let start = self.anchor_media_frame.load(Ordering::Relaxed);
            let valid = self.anchor_valid_frames.load(Ordering::Relaxed);
            let playback = self.anchor_playback_nanos.load(Ordering::Relaxed);
            let after = self.anchor_sequence.load(Ordering::Acquire);
            if before == after {
                return if now_nanos >= playback {
                    let elapsed = nanos_to_frames(now_nanos - playback, sample_rate).min(valid);
                    start.saturating_add(elapsed)
                } else {
                    let scheduled_ahead = nanos_to_frames(playback - now_nanos, sample_rate);
                    start.saturating_sub(scheduled_ahead)
                };
            }
        }
        self.consumed_frames.load(Ordering::Acquire)
    }
}

fn nanos_to_frames(nanos: u64, sample_rate: u32) -> u64 {
    ((nanos as u128 * u128::from(sample_rate)) / 1_000_000_000) as u64
}

fn frames_to_duration(frames: u64, sample_rate: u32) -> Duration {
    if sample_rate == 0 {
        return Duration::ZERO;
    }
    Duration::from_secs_f64(frames as f64 / f64::from(sample_rate))
}

fn duration_to_micros(duration: Duration) -> u64 {
    duration.as_micros().min(u128::from(u64::MAX)) as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn playback_timestamp_delays_the_audio_clock() {
        let clock = AudioClockState::new(Duration::from_secs(5));
        clock.finish_callback(0, 480, 1_000_000_000, 480);
        assert_eq!(
            clock.snapshot(995_000_000, 48_000).position,
            Duration::from_secs(5)
        );
        assert_eq!(
            clock.snapshot(1_005_000_000, 48_000).position,
            Duration::from_millis(5_005)
        );
        assert_eq!(
            clock.snapshot(2_000_000_000, 48_000).position,
            Duration::from_millis(5_010)
        );
    }

    #[test]
    fn pausing_freezes_the_position() {
        let clock = AudioClockState::new(Duration::ZERO);
        clock.finish_callback(0, 4_800, 1_000_000_000, 4_800);
        clock.set_paused(true, 1_050_000_000, 48_000);
        assert_eq!(
            clock.snapshot(3_000_000_000, 48_000).position,
            Duration::from_millis(50)
        );
    }

    #[test]
    fn resuming_waits_for_a_fresh_playback_anchor() {
        let clock = AudioClockState::new(Duration::ZERO);
        clock.finish_callback(0, 4_800, 1_000_000_000, 4_800);
        clock.set_paused(true, 1_050_000_000, 48_000);
        clock.set_paused(false, 2_000_000_000, 48_000);
        assert_eq!(
            clock.snapshot(2_010_000_000, 48_000).position,
            Duration::from_millis(50)
        );
    }
}
