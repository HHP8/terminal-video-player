# Third-party notices

The `terminal-video-player` Rust source is distributed under the MIT license.
Its Rust dependency inventory is locked by `Cargo.lock`; each dependency remains
under its own license.

## FFmpeg

POC packages use the exact BtbN Windows x64 LGPL shared FFmpeg artifact recorded
in `third-party/ffmpeg-artifact.json`.

- Upstream: <https://ffmpeg.org/>
- Corresponding source commit:
  `ce3c09c101c83add623774d414a9f9498caf5c25`
- Build recipe commit:
  `7a83528ea3431e9eca982a712bc3a7cd0789d5d0`
- Expected posture: LGPLv3-or-later (`--enable-version3 --enable-shared
  --disable-static`) with neither `--enable-gpl` nor `--enable-nonfree`

The fetch process records the actual `ffmpeg -version` and `ffmpeg -buildconf`
output. Packaging must stop if the denylisted flags are found. The executable,
DLLs, build metadata, corresponding source location, and license material must
travel together.

FFmpeg's license depends on its exact build configuration and enabled external
libraries. The BtbN build scripts being MIT-licensed does not change the license
of the produced FFmpeg binaries. Codec patent requirements can also vary by
jurisdiction.

## Rust dependencies

The exact direct dependency metadata and locked-graph counts are recorded in
`docs/DEPENDENCIES.md`. This includes Apache-2.0-only CPAL and a transitive
Unicode-3.0 license expression. The POC package does not yet contain all Rust
dependency license texts.

Before a public release, generate and review a machine-readable notice bundle
with `cargo-about` or `cargo-deny`, publish an SBOM, and resolve every license
choice. No such review is claimed complete by this POC.

## Redistribution status

The generated POC ZIP is for local evaluation only. Public redistribution is
blocked until the enabled FFmpeg external libraries and the Rust graph have a
complete, reviewed license/source/notice bundle. A verified archive hash and the
absence of `--enable-gpl`/`--enable-nonfree` do not by themselves complete that
review.
