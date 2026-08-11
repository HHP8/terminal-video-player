use std::time::{Duration, Instant};

#[derive(Debug)]
pub struct WallClock {
    base: Duration,
    started: Instant,
    paused_at: Option<Duration>,
}

impl WallClock {
    pub fn new(base: Duration) -> Self {
        Self {
            base,
            started: Instant::now(),
            paused_at: None,
        }
    }

    pub fn position(&self) -> Duration {
        self.paused_at
            .unwrap_or_else(|| self.base.saturating_add(self.started.elapsed()))
    }

    pub fn set_paused(&mut self, paused: bool) {
        match (paused, self.paused_at) {
            (true, None) => self.paused_at = Some(self.position()),
            (false, Some(position)) => {
                self.base = position;
                self.started = Instant::now();
                self.paused_at = None;
            }
            _ => {}
        }
    }

    pub fn is_paused(&self) -> bool {
        self.paused_at.is_some()
    }

    pub fn seek(&mut self, position: Duration) {
        self.base = position;
        self.started = Instant::now();
        if self.paused_at.is_some() {
            self.paused_at = Some(position);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seek_while_paused_updates_frozen_position() {
        let mut clock = WallClock::new(Duration::ZERO);
        clock.set_paused(true);
        clock.seek(Duration::from_secs(7));
        assert_eq!(clock.position(), Duration::from_secs(7));
        clock.set_paused(false);
        assert!(clock.position() >= Duration::from_secs(7));
    }
}
