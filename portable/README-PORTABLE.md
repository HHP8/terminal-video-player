# Terminal Video Player Portable Prerelease

Run `terminal-video-player.exe --help` for command-line options. The bundled
FFmpeg tools are under `tools/ffmpeg` and are selected automatically when the
player is launched from this directory.

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
