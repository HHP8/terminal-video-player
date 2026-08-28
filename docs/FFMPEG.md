# FFmpeg Setup, Build, and Licensing Boundary

Terminal Video Player does not link statically or dynamically to FFmpeg
libraries. It starts separate `ffprobe.exe` and `ffmpeg.exe` processes with
individual arguments, reads JSON, RGB, and PCM data through pipes, and contains
the processes with a Windows Job Object.

The historical `v0.1.0` source-only prerelease has no binary assets and remains
unchanged. The portable pipeline introduced for `v0.1.1` does not use BtbN,
Gyan, or any other prebuilt FFmpeg binary.

## Reviewed portable build

The workflow builds FFmpeg 9.0.1 from the official `ffmpeg.org` release archive
for upstream tag `n9.0.1`, commit
`bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa`. It verifies the archive byte size
and SHA-256, detached signature, vendored signing-key SHA-256, and signing-key
fingerprint before extraction or execution.

The cross-toolchain is the version-specific llvm-mingw 20260616 UCRT artifact
with LLVM 22.1.8. Its archive identity, source recipe commit, incorporated
component source revisions, licenses, and SHA-256 are recorded in
[`../third-party/ffmpeg-artifact.json`](../third-party/ffmpeg-artifact.json).
The resulting executables import only allowlisted Windows system DLLs and UCRT
API-set forwarders. This includes the console and internal UCRT API-set
contracts `api-ms-win-crt-conio-l1-1-0.dll` and
`api-ms-win-crt-private-l1-1-0.dll`; no redistributable runtime DLL is bundled.

Configuration starts with `--disable-everything`. It disables autodetection,
network access, shared libraries, documentation, debug information, and x86
assembly, then enables only `ffmpeg`, `ffprobe`, static linking, the reviewed
built-in libraries, and the exact component allowlist in
[`../third-party/ffmpeg-components.json`](../third-party/ffmpeg-components.json).
It rejects `--enable-gpl`, `--enable-nonfree`, `--enable-version3`, all external
`--enable-lib*` options, TLS, hardware acceleration, and other prohibited
configuration terms.

The minimal build accepts only local file and pipe protocols. Its supported
demuxers are AVI, FLAC, Matroska/WebM, MOV/MP4, MP3, MPEG-TS, Ogg, and WAV. Its
allowlisted decoders are AAC, AV1, FLAC, H.263, H.264, HEVC, MP3, MPEG-4 Part 2,
Opus, PCM S16LE, Vorbis, VP8, and VP9. H.263 decoding and encoding are required
internal selections of FFmpeg's MPEG-4 Part 2 implementation. The native
MPEG-4 and AAC encoders, MOV muxer, and required lavfi sources and filters exist
only to generate test media. The AC-3 parser is an internal selection of the
MOV muxer and does not enable AC-3 decoding. The configured `pcm_s16le` muxer
is exposed by FFmpeg at runtime under the short format name `s16le`, which the
player uses for its raw PCM audio pipe. FFmpeg's `ffmpeg` command-line program
also selects its built-in `anull`, `atrim`, `crop`, `hflip`, `null`, `rotate`,
`transpose`, `trim`, and `vflip` filters; they are recorded explicitly even
though the player does not request them directly.

Playback still passes `-protocol_whitelist file,pipe` before every FFmpeg input,
so local playlists and manifests cannot resolve nested HTTP or other network
resources.

## License determination and compliance bundle

The reviewed configuration uses FFmpeg built-in LGPL-compatible functionality
only and does not enable GPL, nonfree, version3, or external codec libraries.
The expected FFmpeg license is `LGPL-2.1-or-later`. The audit executes
`ffmpeg -L` and `ffmpeg -buildconf`, compares generated component macros with
the exact allowlist, rejects unexpected PE imports, and fails closed on any
configuration or license mismatch.

Each portable package carries FFmpeg's `LICENSE.md`, the complete LGPL 2.1
text, runtime build configuration, component inventory, binary hashes, PE
imports, and toolchain notices. The same GitHub prerelease separately publishes
the exact verified upstream source archive and signature, vendored verification
key, all local patches (currently none), complete build scripts, configuration,
audit evidence, rebuild instructions, source manifest, and hashes. This
accompanying corresponding-source bundle is the project's conservative method
for satisfying source-access obligations for the exact binaries.

FFmpeg is an independent third-party program. This project does not claim to
author, own, endorse, or represent FFmpeg upstream.

## Source-checkout setup

Outside the portable prerelease, put compatible `ffmpeg.exe` and `ffprobe.exe`
in one directory and select it with `--ffmpeg-dir` or
`TERMINAL_VIDEO_PLAYER_FFMPEG_DIR`. The runtime verifies its configured version
and prohibited flags. A source checkout does not automatically download an
unreviewed prebuilt binary.

The reviewed minimal build can be reconstructed with the documented Ubuntu
environment and [`../scripts/release/build-ffmpeg.sh`](../scripts/release/build-ffmpeg.sh).
See [`RELEASING.md`](RELEASING.md) and the rebuilding instructions included in
the corresponding-source bundle.

Authoritative upstream references:

- [FFmpeg download and source releases](https://ffmpeg.org/download.html)
- [FFmpeg legal guidance](https://ffmpeg.org/legal.html)
- [FFmpeg license documentation](https://ffmpeg.org/doxygen/trunk/md_LICENSE.html)
- [FFmpeg source repository](https://github.com/FFmpeg/FFmpeg)
