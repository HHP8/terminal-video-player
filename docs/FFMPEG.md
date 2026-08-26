# FFmpeg Setup and Licensing Boundary

Terminal Video Player does not link statically or dynamically to FFmpeg
libraries. It starts separate `ffprobe.exe` and `ffmpeg.exe` processes with
individual arguments, reads JSON/raw RGB/raw PCM from pipes, and contains the
decoder processes with a Windows Job Object.

This public repository contains source and setup instructions only. It does not
contain or publish FFmpeg executables, DLLs, codecs, downloaded archives,
installers, portable ZIPs, or binary release assets. The historical v0.1.0
source-only prerelease has no attached assets and does not redistribute FFmpeg.

## Supported local setup

The runtime expects `ffmpeg.exe` and `ffprobe.exe` in one directory. Choose the
directory with `--ffmpeg-dir` or `TERMINAL_VIDEO_PLAYER_FFMPEG_DIR`.

For reproducible local development, the optional helper downloads the exact
external artifact recorded in
[`../third-party/ffmpeg-artifact.json`](../third-party/ffmpeg-artifact.json):

```powershell
.\scripts\Fetch-Ffmpeg.ps1
$env:TERMINAL_VIDEO_PLAYER_FFMPEG_DIR = `
  (Resolve-Path '.\tools\ffmpeg').Path
```

The helper verifies the pinned SHA-256 before extraction, validates the runtime
version token and build flags, downloads the named license files, and writes
only inside the checkout. Its default destination and cache paths are ignored
by Git. Do not run the helper elevated.

Runtime validation requires:

```text
--enable-version3
--enable-shared
--disable-static
```

and rejects:

```text
--enable-gpl
--enable-nonfree
```

Playback also passes `-protocol_whitelist file,pipe` before each input. This
enforces the documented local-only model and prevents a local playlist or
manifest from resolving nested HTTP or other network protocols.

## Redistribution decision

The selected artifact is an LGPL-oriented shared build, but its configuration
enables numerous external libraries. Verifying only the archive hash, FFmpeg
version, and absence of `--enable-gpl` or `--enable-nonfree` does not establish
all notices, patent considerations, corresponding-source obligations, or
redistribution requirements for every enabled component.

Therefore the supported public model is user-provided FFmpeg. Redistributing
the selected FFmpeg archive, executables, DLLs, or a package that contains them
is outside this project and outside this release. A future binary-distribution
proposal must review the exact build configuration and every enabled component,
preserve all required notices, establish corresponding-source compliance, and
receive an appropriate legal review before publication.

Authoritative upstream references:

- [FFmpeg download policy](https://ffmpeg.org/download.html)
- [FFmpeg legal guidance](https://ffmpeg.org/legal.html)
- [FFmpeg source](https://github.com/FFmpeg/FFmpeg)
- [BtbN FFmpeg Builds](https://github.com/BtbN/FFmpeg-Builds)
