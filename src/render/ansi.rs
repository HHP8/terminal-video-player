use std::env;

use crate::cli::{ColorMode, RendererChoice};

use super::{Cell, CellGrid, Glyph, bt709_luma};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorCapability {
    Truecolor,
    Color256,
    Mono,
}

impl ColorCapability {
    pub fn resolve(requested: ColorMode) -> Self {
        match requested {
            ColorMode::Truecolor => Self::Truecolor,
            ColorMode::Color256 => Self::Color256,
            ColorMode::Mono => Self::Mono,
            ColorMode::Auto => {
                let color_term = env::var("COLORTERM")
                    .unwrap_or_default()
                    .to_ascii_lowercase();
                if cfg!(windows)
                    || env::var_os("WT_SESSION").is_some()
                    || color_term.contains("truecolor")
                    || color_term.contains("24bit")
                {
                    Self::Truecolor
                } else if env::var_os("TERM").is_some() {
                    Self::Color256
                } else {
                    Self::Mono
                }
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RenderStrategy {
    Adaptive,
    Full,
    Delta,
    RowRuns,
}

impl From<RendererChoice> for RenderStrategy {
    fn from(value: RendererChoice) -> Self {
        match value {
            RendererChoice::Adaptive => Self::Adaptive,
            RendererChoice::Full => Self::Full,
            RendererChoice::Delta => Self::Delta,
            RendererChoice::Rows => Self::RowRuns,
        }
    }
}

#[derive(Debug)]
pub struct AnsiRenderer {
    previous: Option<CellGrid>,
    strategy: RenderStrategy,
    color: ColorCapability,
    clear_next: bool,
}

#[derive(Debug, Default)]
struct ActiveColors {
    foreground: Option<[u8; 3]>,
    background: Option<[u8; 3]>,
}

impl AnsiRenderer {
    pub fn new(strategy: RenderStrategy, color: ColorCapability) -> Self {
        Self {
            previous: None,
            strategy,
            color,
            clear_next: true,
        }
    }

    pub fn reset(&mut self) {
        self.previous = None;
        self.clear_next = true;
    }

    pub fn encode(&mut self, grid: &CellGrid) -> Vec<u8> {
        let resized = self
            .previous
            .as_ref()
            .is_some_and(|previous| previous.width != grid.width || previous.height != grid.height);
        if resized {
            self.previous = None;
            self.clear_next = true;
        }
        let has_background = grid.paired_colors;

        let mut encoded = match self.strategy {
            RenderStrategy::Full => encode_full(grid, self.color, has_background),
            RenderStrategy::Delta => {
                encode_delta(self.previous.as_ref(), grid, self.color, has_background)
            }
            RenderStrategy::RowRuns => {
                encode_rows(self.previous.as_ref(), grid, self.color, has_background)
            }
            RenderStrategy::Adaptive => {
                let full = encode_full(grid, self.color, has_background);
                if self.previous.is_none() {
                    full
                } else {
                    let delta =
                        encode_delta(self.previous.as_ref(), grid, self.color, has_background);
                    let rows =
                        encode_rows(self.previous.as_ref(), grid, self.color, has_background);
                    [full, delta, rows]
                        .into_iter()
                        .min_by_key(Vec::len)
                        .expect("three renderer candidates")
                }
            }
        };
        if self.clear_next {
            let mut cleared =
                Vec::with_capacity(encoded.len() + if has_background { 8 } else { 4 });
            if has_background {
                cleared.extend_from_slice(b"\x1b[0m");
            }
            cleared.extend_from_slice(b"\x1b[2J");
            cleared.append(&mut encoded);
            encoded = cleared;
            self.clear_next = false;
        }
        self.previous = Some(grid.clone());
        encoded
    }
}

fn encode_full(grid: &CellGrid, color: ColorCapability, has_background: bool) -> Vec<u8> {
    let mut output = Vec::with_capacity(estimate_capacity(grid, color, has_background));
    output.extend_from_slice(b"\x1b[H");
    let mut active = ActiveColors::default();
    for row in 0..grid.height {
        if row > 0 {
            output.extend_from_slice(b"\r\n");
        }
        let cells = grid.row(row);
        write_cells(&mut output, cells, color, &mut active, has_background);
        if row + 1 < grid.height && has_background && color != ColorCapability::Mono {
            output.extend_from_slice(b"\x1b[0m");
            active = ActiveColors::default();
        }
    }
    output.extend_from_slice(b"\x1b[0m");
    output
}

fn encode_rows(
    previous: Option<&CellGrid>,
    grid: &CellGrid,
    color: ColorCapability,
    has_background: bool,
) -> Vec<u8> {
    let Some(previous) =
        previous.filter(|old| old.width == grid.width && old.height == grid.height)
    else {
        return encode_full(grid, color, has_background);
    };
    let mut output = Vec::with_capacity(estimate_capacity(grid, color, has_background) / 2);
    for row in 0..grid.height {
        if previous.row(row) == grid.row(row) {
            continue;
        }
        cursor_to(&mut output, row + 1, 1);
        let cells = grid.row(row);
        let mut active = ActiveColors::default();
        write_cells(&mut output, cells, color, &mut active, has_background);
        if has_background && color != ColorCapability::Mono {
            output.extend_from_slice(b"\x1b[0m");
        }
    }
    output.extend_from_slice(b"\x1b[0m");
    output
}

fn encode_delta(
    previous: Option<&CellGrid>,
    grid: &CellGrid,
    color: ColorCapability,
    has_background: bool,
) -> Vec<u8> {
    let Some(previous) =
        previous.filter(|old| old.width == grid.width && old.height == grid.height)
    else {
        return encode_full(grid, color, has_background);
    };
    let mut output = Vec::with_capacity(estimate_capacity(grid, color, has_background) / 3);
    for row in 0..grid.height {
        let old_row = previous.row(row);
        let new_row = grid.row(row);
        let mut column = 0usize;
        while column < new_row.len() {
            while column < new_row.len() && new_row[column] == old_row[column] {
                column += 1;
            }
            if column == new_row.len() {
                break;
            }
            let start = column;
            while column < new_row.len() && new_row[column] != old_row[column] {
                column += 1;
            }
            cursor_to(&mut output, row + 1, start as u16 + 1);
            let cells = &new_row[start..column];
            let mut active = ActiveColors::default();
            write_cells(&mut output, cells, color, &mut active, has_background);
            if has_background && color != ColorCapability::Mono {
                output.extend_from_slice(b"\x1b[0m");
            }
        }
    }
    output.extend_from_slice(b"\x1b[0m");
    output
}

fn write_cells(
    output: &mut Vec<u8>,
    cells: &[Cell],
    color: ColorCapability,
    active: &mut ActiveColors,
    has_background: bool,
) {
    if has_background {
        for cell in cells {
            write_cell(output, cell, color, active);
        }
    } else {
        for cell in cells {
            write_plain_cell(output, cell, color, active);
        }
    }
}

fn write_plain_cell(
    output: &mut Vec<u8>,
    cell: &Cell,
    color: ColorCapability,
    active: &mut ActiveColors,
) {
    match color {
        ColorCapability::Truecolor => {
            if active.foreground != Some(cell.foreground) {
                append_decimal_sequence(output, b"\x1b[38;2;", &cell.foreground);
                active.foreground = Some(cell.foreground);
            }
        }
        ColorCapability::Color256 => {
            let index = rgb_to_ansi256(cell.foreground);
            let key = [index, 0, 0];
            if active.foreground != Some(key) {
                output.extend_from_slice(b"\x1b[38;5;");
                push_u8_decimal(output, index);
                output.push(b'm');
                active.foreground = Some(key);
            }
        }
        ColorCapability::Mono => {}
    }
    cell.glyph.write_utf8(output);
}

fn write_cell(
    output: &mut Vec<u8>,
    cell: &Cell,
    color: ColorCapability,
    active: &mut ActiveColors,
) {
    let glyph = match color {
        ColorCapability::Truecolor => {
            if active.foreground != Some(cell.foreground) {
                append_decimal_sequence(output, b"\x1b[38;2;", &cell.foreground);
                active.foreground = Some(cell.foreground);
            }
            write_truecolor_background(output, cell.background, active);
            cell.glyph
        }
        ColorCapability::Color256 => {
            let index = rgb_to_ansi256(cell.foreground);
            let key = [index, 0, 0];
            if active.foreground != Some(key) {
                output.extend_from_slice(b"\x1b[38;5;");
                push_u8_decimal(output, index);
                output.push(b'm');
                active.foreground = Some(key);
            }
            write_ansi256_background(output, cell.background, active);
            cell.glyph
        }
        ColorCapability::Mono => match cell.background {
            Some(background) => monochrome_half_block(cell.foreground, background),
            None => cell.glyph,
        },
    };
    glyph.write_utf8(output);
}

fn monochrome_half_block(upper: [u8; 3], lower: [u8; 3]) -> Glyph {
    match (bt709_luma(upper) >= 128, bt709_luma(lower) >= 128) {
        (false, false) => Glyph::ascii(b' '),
        (true, false) => Glyph::upper_half_block(),
        (false, true) => Glyph::lower_half_block(),
        (true, true) => Glyph::full_block(),
    }
}

fn write_truecolor_background(
    output: &mut Vec<u8>,
    background: Option<[u8; 3]>,
    active: &mut ActiveColors,
) {
    match background {
        Some(rgb) if active.background != Some(rgb) => {
            append_decimal_sequence(output, b"\x1b[48;2;", &rgb);
            active.background = Some(rgb);
        }
        None if active.background.take().is_some() => {
            output.extend_from_slice(b"\x1b[49m");
        }
        _ => {}
    }
}

fn write_ansi256_background(
    output: &mut Vec<u8>,
    background: Option<[u8; 3]>,
    active: &mut ActiveColors,
) {
    match background {
        Some(rgb) => {
            let index = rgb_to_ansi256(rgb);
            let key = [index, 0, 0];
            if active.background != Some(key) {
                output.extend_from_slice(b"\x1b[48;5;");
                push_u8_decimal(output, index);
                output.push(b'm');
                active.background = Some(key);
            }
        }
        None if active.background.take().is_some() => {
            output.extend_from_slice(b"\x1b[49m");
        }
        None => {}
    }
}

fn append_decimal_sequence(output: &mut Vec<u8>, prefix: &[u8], rgb: &[u8; 3]) {
    output.extend_from_slice(prefix);
    push_u8_decimal(output, rgb[0]);
    output.push(b';');
    push_u8_decimal(output, rgb[1]);
    output.push(b';');
    push_u8_decimal(output, rgb[2]);
    output.push(b'm');
}

fn push_u8_decimal(output: &mut Vec<u8>, value: u8) {
    if value >= 100 {
        output.push(b'0' + value / 100);
        output.push(b'0' + (value / 10) % 10);
    } else if value >= 10 {
        output.push(b'0' + value / 10);
    }
    output.push(b'0' + value % 10);
}

fn cursor_to(output: &mut Vec<u8>, row: u16, column: u16) {
    output.extend_from_slice(b"\x1b[");
    push_u16_decimal(output, row);
    output.push(b';');
    push_u16_decimal(output, column);
    output.push(b'H');
}

fn push_u16_decimal(output: &mut Vec<u8>, value: u16) {
    output.extend_from_slice(value.to_string().as_bytes());
}

fn rgb_to_ansi256(rgb: [u8; 3]) -> u8 {
    let r = (u16::from(rgb[0]) * 5 / 255) as u8;
    let g = (u16::from(rgb[1]) * 5 / 255) as u8;
    let b = (u16::from(rgb[2]) * 5 / 255) as u8;
    16 + 36 * r + 6 * g + b
}

fn estimate_capacity(grid: &CellGrid, color: ColorCapability, has_background: bool) -> usize {
    let per_cell = match (color, has_background) {
        (ColorCapability::Truecolor, true) => 48,
        (ColorCapability::Color256, true) => 28,
        (ColorCapability::Truecolor, false) => 24,
        (ColorCapability::Color256, false) => 16,
        (ColorCapability::Mono, _) => 4,
    };
    grid.cells.len() * per_cell + grid.height as usize * 2 + 16
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::render::{DisplayMode, Glyph};

    fn grid(changes: bool) -> CellGrid {
        let second = if changes { [255, 0, 0] } else { [0, 0, 0] };
        CellGrid {
            width: 2,
            height: 1,
            paired_colors: false,
            cells: vec![
                Cell {
                    glyph: Glyph::ascii(b' '),
                    foreground: [0, 0, 0],
                    background: None,
                },
                Cell {
                    glyph: Glyph::ascii(b'#'),
                    foreground: second,
                    background: None,
                },
            ],
        }
    }

    #[test]
    fn first_delta_frame_is_full() {
        let mut renderer = AnsiRenderer::new(RenderStrategy::Delta, ColorCapability::Mono);
        let bytes = renderer.encode(&grid(false));
        assert!(bytes.starts_with(b"\x1b[2J\x1b[H"));
    }

    #[test]
    fn default_ascii_cells_preserve_the_previous_byte_output() {
        let mut renderer = AnsiRenderer::new(RenderStrategy::Full, ColorCapability::Mono);
        assert_eq!(renderer.encode(&grid(false)), b"\x1b[2J\x1b[H #\x1b[0m");
    }

    #[test]
    fn unchanged_delta_is_tiny() {
        let mut renderer = AnsiRenderer::new(RenderStrategy::Delta, ColorCapability::Truecolor);
        let first = grid(false);
        renderer.encode(&first);
        let bytes = renderer.encode(&first);
        assert_eq!(bytes, b"\x1b[0m");
    }

    #[test]
    fn adaptive_prefers_small_update() {
        let mut renderer = AnsiRenderer::new(RenderStrategy::Adaptive, ColorCapability::Truecolor);
        renderer.encode(&grid(false));
        let bytes = renderer.encode(&grid(true));
        assert!(!bytes.starts_with(b"\x1b[H"));
    }

    #[test]
    fn reset_clears_stale_cells_before_redrawing() {
        let mut renderer = AnsiRenderer::new(RenderStrategy::Delta, ColorCapability::Mono);
        renderer.encode(&grid(false));
        renderer.reset();
        let bytes = renderer.encode(&grid(false));
        assert!(bytes.starts_with(b"\x1b[2J\x1b[H"));
    }

    #[test]
    fn gradient_glyphs_are_encoded_as_utf8_without_changing_cursor_columns() {
        let first = CellGrid {
            width: 2,
            height: 1,
            paired_colors: false,
            cells: vec![
                Cell {
                    glyph: DisplayMode::Gradient.glyph_for_luma(64),
                    foreground: [10, 20, 30],
                    background: None,
                },
                Cell {
                    glyph: DisplayMode::Gradient.glyph_for_luma(255),
                    foreground: [40, 50, 60],
                    background: None,
                },
            ],
        };
        let mut renderer = AnsiRenderer::new(RenderStrategy::Delta, ColorCapability::Mono);
        let bytes = renderer.encode(&first);
        let text = String::from_utf8(bytes).expect("valid UTF-8");
        assert!(text.contains("░█"));

        let mut second = first;
        second.cells[1].glyph = DisplayMode::Gradient.glyph_for_luma(192);
        let bytes = renderer.encode(&second);
        let text = String::from_utf8(bytes).expect("valid UTF-8");
        assert!(text.contains("\x1b[1;2H"));
        assert!(text.contains('▓'));
    }

    #[test]
    fn glyph_style_does_not_change_color_sequences() {
        for glyph in [
            Glyph::ascii(b'@'),
            Glyph::ascii(b'Z'),
            DisplayMode::Gradient.glyph_for_luma(255),
        ] {
            let grid = CellGrid {
                width: 1,
                height: 1,
                paired_colors: false,
                cells: vec![Cell {
                    glyph,
                    foreground: [10, 20, 30],
                    background: None,
                }],
            };

            let truecolor =
                AnsiRenderer::new(RenderStrategy::Full, ColorCapability::Truecolor).encode(&grid);
            assert!(
                truecolor
                    .windows(b"\x1b[38;2;10;20;30m".len())
                    .any(|window| window == b"\x1b[38;2;10;20;30m")
            );

            let color256 =
                AnsiRenderer::new(RenderStrategy::Full, ColorCapability::Color256).encode(&grid);
            assert!(
                color256
                    .windows(b"\x1b[38;5;16m".len())
                    .any(|window| window == b"\x1b[38;5;16m")
            );

            let mono = AnsiRenderer::new(RenderStrategy::Full, ColorCapability::Mono).encode(&grid);
            assert!(!mono.windows(3).any(|window| window == b"\x1b[3"));
        }
    }

    fn half_block(upper: [u8; 3], lower: [u8; 3]) -> CellGrid {
        CellGrid {
            width: 1,
            height: 1,
            paired_colors: true,
            cells: vec![Cell {
                glyph: DisplayMode::HalfBlock.glyph_for_luma(0),
                foreground: upper,
                background: Some(lower),
            }],
        }
    }

    #[test]
    fn truecolor_half_block_encodes_independent_upper_and_lower_colors() {
        let bytes = AnsiRenderer::new(RenderStrategy::Full, ColorCapability::Truecolor)
            .encode(&half_block([1, 2, 3], [4, 5, 6]));
        assert_eq!(
            bytes,
            "\x1b[0m\x1b[2J\x1b[H\x1b[38;2;1;2;3m\x1b[48;2;4;5;6m▀\x1b[0m".as_bytes()
        );
    }

    #[test]
    fn ansi256_half_block_converts_both_colors() {
        let bytes = AnsiRenderer::new(RenderStrategy::Full, ColorCapability::Color256)
            .encode(&half_block([255, 0, 0], [0, 0, 255]));
        let text = String::from_utf8(bytes).expect("valid UTF-8");
        assert!(text.contains("\x1b[38;5;196m"));
        assert!(text.contains("\x1b[48;5;21m"));
        assert!(text.contains('▀'));
    }

    #[test]
    fn monochrome_half_block_uses_deterministic_two_sample_shapes() {
        for (upper, lower, expected) in [
            ([0, 0, 0], [0, 0, 0], ' '),
            ([255, 255, 255], [0, 0, 0], '▀'),
            ([0, 0, 0], [255, 255, 255], '▄'),
            ([255, 255, 255], [255, 255, 255], '█'),
        ] {
            let bytes = AnsiRenderer::new(RenderStrategy::Full, ColorCapability::Mono)
                .encode(&half_block(upper, lower));
            let text = String::from_utf8(bytes).expect("valid UTF-8");
            assert!(text.contains(expected));
            assert!(!text.contains("\x1b[3"));
            assert!(!text.contains("\x1b[4"));
        }
    }

    #[test]
    fn every_strategy_redraws_a_lower_half_only_change() {
        for strategy in [
            RenderStrategy::Full,
            RenderStrategy::Delta,
            RenderStrategy::RowRuns,
            RenderStrategy::Adaptive,
        ] {
            let mut renderer = AnsiRenderer::new(strategy, ColorCapability::Truecolor);
            renderer.encode(&half_block([10, 20, 30], [40, 50, 60]));
            let bytes = renderer.encode(&half_block([10, 20, 30], [70, 80, 90]));
            let text = String::from_utf8(bytes).expect("valid UTF-8");
            assert!(text.contains("\x1b[48;2;70;80;90m"), "{strategy:?}");
            assert!(text.contains('▀'), "{strategy:?}");
        }
    }

    #[test]
    fn colored_background_is_reset_before_row_and_plain_cell_boundaries() {
        let grid = CellGrid {
            width: 2,
            height: 2,
            paired_colors: true,
            cells: vec![
                Cell {
                    glyph: DisplayMode::HalfBlock.glyph_for_luma(0),
                    foreground: [1, 2, 3],
                    background: Some([4, 5, 6]),
                },
                Cell {
                    glyph: Glyph::ascii(b'#'),
                    foreground: [7, 8, 9],
                    background: None,
                },
                Cell {
                    glyph: DisplayMode::HalfBlock.glyph_for_luma(0),
                    foreground: [10, 11, 12],
                    background: Some([13, 14, 15]),
                },
                Cell {
                    glyph: DisplayMode::HalfBlock.glyph_for_luma(0),
                    foreground: [16, 17, 18],
                    background: Some([19, 20, 21]),
                },
            ],
        };
        let bytes =
            AnsiRenderer::new(RenderStrategy::Full, ColorCapability::Truecolor).encode(&grid);
        let text = String::from_utf8(bytes).expect("valid UTF-8");
        assert!(text.contains("\x1b[49m#"));
        assert!(text.contains("#\x1b[0m\r\n"));
        assert!(text.ends_with("\x1b[0m"));
    }
}
