# Source-Built FFmpeg Portable Release Design

## Status

Approved on 2026-08-26 for implementation in `HHP8/terminal-video-player`.
The implementation targets the next available semantic patch prerelease after
the unchanged source-only `v0.1.0` prerelease. The intended version is
`v0.1.1`, subject to a final remote tag and release conflict check.

## Objective

Create a tag-driven GitHub Actions pipeline that builds Terminal Video Player
and a minimal Windows FFmpeg distribution from verified source, proves that
the outputs are reproducible, validates the extracted portable package, and
publishes a public GitHub prerelease only after every compliance, security,
runtime, and integrity gate passes.

## Release Boundaries

- Preserve the project MIT license and the existing `v0.1.0` prerelease.
- Build and test the exact tagged commit with the repository's pinned Rust
  toolchain and locked dependencies.
- Publish a prerelease only. Do not publish an installer, package-manager
  package, updater, deployment, website, or signed executable.
- Treat FFmpeg as an independent third-party program invoked as a separate
  process. Terminal Video Player does not link to FFmpeg libraries.
- Do not use BtbN, Gyan, or another prebuilt FFmpeg binary.
- Do not enable GPL, nonfree, version 3, external codec, network, hardware
  acceleration, or unnecessary compression functionality.
- Stop before publication when any required input, license, source,
  reproducibility result, runtime check, or security result is unresolved.

## Pinned Inputs

### FFmpeg

- Version: `9.0.1`
- Release tag: `n9.0.1`
- Source commit: `bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa`
- Source archive:
  `https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz`
- Source archive size: `12036420` bytes
- Source SHA-256:
  `cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635`
- Detached signature:
  `https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz.asc`
- Signature SHA-256:
  `b613a00005232a1245ace7080088781ac23a916119d3e5b0d6c042368eee0177`
- Official signing key: `https://ffmpeg.org/ffmpeg-devel.asc`
- Signing-key fingerprint:
  `FCF986EA15E6E293A5644F10B4322F04D67658D8`
- Signing-key SHA-256:
  `397b3becedcd5a98769967ff1ff8501ddc89f8368b8f766e4701377d7dbaabe5`

The workflow must validate the hard-coded archive, signature, and key hashes,
verify the exact signing-key fingerprint, and verify the detached signature
before extracting or executing any source-derived output.

### Windows cross-toolchain

- Project: `mstorsjo/llvm-mingw`
- Release: `20260616`
- Source commit: `170b7e1ec4ad1d9264e6ba320cd4d02f96299c60`
- LLVM version: `22.1.8`
- Artifact:
  `llvm-mingw-20260616-ucrt-ubuntu-22.04-x86_64.tar.xz`
- Artifact URL:
  `https://github.com/mstorsjo/llvm-mingw/releases/download/20260616/llvm-mingw-20260616-ucrt-ubuntu-22.04-x86_64.tar.xz`
- Artifact size: `82188288` bytes
- Artifact SHA-256:
  `534b92e067b22a6b4441f48ae9240a3341b17825d04d577eab0cf85c44b4deda`

The toolchain is a build input and is not redistributed. Its archive must be
hash-verified before extraction. The provenance record must include the
release, source commit, artifact identity, hash, license inventory, and actual
compiler, linker, resource compiler, assembler, and runtime versions.

### GitHub-hosted environments

- Use `ubuntu-24.04` for FFmpeg cross-compilation.
- Use `windows-2025` for Terminal Video Player compilation, portable package
  assembly, and extracted-package runtime validation.
- Record the resolved image operating system, image version, image release,
  architecture, and relevant preinstalled build-tool versions.
- Do not install unversioned packages or use floating container images.
- Pin every third-party GitHub Action to a full immutable commit SHA and record
  the action repository and release associated with that SHA.

## Minimal FFmpeg Configuration

The reviewed build script starts with `--disable-everything` and explicitly
enables only verified requirements. It must build static standalone
`ffmpeg.exe` and `ffprobe.exe` programs without FFmpeg DLLs or external codec
libraries.

Required policies:

- `--disable-network`
- static libraries and programs, with shared libraries disabled
- GPL, nonfree, and version3 disabled and absent from `ffmpeg -buildconf`
- hardware acceleration and external libraries disabled
- protocols limited to `file` and `pipe`
- devices limited to the `lavfi` input used for generated validation fixtures
- filters limited to runtime and fixture needs, including `fps`, `scale`,
  `setpts`, `color`, `aevalsrc`, and `drawbox`
- encoders limited to raw video, signed 16-bit PCM, native MPEG-4 Part 2, and
  native AAC for runtime output and fixture generation
- muxers limited to raw video, signed 16-bit PCM, and the selected fixture
  container
- demuxers, parsers, and native decoders limited to the documented portable
  media set

The intended portable media set covers MP4/MOV, Matroska/WebM, AVI, MPEG-TS,
MP3, WAV, FLAC, and Ogg containers, with verified built-in decoding support for
H.264, HEVC, MPEG-4 Part 2, VP8, VP9, AV1, AAC, MP3, FLAC, Vorbis, Opus, and
PCM streams. The final enabled-component inventory is authoritative: any
component that cannot be enabled without an incompatible license or an
external dependency must be removed from the proposed portable set and
reported before publication.

Still PNG, JPEG, and GIF inputs remain decoded by the Rust `image` dependency
and are not part of FFmpeg's portable decoder surface. Source users may select
a broader compatible FFmpeg installation through the existing explicit
configuration mechanisms, but portable documentation must clearly distinguish
that option from the restricted bundled build.

## Runtime Integration

The portable layout preserves the existing deterministic lookup contract:

```text
terminal-video-player.exe
tools/ffmpeg/ffmpeg.exe
tools/ffmpeg/ffprobe.exe
```

The player must resolve the two FFmpeg tools from `tools/ffmpeg` next to the
portable executable unless an existing explicit override is deliberately used.
The application continues to pass `-protocol_whitelist file,pipe` and must not
gain automatic network access. Runtime tests must prove that a conflicting
FFmpeg earlier on `PATH` is not selected.

## Workflow Architecture

The release workflow supports pull requests and manual validation without
publication, plus an explicit semantic version tag trigger. It separates:

1. Source and metadata validation.
2. Terminal Video Player formatting, check, Clippy, and tests.
3. Two isolated FFmpeg builds from identical inputs.
4. FFmpeg license, configuration, component, and PE import audits.
5. Two isolated release executable and portable package builds.
6. Clean Windows extraction and runtime validation.
7. Bit-for-bit reproducibility comparison.
8. Final prerelease publication.

All jobs default to read-only repository permissions. Only the final
publication job receives `contents: write`, and it depends on every preceding
job succeeding. Publication additionally requires an exact semantic version
tag whose version equals the Cargo package version. Manual inputs do not accept
arbitrary URLs, filenames, tool versions, or tag values.

## Reproducibility

- Build FFmpeg and the Rust release executable twice in isolated matrix jobs.
- Assemble the complete portable package twice from matching replicas.
- Set `SOURCE_DATE_EPOCH` from the tagged commit.
- Prevent PE timestamp insertion and enable deterministic MSVC linking for the
  Rust executable.
- Remove build-directory information using deterministic source and path maps.
- Sort manifest entries and archive entries bytewise.
- Normalize ZIP entry timestamps to a fixed valid DOS timestamp.
- Exclude PDBs, logs, caches, and debug files.
- Compare source hashes, configuration, component inventories, PE imports,
  filenames, sizes, executable hashes, manifest hashes, corresponding-source
  bundle hashes, SBOM hashes, provenance hashes, and final ZIP hashes.
- Require bit-for-bit equality. An unexplained difference is a publication
  blocker even when the files behave equivalently.

## Compliance Bundle

Publish one corresponding-source ZIP containing:

- the original verified `ffmpeg-9.0.1.tar.xz` and detached signature;
- the pinned FFmpeg signing key;
- every repository build, configuration, audit, and packaging script needed to
  reconstruct the distributed binaries;
- a declaration and inventory of local patches, including an explicit `none`
  declaration when no patches exist;
- captured configuration, component inventory, license output, version output,
  toolchain versions, runner metadata, PE imports, and hashes;
- FFmpeg license files, copyright notices, and rebuild instructions;
- a license inventory for FFmpeg, incorporated code, and any redistributed
  runtime file.

The bundle is published on the same release as the binary package. Providing
the exact source archive alongside complete rebuild material is the project's
chosen LGPL compliance method. FFmpeg remains clearly identified as an
independent third-party work under LGPL 2.1 or later. No claim of FFmpeg
ownership or upstream affiliation is permitted.

## Portable Package and Published Assets

The portable ZIP may contain only:

- `terminal-video-player.exe`
- `tools/ffmpeg/ffmpeg.exe`
- `tools/ffmpeg/ffprobe.exe`
- portable usage instructions
- the project MIT license
- `THIRD-PARTY-NOTICES.md`
- complete applicable FFmpeg licenses and notices
- FFmpeg version, build configuration, enabled-component, PE import, and
  provenance records
- package manifest and hashes

Publish separately:

- portable ZIP
- portable ZIP SHA-256 file
- exact corresponding-source ZIP
- corresponding-source SHA-256 file
- SPDX 2.3 JSON SBOM
- package manifest
- provenance record

No Git metadata, caches, fixtures, logs, toolchains, personal paths,
credentials, installers, update services, unverified DLLs, unused FFmpeg
programs, or debug files may appear in the portable ZIP.

## Validation Gates

Before publication, the workflow must:

- run formatting, check, Clippy with warnings denied, unit tests, integration
  tests, Unicode-path tests, resize tests, rendering tests, cleanup tests, and
  applicable FFmpeg tests;
- verify the exact tag and commit identity;
- verify all external hashes before extraction or execution;
- reject unsafe archive paths before extraction;
- verify `ffmpeg -version`, `-buildconf`, `-L`, and enabled component lists;
- reject GPL, nonfree, version3, unknown, or non-allowlisted components;
- inventory PE imports and reject unexpected DLL dependencies;
- scan binaries for personal paths, temporary paths, and unexpected build-host
  information;
- generate representative media using the newly built FFmpeg;
- validate `--help`, diagnostics, every display mode, Unicode and spaced paths,
  still images, GIFs, video, audio-bearing video, cancellation, cleanup,
  protocol restrictions, and process termination;
- extract the final ZIP into a separate clean Unicode and spaced path;
- verify every extracted hash against the manifest and enforce an exact archive
  allowlist;
- scan repository and release assets for secrets, credentials, personal paths,
  Persian or Arabic script, and unexpected binaries;
- run `git diff --check` and preserve existing source-only CI behavior.

## Documentation

Update the README and maintainer documentation with portable download and
checksum verification, package layout, bundled FFmpeg version and license,
corresponding-source access, supported portable formats, deliberately disabled
functionality, Windows and terminal requirements, execution and display-mode
examples, prerelease limitations, safe FFmpeg update procedure, required
review gates, and rollback procedure.

## Publication and Rollback

Immediately before tagging, verify that the intended tag and release do not
exist and that local `main`, `origin/main`, and the reviewed commit agree. Push
the commit without rewriting history, create the next patch tag, and allow the
tag workflow to publish only after all gates succeed.

The release is a public prerelease. Rollback means stopping publication before
asset creation or, after a repository-caused failure, fixing the source on
`main` and selecting a new patch version. Never move, replace, or overwrite an
existing public tag or release.

After publication, verify GitHub's prerelease status, workflow conclusions,
asset inventory, published hashes, anonymous HTTP 200 access, local and remote
branch parity, tagged commit identity, and a clean local working tree.
