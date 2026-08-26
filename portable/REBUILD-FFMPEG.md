# Rebuilding the Bundled FFmpeg Programs

The corresponding-source bundle contains the original verified FFmpeg 9.0.1
archive, its detached signature, the pinned FFmpeg release signing key, the
complete release scripts, configuration metadata, component allowlists,
licenses, hashes, and captured build provenance.

On a clean Ubuntu 24.04 x86-64 environment, set `SOURCE_DATE_EPOCH` to the
tagged Terminal Video Player commit timestamp and run:

```bash
scripts/release/build-ffmpeg.sh \
  --metadata third-party/ffmpeg-artifact.json \
  --components third-party/ffmpeg-components.json \
  --work /tmp/terminal-video-player-ffmpeg-rebuild \
  --output /tmp/terminal-video-player-ffmpeg-output
```

The script downloads only the pinned FFmpeg source, detached signature, and
llvm-mingw archive. It verifies every size and SHA-256, validates the release
signing-key fingerprint and PGP signature, rejects unsafe archive paths, and
then builds `ffmpeg.exe` and `ffprobe.exe` with the reviewed minimal
configuration.
