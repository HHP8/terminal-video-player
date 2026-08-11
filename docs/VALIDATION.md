# POC validation ledger

This ledger separates measured evidence from architecture targets. The
subprocess backend is suitable for continued POC evaluation, but it has **not**
passed the MVP architecture gate because external A/V skew and post-seek
recovery remain unmeasured.

## Test environment

- Date: 2026-07-30
- OS: Microsoft Windows 11 Pro Insider Preview, 10.0.26220, x64
- Terminal: Windows Terminal 1.24.11911.0
- Shell: PowerShell 7.6.4
- CPU: Intel Core i7-8550U, 8 logical processors
- Memory: 15.9 GiB
- Verification compiler: Rust 1.97.1
  (`x86_64-pc-windows-gnu`, LLVM 22.1.6), GCC 16.1.0
- Intended release target: `x86_64-pc-windows-msvc`
- FFmpeg: `n8.1.2-21-gce3c09c101-20260630`
- Timing fixture: 10-second 1920x1080 H.264/AAC flash/click MP4,
  SHA-256
  `dcfe2bf91fa293c67671ca4ec0ff07df2dffe05615e3842bfee9695dc5bab0f9`

The GNU toolchain is project-local and was used only because this machine lacks
the Visual C++ linker and Windows SDK. `cargo +1.97.1-x86_64-pc-windows-msvc
check --locked` fails with `linker link.exe not found`. No system toolchain was
installed or modified.

## Gate status

| Gate | Target | Evidence and current state |
| --- | --- | --- |
| 120x40 truecolor | 30 FPS for 10 minutes, under 5% scheduler drops | **Partial pass.** Ten-second full-noise live runs cover all five display modes. The final Default and Colored Half-Block runs each rendered 300/300 frames at 30.0 FPS with zero missed deadlines; the other character modes also passed in the same terminal. Ten-minute duration remains pending. |
| 200x60 truecolor | 20 FPS or automatic fallback | **Partial.** In the final three-run median comparison, the slowest CPU-only case was Colored Half-Block full-noise at 252.1 FPS and 3.891 ms/frame. The live case was skipped because the available Windows Terminal grid was 130x45; terminal paint throughput at 200x60 remains pending. |
| 1080p H.264 decode/resize | 30 FPS | **Pass for decode transport.** The final ignored integration suite decoded all 300 frames to 640x360 RGB24 in 403.9 ms. This does not measure terminal painting. |
| Ten-minute A/V skew | p95 at most 80 ms; maximum at most 150 ms | **Pending.** A warm 10-second muted-audio playback completed successfully in 11.664 seconds versus 10.423 seconds with `--no-audio`, but elapsed time is not an A/V skew measurement. Independent loopback/screen capture is still required. |
| Seek recovery | Stable synchronization within 1 second | **Pending.** Restart/cleanup paths are implemented; no external flash/click seek capture has been measured. |
| Resize storm | Correct within 250 ms; no persistent drift | **Partial.** A 10,000-render structure test (2,000 resizes in each of five display modes) passes, resize events are coalesced, and paused frames are retained and redrawn. Interactive latency and sync drift remain pending. |
| Unicode paths | Spaces, Persian, emoji, combining, long path | **Partial pass.** Pure-Rust image decoding, FFmpeg video/audio workers, packaged diagnostics, and packaged video playback pass from Unicode paths containing spaces, Persian-script characters, and emoji. Combining-mark, UNC, and near-long-path cases remain pending. |
| Cleanup | Normal, Ctrl+C, decoder error, panic, child crash | **Partial pass.** Audio-enabled playback in every display mode exits normally and leaves zero FFmpeg/ffprobe/player processes. An injected main-thread panic after alternate-screen entry exited 101, returned control to the invoking shell, and left zero media processes. Bounded-channel cancellation, selector cancellation-before-decode, Job Object, RAII, and child-failure paths have targeted coverage. A physical Ctrl+C, audio-device loss, console close, and hard-kill recovery remain pending. |
| Self-contained ZIP | Clean Windows 11 x64 VM, offline | **Partial.** The ZIP plays the 10-second fixture from a Unicode extraction path on this machine; per-file hashes and bundled diagnostics pass. A clean offline VM and MSVC-built executable remain pending. |
| License provenance | Hash/config/source/notice review | **Partial.** Artifact, license-file hashes, runtime token, and required/rejected FFmpeg flags are enforced. Complete notices and corresponding-source review for every enabled FFmpeg component remains pending, so public redistribution is blocked. |

## Live Windows Terminal measurements

Each case ran for 10 seconds at a target of 30 FPS with the adaptive truecolor
renderer. The terminal was requested at 130x45 cells, so the 160x50 and 200x60
live cases were skipped rather than reported as passes. Default and Classic
ASCII intentionally use the same ramp; small differences between their runs
are measurement variance.

| Display mode | Grid | Frames | FPS | Missed deadlines | Bytes/frame | Encode/frame | Write/frame |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Default | 80x24 | 300 | 30.0 | 0 | 35,977 | 331.0 us | 2,314.4 us |
| Default | 120x40 | 300 | 30.0 | 0 | 89,900 | 691.2 us | 4,675.2 us |
| Classic ASCII | 80x24 | 300 | 30.0 | 0 | 35,977 | 299.6 us | 2,611.3 us |
| Classic ASCII | 120x40 | 300 | 30.0 | 0 | 89,900 | 612.2 us | 6,202.0 us |
| Detailed ASCII | 80x24 | 298 | 29.8 | 2 (0.67%) | 35,978 | 293.3 us | 2,681.6 us |
| Detailed ASCII | 120x40 | 300 | 30.0 | 0 | 89,900 | 573.0 us | 5,458.7 us |
| Gradient | 80x24 | 300 | 30.0 | 0 | 39,231 | 355.4 us | 2,777.6 us |
| Gradient | 120x40 | 300 | 30.0 | 0 | 98,030 | 674.4 us | 6,557.7 us |
| Colored Half-Block | 80x24 | 300 | 30.0 | 0 | 73,914 | 604.8 us | 4,179.7 us |
| Colored Half-Block | 120x40 | 300 | 30.0 | 0 | 184,673 | 1,328.9 us | 9,559.7 us |

These figures measure application encoding and synchronous terminal writes, not
Windows Terminal CPU usage or end-to-end screen presentation latency.

## All-mode CPU and playback checks

The benchmark target exercised full, delta, row-run, and adaptive strategies
for motion and full-noise frames. It covered every display mode in Truecolor,
256-color, and monochrome at 120x40 and 200x60, plus sampling at both sizes.
The CLI comparison below interleaved three one-second runs per case and reports
the median:

| Display mode | Pattern | Grid | Median FPS | Median encode/frame | Median bytes/frame |
| --- | --- | ---: | ---: | ---: | ---: |
| Default | Motion | 120x40 | 2,601.9 | 339.5 us | 8,602 |
| Colored Half-Block | Motion | 120x40 | 1,335.6 | 702.7 us | 17,541 |
| Default | Motion | 200x60 | 1,151.6 | 766.5 us | 13,057 |
| Colored Half-Block | Motion | 200x60 | 396.5 | 2,388.2 us | 27,230 |
| Default | Noise | 120x40 | 1,307.4 | 723.8 us | 89,898 |
| Colored Half-Block | Noise | 120x40 | 603.6 | 1,618.2 us | 184,672 |
| Default | Noise | 200x60 | 623.4 | 1,538.3 us | 224,658 |
| Colored Half-Block | Noise | 200x60 | 252.1 | 3,891.0 us | 461,438 |

Half-Block carries independent foreground and background color, so its payload
is about 2.0-2.1 times Default in these fixtures. Its encoding cost was about
2.1-3.1 times Default, while the slowest case still exceeded the 20 FPS gate by
more than 12 times. The renderer keeps the existing foreground-only fast path,
and retained pre-change Default comparisons showed no consistent regression
after interleaving; isolated one-shot differences were scheduling/thermal
variance. No threshold was weakened.

The 10-second 1920x1080 Unicode-path video fixture was then played with audio
enabled and start-muted in every explicit mode:

| Display mode | Exit code | Elapsed |
| --- | ---: | ---: |
| Default | 0 | 11.783 s (cold start) |
| Classic ASCII | 0 | 10.616 s |
| Detailed ASCII | 0 | 10.574 s |
| Gradient | 0 | 10.544 s |
| Colored Half-Block | 0 | 10.534 s |

No media process remained after the five runs. This verifies the shared
decode/playback path; it is not an external A/V skew measurement.

## Automated results

The final source state produced these results:

| Command or check | Result |
| --- | --- |
| `cargo fmt --all -- --check` | Pass |
| `cargo check --all-targets --locked` | Pass with project-local GNU verifier |
| `cargo clippy --all-targets --locked -- -D warnings` | Pass |
| `cargo test --all-targets --locked` | 62 nonignored tests passed: 57 unit, 2 still/GIF all-mode tests, 1 five-mode resize-storm test, and 2 Unicode-path tests; 3 opt-in FFmpeg tests ignored by default; Criterion smoke matrix passed |
| `cargo test --test ffmpeg_smoke --locked -- --ignored --nocapture` | 3 passed; Unicode video/audio pipes, full-channel cancellation, and full 1080p fixture decode |
| Renderer benchmark target | All strategies; five modes; Truecolor, 256-color, and mono; motion/noise; 120x40 and 200x60 passed |
| Interleaved Default/Half-Block CLI comparison | 12 runs (3 repetitions x 2 modes x 2 patterns) passed at all four target grids |
| `cargo build --release --locked` | Pass with project-local GNU verifier |
| `cargo +1.97.1-x86_64-pc-windows-msvc check --locked` | Blocked: `link.exe` and the Windows SDK are absent |
| Valid/missing sidecar diagnostics | Valid runtime exits 0; missing runtime exits 1, so packaging rejects an incompatible pairing |
| Windows PowerShell 5.1 script parsing | Pass |
| Windows PowerShell 5.1 FFmpeg fetch, fixture generation, and packaging | Pass using the pinned, cached artifact |
| Extracted-package file validation | 27/27 manifest entries match SHA-256 |
| Source-tree video playback in all five display modes | Five exit-code-zero runs from a Unicode path containing spaces, Persian-script characters, and emoji; zero media processes remained |
| Injected panic after terminal entry | Exit 101, shell continued, terminal restoration hook ran, zero media processes remained |

The FFmpeg integration command additionally requires:

```powershell
$env:TERMINAL_VIDEO_PLAYER_FFMPEG_DIR = "$PWD\tools\ffmpeg"
$env:TERMINAL_VIDEO_PLAYER_TEST_MEDIA = `
  "$PWD\.cache\test-media\flash-click-1920x1080-10s.mp4"
cargo test --test ffmpeg_smoke --locked -- --ignored --nocapture
```

The Unicode worker test copies the supplied fixture to a runtime-constructed
path containing spaces, Persian-script code points, and emoji before decoding.

## Current local-evaluation artifact

The package is intentionally labeled `unverified-build`: it contains the
project-local GNU verification executable, not a release-gate MSVC build.

- File:
  `terminal-video-player-0.1.0-poc-windows-x64-unverified-build.zip`
- Archive hash: recorded in the adjacent `.zip.sha256` file; that external
  checksum is authoritative because embedding an archive's own digest would
  change the archive
- Package manifest: 27 verified entries
- Public redistribution: blocked pending the complete third-party review

## Remaining manual work

1. Run the motion and noise live benchmarks for ten minutes at 120x40.
2. Use a display/font combination that can expose 200x60 cells and repeat the
   live benchmark.
3. Exercise the selector itself visually in Windows Terminal with its release
   font/background combinations; automated state-machine coverage already
   verifies all selections, invalid input, resize, and cancellation.
4. Generate a ten-minute flash/click fixture, capture display plus loopback
   audio with an independent clock, and calculate p95/maximum skew.
5. Repeat random and +/-5-second seeks while playing and paused; measure time to
   stable synchronization.
6. Exercise Q, Escape, physical Ctrl+C, decoder failure, audio-device removal,
   child crash, and console close interactively. The resize stress test and
   injected-panic check already pass.
7. Build with MSVC and validate the final ZIP on a clean offline Windows 11 x64
   VM.
8. Complete the FFmpeg component notice/source review before any public
   redistribution.

Hard kill is explicitly outside the cleanup guarantee. The recovery command is
`terminal-video-player restore-terminal` for an installed command or
`.\terminal-video-player.exe restore-terminal` inside the portable directory.
