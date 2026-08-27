use std::path::PathBuf;

use clap::{Parser, Subcommand, ValueEnum};

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum ColorMode {
    Auto,
    Truecolor,
    Color256,
    Mono,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum RendererChoice {
    Adaptive,
    Full,
    Delta,
    Rows,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum DisplayModeChoice {
    Default,
    ClassicAscii,
    DetailedAscii,
    Gradient,
    HalfBlock,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum BenchmarkPattern {
    Motion,
    Noise,
}

#[derive(Debug, Parser)]
#[command(
    name = "terminal-video-player",
    version,
    about = "Windows-first terminal media player proof of concept",
    after_help = "Controls: Space pause/resume, Left/Right seek 5 seconds, M mute, Q/Esc quit"
)]
pub struct Cli {
    /// Local image, GIF, or video path.
    #[arg(value_name = "PATH")]
    pub input: Option<PathBuf>,

    /// Choose the display style and skip the interactive video menu.
    ///
    /// When omitted, interactive video playback prompts; non-interactive input uses Default.
    #[arg(long, value_enum, value_name = "MODE", global = true)]
    pub display_mode: Option<DisplayModeChoice>,

    /// Color output mode.
    #[arg(long, value_enum, default_value_t = ColorMode::Auto)]
    pub color: ColorMode,

    /// Override normalized video frame rate (1-60).
    #[arg(long, value_parser = clap::value_parser!(u32).range(1..=60))]
    pub fps: Option<u32>,

    /// Terminal cell height divided by width.
    #[arg(long, default_value_t = 2.0, value_parser = parse_positive_f64)]
    pub cell_aspect: f64,

    /// Disable audio and use a monotonic video clock.
    #[arg(long)]
    pub no_audio: bool,

    /// Start with audio muted while retaining the audio master clock.
    #[arg(long)]
    pub start_muted: bool,

    /// Repeat GIF or video playback.
    #[arg(long)]
    pub r#loop: bool,

    /// Directory containing ffmpeg.exe and ffprobe.exe.
    #[arg(long, value_name = "DIR")]
    pub ffmpeg_dir: Option<PathBuf>,

    /// Force a renderer instead of choosing the smallest payload.
    #[arg(long, value_enum, default_value_t = RendererChoice::Adaptive)]
    pub renderer: RendererChoice,

    #[command(subcommand)]
    pub command: Option<Command>,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Emit best-effort VT reset sequences and restore cooked input mode.
    RestoreTerminal,
    /// Print environment, terminal, and configured FFmpeg diagnostics.
    Diagnostics,
    /// Decode and render-check one local media file without entering terminal playback mode.
    ValidateMedia {
        /// Local image, GIF, or video path to validate.
        #[arg(value_name = "PATH")]
        path: PathBuf,
    },
    /// Benchmark ANSI frame generation and optionally write frames live.
    Benchmark {
        /// Seconds per benchmark case.
        #[arg(long, default_value_t = 2, value_parser = clap::value_parser!(u64).range(1..=3600))]
        seconds: u64,

        /// Write generated frames to the terminal in addition to measuring encoding.
        #[arg(long)]
        live: bool,

        /// Renderer to exercise.
        #[arg(long, value_enum, default_value_t = RendererChoice::Adaptive)]
        renderer: RendererChoice,

        /// Frame-change pattern to encode and optionally paint.
        #[arg(long, value_enum, default_value_t = BenchmarkPattern::Motion)]
        pattern: BenchmarkPattern,

        /// Frame rate used to pace live terminal writes.
        #[arg(long, default_value_t = 30, value_parser = clap::value_parser!(u32).range(1..=60))]
        target_fps: u32,

        /// Also write the summary to this UTF-8 text file.
        #[arg(long, value_name = "PATH")]
        report: Option<PathBuf>,
    },
}

fn parse_positive_f64(value: &str) -> Result<f64, String> {
    let parsed: f64 = value
        .parse()
        .map_err(|_| format!("'{value}' is not a number"))?;
    if !parsed.is_finite() || parsed <= 0.0 {
        return Err("value must be a finite positive number".to_owned());
    }
    Ok(parsed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    #[test]
    fn parses_every_explicit_display_mode() {
        for (value, expected) in [
            ("default", DisplayModeChoice::Default),
            ("classic-ascii", DisplayModeChoice::ClassicAscii),
            ("detailed-ascii", DisplayModeChoice::DetailedAscii),
            ("gradient", DisplayModeChoice::Gradient),
            ("half-block", DisplayModeChoice::HalfBlock),
        ] {
            let cli = Cli::try_parse_from([
                "terminal-video-player",
                "movie.mp4",
                "--display-mode",
                value,
            ])
            .expect("valid display mode");
            assert_eq!(cli.display_mode, Some(expected));
        }
    }

    #[test]
    fn omitted_display_mode_remains_distinguishable_from_explicit_default() {
        let omitted =
            Cli::try_parse_from(["terminal-video-player", "movie.mp4"]).expect("omitted mode");
        let explicit = Cli::try_parse_from([
            "terminal-video-player",
            "movie.mp4",
            "--display-mode",
            "default",
        ])
        .expect("explicit default");
        assert_eq!(omitted.display_mode, None);
        assert_eq!(explicit.display_mode, Some(DisplayModeChoice::Default));
    }

    #[test]
    fn rejects_unknown_display_mode() {
        let error = Cli::try_parse_from([
            "terminal-video-player",
            "movie.mp4",
            "--display-mode",
            "cinema",
        ])
        .expect_err("invalid mode must fail");
        assert!(error.to_string().contains("invalid value 'cinema'"));
    }

    #[test]
    fn display_mode_is_global_for_benchmarks_and_documented_in_help() {
        let cli = Cli::try_parse_from([
            "terminal-video-player",
            "benchmark",
            "--display-mode",
            "gradient",
        ])
        .expect("global benchmark display mode");
        assert_eq!(cli.display_mode, Some(DisplayModeChoice::Gradient));

        let mut command = Cli::command();
        let mut help = Vec::new();
        command.write_long_help(&mut help).expect("render help");
        let help = String::from_utf8(help).expect("UTF-8 help");
        assert!(help.contains("--display-mode <MODE>"));
        assert!(help.contains("classic-ascii"));
        assert!(help.contains("detailed-ascii"));
        assert!(help.contains("gradient"));
        assert!(help.contains("half-block"));
    }

    #[test]
    fn parses_noninteractive_media_validation_with_a_global_display_mode() {
        let cli = Cli::try_parse_from([
            "terminal-video-player",
            "validate-media",
            "fixture.mp4",
            "--display-mode",
            "half-block",
        ])
        .expect("release media validation command");
        assert_eq!(cli.display_mode, Some(DisplayModeChoice::HalfBlock));
        let Some(Command::ValidateMedia { path }) = cli.command else {
            panic!("expected validate-media command");
        };
        assert_eq!(path, PathBuf::from("fixture.mp4"));
    }
}
