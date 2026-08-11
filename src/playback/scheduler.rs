use std::time::Duration;

pub fn is_due(frame_pts: Duration, clock: Duration, frame_interval: Duration) -> bool {
    frame_pts <= clock.saturating_add(frame_interval.div_f64(2.0))
}

pub fn is_late(frame_pts: Duration, clock: Duration, frame_interval: Duration) -> bool {
    frame_pts.saturating_add(frame_interval.mul_f64(1.5)) < clock
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn due_window_allows_half_a_frame_of_lead() {
        let interval = Duration::from_millis(40);
        assert!(is_due(
            Duration::from_millis(1_020),
            Duration::from_secs(1),
            interval
        ));
        assert!(!is_due(
            Duration::from_millis(1_021),
            Duration::from_secs(1),
            interval
        ));
    }

    #[test]
    fn late_window_is_one_and_a_half_frames() {
        let interval = Duration::from_millis(40);
        assert!(is_late(
            Duration::from_millis(939),
            Duration::from_secs(1),
            interval
        ));
        assert!(!is_late(
            Duration::from_millis(940),
            Duration::from_secs(1),
            interval
        ));
    }
}
