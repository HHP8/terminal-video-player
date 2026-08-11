use std::io::{IsTerminal, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};

use super::{
    AnsiRenderer, Cell, CellGrid, ColorCapability, DisplayMode, Glyph, RenderStrategy, bt709_luma,
};
use crate::cli::BenchmarkPattern;
use crate::terminal::{InputEvent, TerminalSession, poll_event};

#[derive(Debug)]
struct Measurement {
    size: (u16, u16),
    frames: u64,
    bytes: u64,
    elapsed: Duration,
    encode_elapsed: Duration,
    write_elapsed: Duration,
    dropped_deadlines: u64,
    live: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct BenchmarkConfig {
    pub seconds: u64,
    pub live: bool,
    pub strategy: RenderStrategy,
    pub pattern: BenchmarkPattern,
    pub target_fps: u32,
    pub display_mode: DisplayMode,
    pub color: ColorCapability,
}

pub fn run(config: BenchmarkConfig, report: Option<&Path>, cancelled: &AtomicBool) -> Result<()> {
    if config.live && !std::io::stdout().is_terminal() {
        anyhow::bail!("live benchmark requires an interactive terminal");
    }

    let mut measurements = Vec::new();
    let sizes = [(80, 24), (120, 40), (160, 50), (200, 60)];
    let terminal_size = crossterm::terminal::size().unwrap_or((0, 0));

    for size in sizes {
        if cancelled.load(Ordering::Relaxed) {
            break;
        }
        if config.live && (terminal_size.0 < size.0 || terminal_size.1 < size.1) {
            eprintln!(
                "skipping live {}x{}: terminal is only {}x{}",
                size.0, size.1, terminal_size.0, terminal_size.1
            );
            continue;
        }
        measurements.push(measure_case(size, &config, cancelled)?);
    }

    let mut summary = format!(
        "renderer={:?} display_mode={:?} color={:?} pattern={:?} live={} target_fps={}\n",
        config.strategy,
        config.display_mode,
        config.color,
        config.pattern,
        config.live,
        config.target_fps
    );
    for measurement in measurements {
        let fps = measurement.frames as f64 / measurement.elapsed.as_secs_f64();
        let mib_per_second =
            measurement.bytes as f64 / measurement.elapsed.as_secs_f64() / (1024.0 * 1024.0);
        let bytes_per_frame = measurement.bytes as f64 / measurement.frames as f64;
        let encode_micros =
            measurement.encode_elapsed.as_secs_f64() * 1_000_000.0 / measurement.frames as f64;
        let write_micros =
            measurement.write_elapsed.as_secs_f64() * 1_000_000.0 / measurement.frames as f64;
        let attempted = measurement.frames + measurement.dropped_deadlines;
        let drop_percent = if attempted == 0 {
            0.0
        } else {
            measurement.dropped_deadlines as f64 * 100.0 / attempted as f64
        };
        summary.push_str(&format!(
            "{}x{}: {:.1} fps, {:.2} MiB/s, {:.0} bytes/frame, {:.1} us encode/frame, {:.1} us write/frame, {} frames, {} missed deadlines ({:.2}%), live={}\n",
            measurement.size.0,
            measurement.size.1,
            fps,
            mib_per_second,
            bytes_per_frame,
            encode_micros,
            write_micros,
            measurement.frames,
            measurement.dropped_deadlines,
            drop_percent,
            measurement.live
        ));
    }
    print!("{summary}");
    if let Some(report) = report {
        std::fs::write(report, summary)
            .with_context(|| format!("writing benchmark report {}", report.display()))?;
    }
    Ok(())
}

fn measure_case(
    size: (u16, u16),
    config: &BenchmarkConfig,
    cancelled: &AtomicBool,
) -> Result<Measurement> {
    let mut renderer = AnsiRenderer::new(config.strategy, config.color);
    let mut frame_index = 0u64;
    let mut rendered_frames = 0u64;
    let mut total_bytes = 0u64;
    let mut encode_elapsed = Duration::ZERO;
    let mut write_elapsed = Duration::ZERO;
    let mut dropped_deadlines = 0u64;
    let mut session = if config.live {
        Some(TerminalSession::enter().context("entering live benchmark terminal mode")?)
    } else {
        None
    };
    let started = Instant::now();
    let duration = Duration::from_secs(config.seconds);
    let frame_interval = Duration::from_secs_f64(1.0 / f64::from(config.target_fps));

    while started.elapsed() < duration && !cancelled.load(Ordering::Relaxed) {
        if config.live && matches!(poll_event(Duration::ZERO)?, InputEvent::Quit) {
            cancelled.store(true, Ordering::Relaxed);
            break;
        }
        if config.live {
            let expected_index =
                (started.elapsed().as_secs_f64() * f64::from(config.target_fps)).floor() as u64;
            if expected_index > frame_index {
                dropped_deadlines += expected_index - frame_index;
                frame_index = expected_index;
            }
        }
        let grid = match config.pattern {
            BenchmarkPattern::Motion => {
                synthetic_grid_for_mode(size.0, size.1, frame_index, config.display_mode)
            }
            BenchmarkPattern::Noise => {
                synthetic_noise_grid_for_mode(size.0, size.1, frame_index, config.display_mode)
            }
        };
        let encode_started = Instant::now();
        let bytes = renderer.encode(&grid);
        encode_elapsed += encode_started.elapsed();
        total_bytes += bytes.len() as u64;
        if let Some(session) = session.as_mut() {
            let write_started = Instant::now();
            session.write_frame(&bytes)?;
            write_elapsed += write_started.elapsed();
        }
        frame_index += 1;
        rendered_frames += 1;
        if config.live {
            let next_deadline = started
                .checked_add(frame_interval.mul_f64(frame_index as f64))
                .unwrap_or_else(Instant::now);
            let now = Instant::now();
            if next_deadline > now {
                let wait = (next_deadline - now).min(duration.saturating_sub(started.elapsed()));
                if matches!(poll_event(wait)?, InputEvent::Quit) {
                    cancelled.store(true, Ordering::Relaxed);
                }
            }
        }
    }
    if let Some(mut session) = session {
        session.restore();
    } else {
        std::io::sink().flush()?;
    }

    Ok(Measurement {
        size,
        frames: rendered_frames,
        bytes: total_bytes,
        elapsed: started.elapsed(),
        encode_elapsed,
        write_elapsed,
        dropped_deadlines,
        live: config.live,
    })
}

pub fn synthetic_grid(width: u16, height: u16, frame_index: u64) -> CellGrid {
    let mut state = frame_index ^ 0x9e37_79b9_7f4a_7c15;
    let mut cells = Vec::with_capacity(width as usize * height as usize);
    for index in 0..width as usize * height as usize {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        let moving_band = ((index as u64 + frame_index * 3) % u64::from(width)) < 8;
        let rgb = if moving_band {
            [state as u8, (state >> 8) as u8, (state >> 16) as u8]
        } else {
            let base = (index as u8).wrapping_mul(3);
            [base, base.wrapping_add(32), base.wrapping_add(64)]
        };
        cells.push(Cell {
            glyph: Glyph::ascii(b'#'),
            foreground: rgb,
            background: None,
        });
    }
    CellGrid {
        width,
        height,
        paired_colors: false,
        cells,
    }
}

pub fn synthetic_noise_grid(width: u16, height: u16, frame_index: u64) -> CellGrid {
    let mut state = frame_index ^ 0xd1b5_4a32_d192_ed03;
    let mut cells = Vec::with_capacity(width as usize * height as usize);
    for _ in 0..width as usize * height as usize {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        cells.push(Cell {
            glyph: Glyph::ascii(b'#'),
            foreground: [state as u8, (state >> 8) as u8, (state >> 16) as u8],
            background: None,
        });
    }
    CellGrid {
        width,
        height,
        paired_colors: false,
        cells,
    }
}

pub fn synthetic_grid_for_mode(
    width: u16,
    height: u16,
    frame_index: u64,
    display_mode: DisplayMode,
) -> CellGrid {
    apply_display_mode(synthetic_grid(width, height, frame_index), display_mode)
}

pub fn synthetic_noise_grid_for_mode(
    width: u16,
    height: u16,
    frame_index: u64,
    display_mode: DisplayMode,
) -> CellGrid {
    apply_display_mode(
        synthetic_noise_grid(width, height, frame_index),
        display_mode,
    )
}

fn apply_display_mode(mut grid: CellGrid, display_mode: DisplayMode) -> CellGrid {
    grid.paired_colors = display_mode == DisplayMode::HalfBlock;
    for (index, cell) in grid.cells.iter_mut().enumerate() {
        if display_mode == DisplayMode::HalfBlock {
            let bias = (index as u8).wrapping_mul(17);
            let upper = cell.foreground;
            cell.glyph = DisplayMode::HalfBlock.glyph_for_luma(0);
            cell.background = Some([
                upper[1].wrapping_add(bias),
                upper[2].wrapping_add(31),
                upper[0].wrapping_add(63),
            ]);
        } else {
            cell.glyph = display_mode.glyph_for_luma(bt709_luma(cell.foreground));
            cell.background = None;
        }
    }
    grid
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn benchmark_fixtures_apply_the_requested_display_mode_without_changing_rgb() {
        let default = synthetic_grid_for_mode(32, 8, 3, DisplayMode::Default);
        let classic = synthetic_grid_for_mode(32, 8, 3, DisplayMode::ClassicAscii);
        let detailed = synthetic_grid_for_mode(32, 8, 3, DisplayMode::DetailedAscii);
        let gradient = synthetic_grid_for_mode(32, 8, 3, DisplayMode::Gradient);
        let half_block = synthetic_grid_for_mode(32, 8, 3, DisplayMode::HalfBlock);

        assert_eq!(default, classic);
        assert_eq!(
            default
                .cells
                .iter()
                .map(|cell| cell.foreground)
                .collect::<Vec<_>>(),
            detailed
                .cells
                .iter()
                .map(|cell| cell.foreground)
                .collect::<Vec<_>>()
        );
        assert!(
            default
                .cells
                .iter()
                .zip(&detailed.cells)
                .any(|(left, right)| left.glyph != right.glyph)
        );
        assert!(
            default
                .cells
                .iter()
                .zip(&gradient.cells)
                .any(|(left, right)| left.glyph != right.glyph)
        );
        assert!(
            half_block
                .cells
                .iter()
                .all(|cell| cell.glyph.as_char() == '▀' && cell.background.is_some())
        );
        assert_eq!(
            default
                .cells
                .iter()
                .map(|cell| cell.foreground)
                .collect::<Vec<_>>(),
            half_block
                .cells
                .iter()
                .map(|cell| cell.foreground)
                .collect::<Vec<_>>()
        );
        assert!(
            half_block
                .cells
                .iter()
                .any(|cell| cell.background != Some(cell.foreground))
        );
    }
}
