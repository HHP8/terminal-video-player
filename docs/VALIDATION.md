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

GitHub Actions repeats the four Cargo checks on `windows-2022` with read-only
repository permissions.

## FFmpeg integration checks

These tests are ignored by default because they require external FFmpeg tools
and generated media:

```powershell
.\scripts\Fetch-Ffmpeg.ps1
.\scripts\Generate-TestMedia.ps1 -DurationSeconds 10
$env:TERMINAL_VIDEO_PLAYER_FFMPEG_DIR = `
  (Resolve-Path '.\tools\ffmpeg').Path
$env:TERMINAL_VIDEO_PLAYER_TEST_MEDIA = `
  (Resolve-Path '.\.cache\test-media\flash-click-1920x1080-10s.mp4').Path
cargo test --test ffmpeg_smoke --locked -- --ignored --nocapture
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

The 2026-08-26 local release-preparation shell can run Rust formatting and the
external FFmpeg tools, but it cannot link Rust test binaries: the installed
MSVC toolchain has no Visual Studio linker/Windows SDK configured, and the local
GNU toolchain includes `dlltool.exe` but not the assembler that it invokes.
Compilation, Clippy, and Rust tests must not be reported as locally passing in
this shell. The hosted Windows CI result is the required executable validation
before public visibility is enabled.

## Remaining limitations and manual checks

- Measure ten-minute end-to-end A/V skew with independent display/audio capture.
- Measure synchronization recovery after repeated forward and backward seeks.
- Repeat live 120x40 and 200x60 terminal-paint benchmarks for ten minutes.
- Exercise physical Ctrl+C, audio-device removal, child crash, and console close.
- Test combining-mark, UNC, and near-long-path media paths.
- Validate any future MSVC binary on a clean Windows 11 x64 system. No binary is
  created or published by this source release.
- Hard process termination cannot run RAII terminal restoration.
