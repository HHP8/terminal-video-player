# Validation Ledger

This ledger separates repeatable checks from historical proof-of-concept
measurements and unverified release claims. The project remains a POC even when
the automated suite passes.

## Required source checks

Run from PowerShell with Rust 1.97.1 MSVC, Visual Studio Build Tools, and a
Windows SDK:

```powershell
cargo fmt --all -- --check
cargo check --all-targets --locked
cargo clippy --all-targets --locked -- -D warnings
cargo test --all-targets --locked
git diff --check
```

GitHub Actions repeats the four Cargo checks on `windows-2025` with read-only
repository permissions.

## FFmpeg integration checks

These tests are ignored by default because they require external FFmpeg tools
and generated media:

```powershell
.\scripts\Generate-TestMedia.ps1 -DurationSeconds 10 `
  -FfmpegDirectory 'C:\path\to\reviewed\ffmpeg\bin'
$env:TERMINAL_VIDEO_PLAYER_FFMPEG_DIR = 'C:\path\to\reviewed\ffmpeg\bin'
cargo test --locked --all-targets -- --include-ignored
```

The integration suite covers Unicode-path video/audio decoding, cancellation
with a full bounded queue, and faster-than-real-time decode of the ten-second
1080p fixture to 640x360 RGB24. `Run-PlaybackSmoke.ps1` and
`Run-LiveBenchmark.ps1` provide interactive checks without publishing their
generated reports.

## Established POC evidence

- Automated coverage exercises all five display modes in Truecolor, 256-color,
  and monochrome, including full, delta, changed-row, and adaptive encoders.
- Resize-storm coverage performs 10,000 renders across the five modes.
- Runtime-constructed Unicode paths cover spaces, escaped Persian-script test
  data, and emoji without embedding non-English repository prose.
- Video and audio queues are bounded, late frames are dropped, and decoder
  generations are terminated and joined during seek and cleanup.
- Previous ten-second live runs at 120x40 and 30 FPS completed without missed
  deadlines for Default and Colored Half-Block. These measurements are
  historical POC evidence, not a portable performance guarantee.
- Previous all-mode source playback and an injected main-thread panic left no
  decoder process behind. Physical console-close and hard-kill behavior remain
  outside that evidence.

## Current environment boundary

The 2026-08-26 local release-preparation shell has no usable Rust toolchain,
Visual Studio linker, or Windows SDK. Compilation, formatting, Clippy, and Rust
tests must not be reported as locally passing in this shell. The hosted Windows
CI result is required before a version tag can be created.

The portable workflow additionally builds FFmpeg twice from pinned source,
audits configuration and licenses, builds the player twice, assembles two
packages, runs clean-extraction runtime tests in a Unicode path, and requires
bit-for-bit identical binaries and all seven release assets. Only the final
tag-only job has write permission.

## Remaining limitations and manual checks

- Measure ten-minute end-to-end A/V skew with independent display/audio capture.
- Measure synchronization recovery after repeated forward and backward seeks.
- Repeat live 120x40 and 200x60 terminal-paint benchmarks for ten minutes.
- Exercise physical Ctrl+C, audio-device removal, child crash, and console close.
- Test combining-mark and near-long-path media paths. Automated Windows tests
  reject UNC syntax before filesystem access and accept canonical local files.
- Validate the unsigned MSVC binary on additional clean Windows 10 and Windows
  11 x64 systems outside the hosted-runner environment.
- Hard process termination cannot run RAII terminal restoration.
