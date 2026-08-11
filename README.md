# terminal-video-player

A Windows-first terminal media player proof of concept. It renders local images,
GIFs, and videos with color or grayscale terminal glyphs in an interactive VT
terminal. Video and audio are decoded by pinned FFmpeg sidecars; audio is sent
directly to WASAPI through CPAL.

This repository implements the technical proof-of-concept tier. It is not yet a
signed installer or a stable release.

## Supported scope

- Windows 11 x64, Windows Terminal, and PowerShell 7 are the release-blocking
  development target.
- PNG, JPEG, and GIF use the pure-Rust `image` decoder.
- Other local inputs are probed and decoded by bundled `ffprobe.exe` and
  `ffmpeg.exe`. Their container and codec support is limited to what is enabled
  in the pinned FFmpeg build.
- Video defaults to at most 30 FPS (an explicit override may request up to 60)
  and a 640x360 intermediate RGB frame.
- Five display modes are available independently of ANSI update strategy:
  Default, Classic ASCII, Detailed ASCII, Gradient, and Colored Half-Block.
  The first four map one sampled pixel to a luminance glyph; Half-Block packs
  two vertically sampled pixels into one terminal cell.
- Audio is normalized to signed 16-bit, 48 kHz stereo PCM and played through the
  default WASAPI output device.
- The WASAPI predicted-playback timestamp is the master clock. Late video frames
  are dropped; seek restarts both decoder processes at the same absolute time.
- Paths are kept as `Path`/`OsString` values and are never inserted into a shell
  command string.

Not included: YouTube, subtitles, webcams, network streams, playback speed,
ARM64, installers, automatic updates, or production branding.

## Developer setup

Install the Rust MSVC toolchain and Visual Studio 2022 Build Tools with the
Desktop development with C++ workload and a Windows 11 SDK. No FFmpeg
development headers, vcpkg, LLVM, libmpv, or ASIO SDK are required.

```powershell
rustup toolchain install 1.97.1-x86_64-pc-windows-msvc
.\scripts\Fetch-Ffmpeg.ps1
cargo build --release --locked
```

The fetch script is compatible with Windows PowerShell 5.1 and PowerShell 7. It
downloads one exact artifact, verifies SHA-256 before extraction, rejects GPL or
nonfree build flags, and writes only under this checkout.

## Run

```powershell
$env:TERMINAL_VIDEO_PLAYER_FFMPEG_DIR = "$PWD\tools\ffmpeg"
cargo run --release --locked -- "C:\Media\sample-video.mp4"
cargo run --release --locked -- "C:\Media\sample-video.mp4" --display-mode detailed-ascii
cargo run --release --locked -- "C:\Media\sample-video.mp4" --display-mode gradient
cargo run --release --locked -- "C:\Media\sample-video.mp4" --display-mode half-block
cargo run --release --locked -- "C:\Media\sample-video.mp4" --start-muted
cargo run --release --locked -- "C:\Media\photo.png" --display-mode classic-ascii --color mono
cargo run --release --locked -- "C:\Media\photo.png" --display-mode half-block
cargo run --release --locked -- "C:\Media\animation.gif" --display-mode half-block --loop
```

### Display modes

When a video is launched with interactive input and no `--display-mode`, the
application opens its alternate-screen session and asks:

```text
1. Default
2. Classic ASCII
3. Detailed ASCII
4. Gradient
5. Colored Half-Block
```

Press `1` through `5` to select immediately. Enter with no selection chooses
Default. An invalid key prints a short correction; `Q`, Escape, or Ctrl+C
cancels and restores the terminal without starting FFmpeg decoder processes.

Use an explicit mode to skip the menu:

```powershell
terminal-video-player "C:\Media\movie.mp4" --display-mode default
terminal-video-player "C:\Media\movie.mp4" --display-mode classic-ascii
terminal-video-player "C:\Media\movie.mp4" --display-mode detailed-ascii
terminal-video-player "C:\Media\movie.mp4" --display-mode gradient
terminal-video-player "C:\Media\movie.mp4" --display-mode half-block
```

Piped or otherwise non-interactive input never waits for the selector and uses
Default unless an explicit mode is supplied. Image and GIF launches do not
prompt, but `--display-mode` applies to them.

The ramps are ordered darkest to brightest:

| Mode | Character ramp |
| --- | --- |
| Default | ` .:-=+*#%@` |
| Classic ASCII | ` .:-=+*#%@` |
| Detailed ASCII | ` .-':_,^=;><+!rc*/z?sLTv)J7(\|Fi{C}fI31tlu[neoZ5Yxjya]2ESwqkP6h9d4VpOGbUAKXHm8RD#$Bg0MNWQ%&@` |
| Gradient | ` ░▒▓█` |
| Colored Half-Block | `▀` (U+2580), with independent upper and lower colors |

Default intentionally preserves the pre-selector renderer exactly, so it is
currently visually equivalent to Classic ASCII. The four character modes
change glyph density only. Colored Half-Block instead doubles vertical source
sampling: each terminal cell uses `▀` (U+2580), the upper sample as foreground,
and the lower sample as background. Truecolor emits `38;2` foreground and
`48;2` background SGR sequences; 256-color mode uses `38;5` and `48;5`.
Monochrome deterministically thresholds the upper and lower BT.709 luminance at
128 and chooses space, `▀`, `▄`, or `█`.

All five modes work with still images, GIFs, and FFmpeg-decoded video.
`--renderer adaptive|full|delta|rows` controls ANSI updates: `adaptive`, the
default, chooses the smallest encoded payload for each frame; `full` redraws the
whole grid; `delta` writes only changed cell runs; and `rows` rewrites each
changed row. The first frame and a resized grid are cleared and fully drawn.
Half-Block output resets active colors at row/run, frame, menu, and
terminal-session boundaries so its background color cannot bleed into status
text or restored shell output. Existing
`--color auto|truecolor|color256|mono` behavior remains independent of update
strategy. Runtime mode switching is not implemented.

Controls:

| Key | Action |
| --- | --- |
| `Space` | Pause or resume |
| `Left` / `Right` | Seek backward or forward five seconds |
| `M` | Mute or unmute |
| `Q` / `Esc` / `Ctrl+C` | Quit |

Useful diagnostics:

```powershell
cargo run --release --locked -- diagnostics
cargo run --release --locked -- benchmark --display-mode gradient --seconds 10 --live
cargo run --release --locked -- benchmark --display-mode half-block --seconds 10 --live
cargo run --release --locked -- restore-terminal
```

If audio-device negotiation fails, retry with `--no-audio`. If the terminal was
interrupted too abruptly to run cleanup, use `terminal-video-player
restore-terminal` when installed on `PATH`, or
`.\terminal-video-player.exe restore-terminal` from a portable ZIP. Closing and
reopening the terminal tab is the final fallback.

## Tests

```powershell
cargo fmt --all -- --check
cargo check --all-targets --locked
cargo clippy --all-targets --locked -- -D warnings
cargo test --all-targets --locked
```

The opt-in FFmpeg integration tests require the pinned sidecars and generated
test media. See the [validation ledger](docs/VALIDATION.md) for their existing
command and the current evidence boundaries.

## Package the POC

```powershell
.\scripts\Package-Poc.ps1
```

The script builds an untracked ZIP under `artifacts\`, includes the entire pinned
FFmpeg runtime directory, notices, provenance, per-file hashes, and an archive
SHA-256 checksum. It regenerates the sidecar directory from the verified
artifact before packaging. A `-SkipBuild` archive is labeled
`unverified-build`; it is useful only for local verification and does not prove
the declared MSVC build gate. The script does not install anything, change
`PATH`, sign, publish, or commit binaries.

See [architecture](docs/ARCHITECTURE.md), [FFmpeg provenance](docs/FFMPEG.md),
the [dependency inventory](docs/DEPENDENCIES.md), the
[portable package guide](docs/PORTABLE.md), and the
[validation ledger](docs/VALIDATION.md).

## License

The Rust application is [MIT licensed](LICENSE). Packaged FFmpeg binaries are
separate works with their own LGPLv3-or-later and component obligations. See
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Licensing notes are
engineering guidance, not legal advice.
