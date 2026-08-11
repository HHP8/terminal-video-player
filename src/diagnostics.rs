use std::env;

use crate::audio::AudioDevice;
use crate::media::FfmpegPaths;

pub fn print(ffmpeg: Option<&FfmpegPaths>) -> bool {
    println!(
        "terminal-video-player {} (proof of concept)",
        env!("CARGO_PKG_VERSION")
    );
    println!("platform: {} {}", env::consts::OS, env::consts::ARCH);
    println!(
        "Windows Terminal: {}",
        if env::var_os("WT_SESSION").is_some() {
            "detected"
        } else {
            "not detected"
        }
    );
    println!(
        "PowerShell environment: {}",
        if env::var_os("PSModulePath").is_some() {
            "detected"
        } else {
            "not detected"
        }
    );
    match crossterm::terminal::size() {
        Ok((columns, rows)) => println!("terminal cells: {columns}x{rows}"),
        Err(error) => println!("terminal cells: unavailable ({error})"),
    }
    match AudioDevice::open() {
        Ok(_) => println!("WASAPI 48 kHz stereo output: available"),
        Err(error) => println!("WASAPI 48 kHz stereo output: unavailable ({error:#})"),
    }
    match ffmpeg {
        Some(paths) => {
            println!("FFmpeg directory: {}", paths.directory.display());
            match paths.version() {
                Ok(version) => println!("FFmpeg version: {version}"),
                Err(error) => println!("FFmpeg version: unreadable ({error:#})"),
            }
            match paths.validate_runtime() {
                Ok(()) => {
                    println!("FFmpeg pinned version/configuration: verified");
                    true
                }
                Err(error) => {
                    println!("FFmpeg pinned version/configuration: invalid ({error:#})");
                    false
                }
            }
        }
        None => {
            println!(
                "FFmpeg: not found beside the application; reinstall or pass --ffmpeg-dir <DIR>"
            );
            false
        }
    }
}
