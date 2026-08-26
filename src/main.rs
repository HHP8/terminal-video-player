use std::io::IsTerminal;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{Context, Result};
use clap::Parser;
use terminal_video_player::cli::{Cli, Command};
use terminal_video_player::diagnostics;
use terminal_video_player::media::FfmpegPaths;
use terminal_video_player::playback;
use terminal_video_player::render::{ColorCapability, DisplayMode, benchmark};
use terminal_video_player::terminal::{
    DisplayModePolicy, MenuOutcome, TerminalSession, force_restore_terminal, install_panic_hook,
    restore_terminal, select_display_mode, selection_policy,
};

fn main() {
    if let Err(error) = run() {
        restore_terminal();
        eprintln!("error: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Some(Command::RestoreTerminal) => {
            force_restore_terminal();
            println!("Terminal state reset sequence sent.");
            return Ok(());
        }
        Some(Command::Diagnostics) => {
            let ffmpeg = FfmpegPaths::resolve(cli.ffmpeg_dir.as_deref()).ok();
            if !diagnostics::print(ffmpeg.as_ref()) {
                anyhow::bail!("the configured FFmpeg runtime is missing or incompatible");
            }
            return Ok(());
        }
        Some(Command::Benchmark {
            seconds,
            live,
            renderer,
            pattern,
            target_fps,
            report,
        }) => {
            let cancelled = install_cancellation_handler()?;
            install_panic_hook();
            let display_mode = cli
                .display_mode
                .map(Into::into)
                .unwrap_or(DisplayMode::Default);
            return benchmark::run(
                benchmark::BenchmarkConfig {
                    seconds,
                    live,
                    strategy: renderer.into(),
                    pattern,
                    target_fps,
                    display_mode,
                    color: ColorCapability::resolve(cli.color),
                },
                report.as_deref(),
                &cancelled,
            );
        }
        None => {}
    }

    let input = cli
        .input
        .as_deref()
        .context("a local image, GIF, or video path is required")?;

    if !input.exists() {
        anyhow::bail!("input does not exist: {}", input.display());
    }
    if !std::io::stdout().is_terminal() {
        anyhow::bail!(
            "stdout is not an interactive terminal; run this command in Windows Terminal"
        );
    }
    let media = playback::prepare(input, &cli).context("preparing media input")?;
    let display_policy = selection_policy(
        cli.display_mode.map(Into::into),
        media.is_video(),
        std::io::stdin().is_terminal(),
    );

    let cancelled = install_cancellation_handler()?;
    install_panic_hook();
    let mut terminal = TerminalSession::enter().context("entering terminal playback mode")?;
    if std::env::var_os("TERMINAL_VIDEO_PLAYER_INJECT_PANIC").as_deref()
        == Some(std::ffi::OsStr::new("after-enter"))
    {
        panic!("injected panic after terminal entry");
    }
    let display_mode = match display_policy {
        DisplayModePolicy::Use(mode) => mode,
        DisplayModePolicy::Prompt => match select_display_mode(&mut terminal, &cancelled)? {
            MenuOutcome::Selected(mode) => mode,
            MenuOutcome::Cancelled => return Ok(()),
        },
    };
    if cancelled.load(Ordering::Relaxed) {
        return Ok(());
    }
    playback::play(media, &cli, display_mode, &cancelled, &mut terminal)
}

fn install_cancellation_handler() -> Result<Arc<AtomicBool>> {
    let cancelled = Arc::new(AtomicBool::new(false));
    let signal_cancelled = Arc::clone(&cancelled);
    ctrlc::set_handler(move || {
        signal_cancelled.store(true, Ordering::SeqCst);
    })
    .context("installing Ctrl+C handler")?;
    Ok(cancelled)
}
