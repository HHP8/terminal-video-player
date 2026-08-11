use std::hint::black_box;
use std::time::Duration;

use criterion::{BenchmarkId, Criterion, criterion_group, criterion_main};
use terminal_video_player::render::benchmark::{
    synthetic_grid, synthetic_grid_for_mode, synthetic_noise_grid, synthetic_noise_grid_for_mode,
};
use terminal_video_player::render::{
    AnsiRenderer, ColorCapability, DisplayMode, RenderStrategy, RgbFrame, sample_cells_with_mode,
};

fn render_benchmark(criterion: &mut Criterion) {
    let mut group = criterion.benchmark_group("ansi-encode");
    for (width, height) in [(80, 24), (120, 40), (160, 50), (200, 60)] {
        for (pattern, first, second) in [
            (
                "motion",
                synthetic_grid(width, height, 0),
                synthetic_grid(width, height, 1),
            ),
            (
                "noise",
                synthetic_noise_grid(width, height, 0),
                synthetic_noise_grid(width, height, 1),
            ),
        ] {
            for strategy in [
                RenderStrategy::Full,
                RenderStrategy::Delta,
                RenderStrategy::RowRuns,
                RenderStrategy::Adaptive,
            ] {
                group.bench_with_input(
                    BenchmarkId::new(
                        format!("{pattern}/{strategy:?}"),
                        format!("{width}x{height}"),
                    ),
                    &(first.clone(), second.clone()),
                    |bencher, (first, second)| {
                        bencher.iter(|| {
                            let mut renderer =
                                AnsiRenderer::new(strategy, ColorCapability::Truecolor);
                            black_box(renderer.encode(first));
                            black_box(renderer.encode(second));
                        });
                    },
                );
            }
        }
    }
    group.finish();
}

fn display_mode_encode_benchmark(criterion: &mut Criterion) {
    let mut group = criterion.benchmark_group("display-mode-encode");
    for (width, height) in [(120, 40), (200, 60)] {
        for (pattern, frame) in [("motion", false), ("noise", true)] {
            for color in [
                ColorCapability::Truecolor,
                ColorCapability::Color256,
                ColorCapability::Mono,
            ] {
                for display_mode in DisplayMode::ALL {
                    let first = if frame {
                        synthetic_noise_grid_for_mode(width, height, 0, display_mode)
                    } else {
                        synthetic_grid_for_mode(width, height, 0, display_mode)
                    };
                    let second = if frame {
                        synthetic_noise_grid_for_mode(width, height, 1, display_mode)
                    } else {
                        synthetic_grid_for_mode(width, height, 1, display_mode)
                    };
                    group.bench_with_input(
                        BenchmarkId::new(
                            format!("{pattern}/{color:?}/{display_mode:?}"),
                            format!("{width}x{height}"),
                        ),
                        &(first, second),
                        |bencher, (first, second)| {
                            bencher.iter(|| {
                                let mut renderer =
                                    AnsiRenderer::new(RenderStrategy::Adaptive, color);
                                black_box(renderer.encode(first));
                                black_box(renderer.encode(second));
                            });
                        },
                    );
                }
            }
        }
    }
    group.finish();
}

fn display_mode_sampling_benchmark(criterion: &mut Criterion) {
    let mut rgb = Vec::with_capacity(640 * 360 * 3);
    for index in 0..640_u32 * 360 {
        rgb.extend_from_slice(&[index as u8, (index >> 5) as u8, (index >> 11) as u8]);
    }
    let frame = RgbFrame {
        generation: 0,
        index: 0,
        pts: Duration::ZERO,
        width: 640,
        height: 360,
        rgb: rgb.into_boxed_slice(),
    };

    let mut group = criterion.benchmark_group("display-mode-sample");
    for (width, height) in [(120, 40), (200, 60)] {
        for display_mode in DisplayMode::ALL {
            group.bench_with_input(
                BenchmarkId::new(format!("{display_mode:?}"), format!("{width}x{height}")),
                &display_mode,
                |bencher, display_mode| {
                    bencher.iter(|| {
                        black_box(sample_cells_with_mode(
                            &frame,
                            width,
                            height,
                            2.0,
                            *display_mode,
                        ));
                    });
                },
            );
        }
    }
    group.finish();
}

criterion_group!(
    benches,
    render_benchmark,
    display_mode_encode_benchmark,
    display_mode_sampling_benchmark
);
criterion_main!(benches);
