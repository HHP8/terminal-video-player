# Terminal Video Player Portable Prerelease

Run `terminal-video-player.exe --help` for command-line options. The bundled
FFmpeg tools are under `tools/ffmpeg` and are selected automatically when the
player is launched from this directory unless `--ffmpeg-dir` or
`TERMINAL_VIDEO_PLAYER_FFMPEG_DIR` explicitly selects another tool directory.

This prerelease is a proof of concept for Windows 10 or later and Windows
Terminal. It is not an installer and does not modify the system. Extract the
entire ZIP before running it.

Verify the downloaded ZIP in PowerShell before extraction:

```powershell
Get-FileHash -Algorithm SHA256 .\terminal-video-player-v0.1.1-portable-windows-x86_64.zip
Get-Content .\terminal-video-player-v0.1.1-portable-windows-x86_64.zip.sha256
```

The two hashes must match. Package files are additionally recorded in
`manifest/PACKAGE-MANIFEST.json` and `manifest/SHA256SUMS`.

FFmpeg is an independent third-party program under LGPL 2.1 or later. The
portable package contains its applicable license notices and build provenance.
The exact corresponding source and rebuild material are published as a
separate asset on the same GitHub prerelease.

The Rust dependency license and notice files detected from the exact locked
release graph are under `licenses/Rust`, together with a hashed inventory.

Supported portable video/audio containers are AVI, FLAC, Matroska/WebM,
MOV/MP4, MP3, MPEG-TS, Ogg, and WAV. Allowlisted decoders cover AAC, AV1, FLAC,
H.264, HEVC, MP3, MPEG-4 Part 2, Opus, PCM S16LE, Vorbis, VP8, and VP9. PNG,
JPEG, and GIF are decoded by the player itself. Network access, subtitles,
hardware acceleration, external codec libraries, and other FFmpeg functionality
are deliberately absent.

Media paths must resolve to a local Windows drive. UNC paths, device paths,
and mapped network drives are rejected before probing.

Example:

```powershell
.\terminal-video-player.exe '.\media\movie.mp4' --display-mode half-block
```

Display modes are `default`, `classic-ascii`, `detailed-ascii`, `gradient`,
and `half-block`. This package remains an unsigned prerelease proof of concept.
