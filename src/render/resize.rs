use std::time::Duration;

use super::{DisplayMode, Glyph, bt709_luma};

#[derive(Debug, Clone)]
pub struct RgbFrame {
    pub generation: u64,
    pub index: u64,
    pub pts: Duration,
    pub width: u32,
    pub height: u32,
    pub rgb: Box<[u8]>,
}

impl RgbFrame {
    pub fn validate(&self) -> bool {
        let expected = self.width as usize * self.height as usize * 3;
        self.width > 0 && self.height > 0 && self.rgb.len() == expected
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cell {
    pub glyph: Glyph,
    pub foreground: [u8; 3],
    pub background: Option<[u8; 3]>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CellGrid {
    pub width: u16,
    pub height: u16,
    pub paired_colors: bool,
    pub cells: Vec<Cell>,
}

impl CellGrid {
    pub fn row(&self, row: u16) -> &[Cell] {
        let start = row as usize * self.width as usize;
        &self.cells[start..start + self.width as usize]
    }
}

pub fn fit_grid(
    source_width: u32,
    source_height: u32,
    max_columns: u16,
    max_rows: u16,
    cell_aspect: f64,
) -> (u16, u16) {
    if source_width == 0 || source_height == 0 || max_columns == 0 || max_rows == 0 {
        return (0, 0);
    }

    let source_aspect = source_width as f64 / source_height as f64;
    let max_display_aspect = max_columns as f64 / (max_rows as f64 * cell_aspect);

    let (columns, rows) = if source_aspect >= max_display_aspect {
        let columns = f64::from(max_columns);
        let rows = (columns / (source_aspect * cell_aspect)).round();
        (columns, rows)
    } else {
        let rows = f64::from(max_rows);
        let columns = (source_aspect * rows * cell_aspect).round();
        (columns, rows)
    };

    (
        columns.clamp(1.0, max_columns as f64) as u16,
        rows.clamp(1.0, max_rows as f64) as u16,
    )
}

pub fn sample_cells(
    frame: &RgbFrame,
    max_columns: u16,
    max_rows: u16,
    cell_aspect: f64,
) -> CellGrid {
    sample_cells_with_mode(
        frame,
        max_columns,
        max_rows,
        cell_aspect,
        DisplayMode::Default,
    )
}

pub fn sample_cells_with_mode(
    frame: &RgbFrame,
    max_columns: u16,
    max_rows: u16,
    cell_aspect: f64,
    display_mode: DisplayMode,
) -> CellGrid {
    debug_assert!(frame.validate());
    let (width, height) = fit_grid(
        frame.width,
        frame.height,
        max_columns,
        max_rows,
        cell_aspect,
    );
    let mut cells = Vec::with_capacity(width as usize * height as usize);

    if display_mode == DisplayMode::HalfBlock {
        let sample_rows = u64::from(height) * 2;
        for target_y in 0..height {
            let upper_y =
                centered_source_coordinate(u64::from(target_y) * 2, sample_rows, frame.height);
            let lower_y =
                centered_source_coordinate(u64::from(target_y) * 2 + 1, sample_rows, frame.height);
            for target_x in 0..width {
                let source_x =
                    centered_source_coordinate(u64::from(target_x), u64::from(width), frame.width);
                cells.push(Cell {
                    glyph: display_mode.glyph_for_luma(0),
                    foreground: pixel(frame, source_x, upper_y),
                    background: Some(pixel(frame, source_x, lower_y)),
                });
            }
        }
        return CellGrid {
            width,
            height,
            paired_colors: true,
            cells,
        };
    }

    for target_y in 0..height {
        let source_y = source_coordinate(u64::from(target_y), u64::from(height), frame.height);
        for target_x in 0..width {
            let source_x = source_coordinate(u64::from(target_x), u64::from(width), frame.width);
            let foreground = pixel(frame, source_x, source_y);
            cells.push(Cell {
                glyph: display_mode.glyph_for_luma(bt709_luma(foreground)),
                foreground,
                background: None,
            });
        }
    }

    CellGrid {
        width,
        height,
        paired_colors: false,
        cells,
    }
}

fn source_coordinate(target: u64, target_extent: u64, source_extent: u32) -> u32 {
    debug_assert!(target_extent > 0);
    ((target * u64::from(source_extent)) / target_extent)
        .min(u64::from(source_extent.saturating_sub(1))) as u32
}

fn centered_source_coordinate(target: u64, target_extent: u64, source_extent: u32) -> u32 {
    debug_assert!(target_extent > 0);
    (((target * 2 + 1) * u64::from(source_extent)) / (target_extent * 2))
        .min(u64::from(source_extent.saturating_sub(1))) as u32
}

fn pixel(frame: &RgbFrame, source_x: u32, source_y: u32) -> [u8; 3] {
    let offset = ((source_y * frame.width + source_x) * 3) as usize;
    [
        frame.rgb[offset],
        frame.rgb[offset + 1],
        frame.rgb[offset + 2],
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fit_grid_respects_bounds_and_cell_aspect() {
        assert_eq!(fit_grid(1920, 1080, 120, 40, 2.0), (120, 34));
        assert_eq!(fit_grid(1920, 1080, 200, 60, 2.0), (200, 56));
        assert_eq!(fit_grid(1080, 1920, 120, 40, 2.0), (45, 40));
        assert_eq!(fit_grid(0, 1080, 120, 40, 2.0), (0, 0));
        assert_eq!(34 * 2, 68);
        assert_eq!(56 * 2, 112);
    }

    #[test]
    fn samples_valid_grid() {
        let frame = RgbFrame {
            generation: 1,
            index: 0,
            pts: Duration::ZERO,
            width: 2,
            height: 1,
            rgb: vec![0, 0, 0, 255, 255, 255].into_boxed_slice(),
        };
        let grid = sample_cells(&frame, 2, 1, 1.0);
        assert_eq!(grid.width, 2);
        assert_eq!(grid.cells[0].glyph.as_char(), ' ');
        assert_eq!(grid.cells[1].glyph.as_char(), '@');
    }

    #[test]
    fn styled_sampling_changes_only_glyph_selection() {
        let frame = RgbFrame {
            generation: 1,
            index: 0,
            pts: Duration::ZERO,
            width: 3,
            height: 1,
            rgb: vec![0, 0, 0, 128, 128, 128, 255, 255, 255].into_boxed_slice(),
        };

        for (mode, expected) in [
            (DisplayMode::Default, [' ', '=', '@']),
            (DisplayMode::ClassicAscii, [' ', '=', '@']),
            (DisplayMode::DetailedAscii, [' ', 'Z', '@']),
            (DisplayMode::Gradient, [' ', '▒', '█']),
        ] {
            let grid = sample_cells_with_mode(&frame, 3, 1, 1.0, mode);
            assert_eq!(
                grid.cells
                    .iter()
                    .map(|cell| cell.glyph.as_char())
                    .collect::<Vec<_>>(),
                expected
            );
            assert_eq!(grid.cells[1].foreground, [128, 128, 128]);
            assert_eq!(grid.cells[1].background, None);
        }
    }

    #[test]
    fn default_wrapper_is_identical_to_explicit_default() {
        let frame = RgbFrame {
            generation: 1,
            index: 0,
            pts: Duration::ZERO,
            width: 2,
            height: 1,
            rgb: vec![50, 100, 150, 200, 220, 240].into_boxed_slice(),
        };
        assert_eq!(
            sample_cells(&frame, 2, 1, 1.0),
            sample_cells_with_mode(&frame, 2, 1, 1.0, DisplayMode::Default)
        );
    }

    #[test]
    fn extended_cell_keeps_paired_color_identity_compact() {
        assert_eq!(std::mem::size_of::<Cell>(), 8);
    }

    #[test]
    fn half_block_combines_two_vertical_image_samples_in_one_cell() {
        let frame = RgbFrame {
            generation: 1,
            index: 0,
            pts: Duration::ZERO,
            width: 1,
            height: 2,
            rgb: vec![255, 0, 0, 0, 0, 255].into_boxed_slice(),
        };
        let grid = sample_cells_with_mode(&frame, 1, 1, 1.0, DisplayMode::HalfBlock);
        assert_eq!((grid.width, grid.height), (1, 1));
        assert_eq!(grid.cells[0].glyph.as_char(), '▀');
        assert_eq!(grid.cells[0].foreground, [255, 0, 0]);
        assert_eq!(grid.cells[0].background, Some([0, 0, 255]));
    }

    #[test]
    fn half_block_preserves_double_vertical_resolution_and_safe_boundaries() {
        let four_rows = RgbFrame {
            generation: 1,
            index: 0,
            pts: Duration::ZERO,
            width: 1,
            height: 4,
            rgb: vec![1, 0, 0, 2, 0, 0, 3, 0, 0, 4, 0, 0].into_boxed_slice(),
        };
        let grid = sample_cells_with_mode(&four_rows, 1, 2, 1.0, DisplayMode::HalfBlock);
        assert_eq!((grid.width, grid.height), (1, 2));
        assert_eq!(grid.cells[0].foreground, [1, 0, 0]);
        assert_eq!(grid.cells[0].background, Some([2, 0, 0]));
        assert_eq!(grid.cells[1].foreground, [3, 0, 0]);
        assert_eq!(grid.cells[1].background, Some([4, 0, 0]));

        let one_row = RgbFrame {
            generation: 1,
            index: 0,
            pts: Duration::ZERO,
            width: 1,
            height: 1,
            rgb: vec![9, 8, 7].into_boxed_slice(),
        };
        let grid = sample_cells_with_mode(&one_row, 1, 1, 2.0, DisplayMode::HalfBlock);
        assert_eq!(grid.cells[0].foreground, [9, 8, 7]);
        assert_eq!(grid.cells[0].background, Some([9, 8, 7]));

        let odd_rows = RgbFrame {
            generation: 1,
            index: 0,
            pts: Duration::ZERO,
            width: 1,
            height: 3,
            rgb: vec![1, 0, 0, 2, 0, 0, 3, 0, 0].into_boxed_slice(),
        };
        let grid = sample_cells_with_mode(&odd_rows, 1, 1, 2.0, DisplayMode::HalfBlock);
        assert_eq!(grid.cells[0].foreground, [1, 0, 0]);
        assert_eq!(grid.cells[0].background, Some([3, 0, 0]));
    }
}
