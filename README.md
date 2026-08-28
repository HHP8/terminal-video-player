# Terminal Video Player

Terminal Video Player is a Windows-first Rust proof of concept that renders
local images, animated GIFs, and videos inside a VT-compatible terminal. It can
produce colored or monochrome character art, including a Colored Half-Block
mode with independent foreground and background colors, while playing decoded
audio through the default Windows audio device.

The project remains an unsigned prerelease proof of concept. It has no
installer, stable API, automatic updater, or production support commitment.

## Features

- PNG and JPEG still images plus animated GIF playback through the Rust
  `image` crate.
- Local video and audio decoding through separately invoked `ffprobe.exe` and
  `ffmpeg.exe`; the Rust application does not link to FFmpeg libraries.
- Five display modes: Default, Classic ASCII, Detailed ASCII, Gradient, and
  Colored Half-Block.
- Truecolor, 256-color, monochrome, and automatic color selection.
- Full-frame, delta-run, changed-row, and per-frame adaptive ANSI updates.
- Pause, seek, mute, looping, resize handling, bounded queues, and best-effort
  terminal restoration.
- Local-only FFmpeg protocol policy. Nested network resources in playlists or
  manifests are not permitted.

## Windows and media support

The supported target is Windows 10 or later on x64, with Windows Terminal or
another interactive terminal that supports ANSI/VT sequences. Source builds
use the pinned Rust 1.97.1 MSVC toolchain, Visual Studio 2022 Build Tools with
the Desktop development with C++ workload, and a Windows SDK.

PNG, JPEG, and GIF are decoded directly by the player. Still images and GIF
frames are limited to 4096x4096 pixels, with additional allocation, decoded-
byte, and frame-count limits where applicable. The portable FFmpeg
build supports local and pipe input for AVI, FLAC, Matroska/WebM, MOV/MP4, MP3,
MPEG-TS, Ogg, and WAV containers, with its allowlisted AAC, AV1, FLAC, H.263,
H.264, HEVC, MP3, MPEG-4 Part 2, Opus, PCM S16LE, Vorbis, VP8, and VP9 decoders.
H.263 is present because FFmpeg selects it internally for MPEG-4 Part 2 support.
Actual playback also depends on a file containing a supported combination.

The minimal build excludes network access, TLS, external codec libraries,
hardware acceleration, subtitles, webcams, and nonallowlisted formats. The
player does not support YouTube, playback-speed control, ARM64, or automatic
updates.

## Portable prerelease

Tagged portable prereleases contain only the player, source-built `ffmpeg.exe`
and `ffprobe.exe`, required notices, provenance, and package verification
records. FFmpeg is an independent third-party program; it is not part of
Terminal Video Player and is not linked into the Rust executable.

Download the ZIP and its `.sha256` file from the same GitHub prerelease. Verify
before extraction:

```powershell
$Zip = '.\terminal-video-player-v0.1.1-portable-windows-x86_64.zip'
$Expected = (Get-Content "$Zip.sha256").Split(' ')[0]
$Actual = (Get-FileHash -Algorithm SHA256 $Zip).Hash.ToLowerInvariant()
if ($Actual -cne $Expected) { throw 'Portable ZIP checksum mismatch.' }
```

Extract the complete ZIP to a writable directory, then run:

```powershell
.\terminal-video-player.exe --help
.\terminal-video-player.exe diagnostics
.\terminal-video-player.exe 'C:\Media\movie.mp4' --display-mode half-block
```

Maintainers and automated package verification can decode a local media file
and exercise a selected renderer without entering interactive terminal mode:

```powershell
.\terminal-video-player.exe --display-mode half-block validate-media .\sample.mp4
```

`validate-media` applies the same local-path, FFmpeg identity, protocol,
decoding, and ANSI-rendering controls as playback. It does not display or play
the media and is intended for deterministic diagnostics.

Without an explicit `--ffmpeg-dir` or `TERMINAL_VIDEO_PLAYER_FFMPEG_DIR`
override, the portable player resolves its bundled tools from `tools\ffmpeg`
beside the executable. The same release publishes the exact FFmpeg source archive, signature,
build scripts, configuration, audit evidence, source manifest, and hashes in a
separate corresponding-source ZIP. See [FFmpeg setup and licensing](docs/FFMPEG.md).

## Build from source

```powershell
rustup toolchain install 1.97.1-x86_64-pc-windows-msvc `
  --profile minimal --component rustfmt,clippy
cargo build --release --locked
```

For video, install compatible `ffmpeg.exe` and `ffprobe.exe` in one directory,
then pass `--ffmpeg-dir` or set `TERMINAL_VIDEO_PLAYER_FFMPEG_DIR`. A source
checkout does not download or trust an arbitrary prebuilt FFmpeg package.

```powershell
$env:TERMINAL_VIDEO_PLAYER_FFMPEG_DIR = 'C:\Tools\ffmpeg\bin'
.\target\release\terminal-video-player.exe diagnostics
```

Maintainers can reconstruct the reviewed minimal FFmpeg build on Ubuntu 24.04
using [`scripts/release/build-ffmpeg.sh`](scripts/release/build-ffmpeg.sh) and
the pinned metadata. The normal release path is GitHub Actions; do not manually
upload locally assembled binaries. See [`docs/RELEASING.md`](docs/RELEASING.md).

## Playback examples

```powershell
.\terminal-video-player.exe 'C:\Media\movie.mp4'
.\terminal-video-player.exe 'C:\Media\movie.mp4' --display-mode detailed-ascii
.\terminal-video-player.exe 'C:\Media\movie.mp4' --display-mode half-block --start-muted
.\terminal-video-player.exe 'C:\Media\photo.png' --display-mode gradient --color mono
.\terminal-video-player.exe 'C:\Media\animation.gif' --display-mode half-block --loop
```

Paths are passed to child processes as separate arguments and are not
interpolated into shell command strings. UNC paths, device paths, and mapped
network drives are rejected before media probing; playback accepts local
Windows-drive paths only.

## Keyboard controls

| Key | Action |
| --- | --- |
| `Space` | Pause or resume |
| `Left` / `Right` | Seek backward or forward five seconds |
| `M` | Mute or unmute |
| `Q` / `Esc` / `Ctrl+C` | Quit |

An interactive video launch without `--display-mode` shows a five-choice menu.
Press `1` through `5` to select immediately, or Enter for Default. Still images
and GIFs do not show the selector.

## Display modes

| Mode | Character ramp or cell form |
| --- | --- |
| Default | ` .:-=+*#%@` |
| Classic ASCII | ` .:-=+*#%@` |
| Detailed ASCII | ` .-':_,^=;><+!rc*/z?sLTv)J7(\|Fi{C}fI31tlu[neoZ5Yxjya]2ESwqkP6h9d4VpOGbUAKXHm8RD#$Bg0MNWQ%&@` |
| Gradient | ` ░▒▓█` |
| Colored Half-Block | `▀` with independent upper and lower colors |

Default is currently visually equivalent to Classic ASCII. Colored Half-Block
samples two vertical pixels per cell. The upper sample is foreground, the
lower sample is background, and the displayed glyph is `▀`. The Detailed ASCII
ramp is adapted from tplay under the MIT License; see [Attribution](#attribution).

## Color and ANSI updates

`--color auto|truecolor|color256|mono` controls color capability independently
of display mode. `--renderer adaptive|full|delta|rows` selects full redraws,
changed cell runs, changed rows, or the smallest encoded strategy per frame.
Color state is reset at run, row, frame, menu, and terminal-session boundaries.

## Diagnostics and testing

```powershell
cargo run --release --locked -- diagnostics
cargo run --release --locked -- benchmark --display-mode half-block --seconds 10 --live
cargo run --release --locked -- restore-terminal

cargo fmt --all -- --check
cargo check --all-targets --locked
cargo clippy --all-targets --locked -- -D warnings
cargo test --all-targets --locked
```

Ignored FFmpeg integration tests require compatible tools and generated local
media. The release workflow runs them against the newly built packaged tools.
See [`docs/VALIDATION.md`](docs/VALIDATION.md) for the exact commands and
remaining manual checks.

## Known limitations

- This is an unsigned Windows-only prerelease proof of concept.
- Variable-frame-rate video is normalized; long-duration A/V skew and repeated
  post-seek recovery measurements remain incomplete.
- FFmpeg children enter a kill-on-close Job Object immediately after spawn,
  leaving a small pre-assignment interval.
- A hard process kill cannot execute terminal-restoration cleanup.
- Still images and GIFs have explicit dimension and decoder-allocation limits.
  GIFs are preloaded for looping within additional frame-count and aggregate
  decoded-memory limits.
- Windows Terminal cell pixel dimensions are not detected automatically;
  `--cell-aspect` is configurable.
- Portable releases are prereleases because clean-machine coverage, code
  signing, long-duration playback, and production support are incomplete.

## Attribution

Terminal Video Player was independently developed as a separate project and
was inspired in part by [tplay](https://github.com/maxcurzi/tplay). It is not an
official fork and is not affiliated with or endorsed by tplay or its author.
The Detailed ASCII character ramp was adapted from tplay and retains the
required MIT attribution in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
No tplay name, logo, screenshots, branding, or README prose is used.

## Contributing, security, and license

Read [`CONTRIBUTING.md`](CONTRIBUTING.md), [`SECURITY.md`](SECURITY.md), and
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md). First-party source is licensed
under the [MIT License](LICENSE). Dependencies and attributed material retain
their own licenses; see [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) and
the [locked Rust dependency inventory](third-party/rust-dependencies.csv).
