# Portable proof-of-concept package

This ZIP is an unsigned evaluation build for Windows 11 x64. It does not install
anything, change `PATH`, or require Rust, vcpkg, FFmpeg headers, WSL, or a
system-wide FFmpeg installation.

Extract the whole archive, keep `tools\ffmpeg` beside the application, and run
it from PowerShell:

```powershell
.\terminal-video-player.exe "C:\Media\sample-video.mp4"
.\terminal-video-player.exe "C:\Media\sample-video.mp4" --display-mode detailed-ascii
.\terminal-video-player.exe "C:\Media\sample-video.mp4" --display-mode gradient
.\terminal-video-player.exe "C:\Media\sample-video.mp4" --display-mode half-block
.\terminal-video-player.exe "C:\Media\sample-video.mp4" --start-muted
.\terminal-video-player.exe "C:\Media\photo.png" --display-mode classic-ascii --color mono
.\terminal-video-player.exe "C:\Media\photo.png" --display-mode half-block
.\terminal-video-player.exe "C:\Media\animation.gif" --display-mode half-block --loop
```

When an interactive video launch omits `--display-mode`, press `1` through `5`
to choose Default, Classic ASCII, Detailed ASCII, Gradient, or Colored
Half-Block. Enter chooses Default; `Q`, Escape, or Ctrl+C cancels cleanly.
Explicit
`--display-mode default|classic-ascii|detailed-ascii|gradient|half-block`
skips the menu. Piped/non-interactive input falls back to Default without
waiting. Default preserves the original ` .:-=+*#%@` ramp and is therefore
currently visually equivalent to Classic ASCII.

Colored Half-Block uses `▀` (U+2580) to pack two vertically sampled image
pixels into one terminal cell: the upper pixel is the foreground and the lower
pixel is the background. It works for still images, GIFs, and videos with every
renderer strategy. Truecolor colors both halves with `38;2`/`48;2`; 256-color
mode uses `38;5`/`48;5`. Monochrome uses a deterministic BT.709 threshold and
space/`▀`/`▄`/`█` fallback. The renderer resets foreground/background state at
render and terminal-session boundaries so Half-Block colors do not bleed into
status text or the PowerShell prompt.

Controls:

| Key | Action |
| --- | --- |
| `Space` | Pause or resume |
| `Left` / `Right` | Seek backward or forward five seconds |
| `M` | Mute or unmute |
| `Q` / `Esc` / `Ctrl+C` | Quit |

Diagnostics and recovery:

```powershell
.\terminal-video-player.exe diagnostics
.\terminal-video-player.exe benchmark --display-mode gradient --seconds 10 --live
.\terminal-video-player.exe benchmark --display-mode half-block --seconds 10 --live
.\terminal-video-player.exe restore-terminal
```

If audio setup fails, retry with `--no-audio`. If an abrupt termination leaves
the tab in an unusual state, run the recovery command or close and reopen the
terminal tab.

This POC package is not approved for public redistribution. Its FFmpeg build
contains numerous separately licensed components whose complete notice/source
bundle still requires review. It is also unsigned, and the architecture's live
ten-minute/200x60 terminal throughput and end-to-end A/V synchronization gates
remain pending.
See the [validation ledger](VALIDATION.md), [FFmpeg provenance](FFMPEG.md), and
[third-party notices](../THIRD-PARTY-NOTICES.md).
