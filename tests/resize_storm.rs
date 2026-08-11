use std::time::Duration;

use terminal_video_player::render::{
    AnsiRenderer, ColorCapability, DisplayMode, RenderStrategy, RgbFrame, sample_cells_with_mode,
};

#[test]
fn repeated_resize_rebuilds_valid_bounded_frames() {
    let frame = RgbFrame {
        generation: 0,
        index: 0,
        pts: Duration::ZERO,
        width: 640,
        height: 360,
        rgb: vec![127; 640 * 360 * 3].into_boxed_slice(),
    };
    for display_mode in DisplayMode::ALL {
        let mut renderer = AnsiRenderer::new(RenderStrategy::Adaptive, ColorCapability::Truecolor);
        for index in 0..2_000_u16 {
            let columns = 40 + index % 161;
            let rows = 12 + index.wrapping_mul(7) % 49;
            let grid = sample_cells_with_mode(&frame, columns, rows, 2.0, display_mode);
            assert!(grid.width <= columns);
            assert!(grid.height <= rows);
            assert_eq!(
                grid.cells.len(),
                usize::from(grid.width) * usize::from(grid.height)
            );
            let encoded = renderer.encode(&grid);
            assert!(!encoded.is_empty());
        }
    }
}
