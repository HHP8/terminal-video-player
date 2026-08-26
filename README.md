# Terminal Video Player

Terminal Video Player is a Windows-first Rust proof of concept that renders
local images, animated GIFs, and videos inside a VT-compatible terminal. It can
produce colored or monochrome character art, including a Colored Half-Block
mode with independent foreground and background colors, while playing decoded
audio through the default Windows audio device.

The project is source-only and remains a proof of concept. It has no installer,
signed executable, portable archive, stable API, or binary release. Users build
the application from source and provide a compatible FFmpeg installation for
video and audio playback.

## Features

- PNG and JPEG still images plus animated GIF playback through the Rust
  `image` crate.
- Local video and audio decoding through separately invoked `ffprobe.exe` and
  `ffmpeg.exe`; the Rust application does not link to FFmpeg libraries.
- Five display modes: Default, Classic ASCII, Detailed ASCII, Gradient, and
  Colored Half-Block.
- Truecolor, 256-color, monochrome, and automatic color selection.
- Full-frame, delta-run, changed-row, and per-frame adaptive ANSI updates.
- Pause, seek, mute, looping, resize handling, and best-effort terminal
  restoration.
- Bounded video/audio queues, a 640x360 maximum intermediate video frame, and
  explicit GIF dimension, frame-count, and aggregate decoded-memory limits.
- Local-only FFmpeg protocol policy. Nested network resources in playlists or
  manifests are not permitted.
- Rendering benchmarks, Unicode-path tests, resize stress coverage, and
  opt-in FFmpeg integration tests.

## Supported environment and media

The current development target is Windows 11 x64 with Windows Terminal or
another interactive terminal that supports ANSI/VT sequences. Source builds
use the Rust 1.97.1 MSVC toolchain, Visual Studio 2022 Build Tools with the
Desktop development with C++ workload, and a Windows SDK.

PNG, JPEG, and GIF are decoded directly. Other local files are handled by the
configured FFmpeg build, so actual container and codec support depends on that
build. The checked setup uses the exact LGPL shared build recorded in
[`third-party/ffmpeg-artifact.json`](third-party/ffmpeg-artifact.json).

Network URLs and network resources referenced by local playlists are outside
the supported scope. The player also does not support YouTube, subtitles,
webcams, playback-speed control, ARM64, automatic updates, or production
branding.

## Build from source

1. Install [Rustup](https://rustup.rs/) and Visual Studio 2022 Build Tools with
   the Desktop development with C++ workload and a Windows SDK.
2. Clone this repository and enter its directory.
3. Install the pinned toolchain and obtain the supported FFmpeg build.
4. Build with the locked dependency graph.

```powershell
rustup toolchain install 1.97.1-x86_64-pc-windows-msvc `
  --profile minimal --component rustfmt,clippy
.\scripts\Fetch-Ffmpeg.ps1
cargo build --release --locked
```

The FFmpeg helper supports Windows PowerShell 5.1 and PowerShell 7. It downloads
the exact external archive named in the manifest, verifies its SHA-256 before
extraction, rejects GPL or nonfree build flags, and installs it only into
directories inside the repository checkout. The default destinations are
ignored by Git. The archive, executables, and DLLs are never source controlled
or redistributed by this repository.

To use a separately installed matching build, put `ffmpeg.exe` and
`ffprobe.exe` in one directory and pass that directory with `--ffmpeg-dir`, or
set `TERMINAL_VIDEO_PLAYER_FFMPEG_DIR`. Runtime validation requires the expected
version token and build flags from the manifest.

See [FFmpeg setup and licensing](docs/FFMPEG.md) for the exact boundary.

## Playback examples

These examples use the locally fetched tools without changing the system
`PATH`:

```powershell
$env:TERMINAL_VIDEO_PLAYER_FFMPEG_DIR = `
  (Resolve-Path '.\tools\ffmpeg').Path

.\target\release\terminal-video-player.exe `
  'C:\Media\movie.mp4'
.\target\release\terminal-video-player.exe `
  'C:\Media\movie.mp4' --display-mode detailed-ascii
.\target\release\terminal-video-player.exe `
  'C:\Media\movie.mp4' --display-mode half-block --start-muted
.\target\release\terminal-video-player.exe `
  'C:\Media\photo.png' --display-mode gradient --color mono
.\target\release\terminal-video-player.exe `
  'C:\Media\animation.gif' --display-mode half-block --loop
```

Paths are retained as Windows path values and passed to child processes as
separate arguments. They are never interpolated into a shell command string.

## Keyboard controls

| Key | Action |
| --- | --- |
| `Space` | Pause or resume |
| `Left` / `Right` | Seek backward or forward five seconds |
| `M` | Mute or unmute |
| `Q` / `Esc` / `Ctrl+C` | Quit |

An interactive video launch without `--display-mode` shows a five-choice menu.
Press `1` through `5` to select immediately, or press Enter for Default. `Q`,
Escape, and Ctrl+C cancel before decoder processes start. Non-interactive input
uses Default unless a mode is supplied explicitly. Still images and GIFs do not
show the selector.

## Display modes

| Mode | Character ramp or cell form |
| --- | --- |
| Default | ` .:-=+*#%@` |
| Classic ASCII | ` .:-=+*#%@` |
| Detailed ASCII | ` .-':_,^=;><+!rc*/z?sLTv)J7(\|Fi{C}fI31tlu[neoZ5Yxjya]2ESwqkP6h9d4VpOGbUAKXHm8RD#$Bg0MNWQ%&@` |
| Gradient | ` ░▒▓█` |
| Colored Half-Block | `▀` with independent upper and lower colors |

Default intentionally retains the original short ramp and is currently
visually equivalent to Classic ASCII. The first four modes map one sampled
pixel to a luminance glyph. Colored Half-Block samples two vertical pixels per
terminal cell: the upper sample is foreground, the lower sample is background,
and the displayed glyph is `▀`.

Truecolor uses `38;2` and `48;2` SGR sequences. The 256-color path uses `38;5`
and `48;5`. Monochrome thresholds the two BT.709 luminance values and chooses
space, `▀`, `▄`, or `█`. All five modes work for still images, GIFs, and video.

The Detailed ASCII ramp is adapted from tplay under the MIT License; see
[Attribution](#attribution) and
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

## Color and ANSI update strategies

`--color auto|truecolor|color256|mono` controls color capability independently
of the display mode. `--renderer adaptive|full|delta|rows` controls terminal
updates:

- `adaptive` encodes every available strategy and chooses the smallest payload
  for the current frame.
- `full` redraws the complete grid.
- `delta` writes only changed cell runs.
- `rows` rewrites each changed row.

The first frame and a resized grid are cleared and fully drawn. Color state is
reset at run, row, frame, menu, and terminal-session boundaries so Half-Block
background colors do not bleed into status text or the restored shell.

## Diagnostics and testing

```powershell
$env:TERMINAL_VIDEO_PLAYER_FFMPEG_DIR = `
  (Resolve-Path '.\tools\ffmpeg').Path

cargo run --release --locked -- diagnostics
cargo run --release --locked -- benchmark `
  --display-mode half-block --seconds 10 --live
cargo run --release --locked -- restore-terminal

cargo fmt --all -- --check
cargo check --all-targets --locked
cargo clippy --all-targets --locked -- -D warnings
cargo test --all-targets --locked
```

The opt-in FFmpeg integration tests require the supported FFmpeg tools and a
generated local fixture:

```powershell
.\scripts\Generate-TestMedia.ps1 -DurationSeconds 10
$env:TERMINAL_VIDEO_PLAYER_TEST_MEDIA = `
  (Resolve-Path '.\.cache\test-media\flash-click-1920x1080-10s.mp4').Path
cargo test --test ffmpeg_smoke --locked -- --ignored --nocapture
```

Generated fixtures, reports, binaries, FFmpeg files, and build output are
ignored. See the [validation ledger](docs/VALIDATION.md) for current evidence
and the remaining manual checks.

If audio-device negotiation fails, retry with `--no-audio`. If a sudden
termination leaves the terminal altered, run
`terminal-video-player restore-terminal`; closing and reopening the terminal tab
is the final fallback.

## Known limitations

- This is an unsigned Windows-only proof of concept, not a stable release.
- Variable-frame-rate video is normalized and does not preserve every source
  presentation timestamp.
- External end-to-end A/V skew and post-seek recovery measurements remain
  incomplete.
- FFmpeg children are assigned to a kill-on-close Job Object immediately after
  spawn, leaving a small pre-assignment interval.
- A hard process kill cannot execute terminal-restoration cleanup.
- GIFs are preloaded for looping, but are limited to 4096x4096 pixels, 10,000
  frames, 256 MiB of retained decoded RGB data, and a 256 MiB decoder allocation
  budget.
- Windows Terminal cell pixel dimensions are not detected automatically;
  `--cell-aspect` is configurable.
- This repository does not distribute FFmpeg, executables, DLLs, installers, or
  portable archives.

## Attribution

Terminal Video Player was independently developed as a separate project and
was inspired in part by [tplay](https://github.com/maxcurzi/tplay). It is not an
official fork, and it is not affiliated with or endorsed by tplay or its
author. The Detailed ASCII character ramp was adapted from tplay and retains
the required MIT attribution in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

No tplay name, logo, screenshots, branding, or README prose is used for this
project.

## Contributing, security, and conduct

Contributions are welcome. Read [`CONTRIBUTING.md`](CONTRIBUTING.md), report
vulnerabilities according to [`SECURITY.md`](SECURITY.md), and follow
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## License

First-party source is licensed under the [MIT License](LICENSE). Dependencies
and attributed material remain under their respective licenses. See
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) and the
[locked Rust dependency inventory](third-party/rust-dependencies.csv).
