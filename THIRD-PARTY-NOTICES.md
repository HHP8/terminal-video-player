# Third-Party Notices

The first-party Terminal Video Player source is distributed under the MIT
License. Third-party projects and dependencies retain their own copyrights and
licenses.

## tplay

- Project name: `tplay`
- Repository: <https://github.com/maxcurzi/tplay>
- Copyright: `Copyright (c) 2023 Max Curzi`
- License: MIT

Terminal Video Player is a separate, independently developed project inspired
in part by tplay. It is not affiliated with or endorsed by tplay or its author.
The Detailed ASCII character ramp in `src/render/glyph.rs` was adapted from
tplay's `CHARS3` ramp. No exclusive ownership is claimed over that adapted
material.

The complete applicable tplay MIT license text follows:

```text
MIT License

Copyright (c) 2023 Max Curzi

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Rust dependencies

The exact locked dependency graph contains 174 third-party package/version
pairs. Cargo metadata reported no missing license expression. The complete
inventory is in [`third-party/rust-dependencies.csv`](third-party/rust-dependencies.csv),
and the review method and license-choice notes are in
[`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md).

Each dependency remains subject to its own license. This notice does not claim
ownership of dependency source, documentation, or trademarks. Portable
packages include the exact release graph's detected license and notice files,
plus their hashed inventory, under `licenses/Rust`.

## FFmpeg

Terminal Video Player invokes `ffmpeg.exe` and `ffprobe.exe` as independent
processes and does not link to FFmpeg libraries. Portable prereleases build
FFmpeg 9.0.1 from verified official upstream source using only the reviewed
built-in LGPL-compatible component allowlist. GPL, nonfree, version3, network,
external codec-library, TLS, and hardware-acceleration enablement are rejected.

FFmpeg is copyright its contributors and is distributed under the GNU Lesser
General Public License version 2.1 or later for this reviewed configuration.
The portable ZIP includes FFmpeg's license and notices. The same GitHub
prerelease includes the exact corresponding-source archive, detached signature,
build scripts, configuration, audit evidence, rebuild instructions, and
hashes. See [`docs/FFMPEG.md`](docs/FFMPEG.md). This project does not claim
ownership of or affiliation with FFmpeg.

## llvm-mingw build toolchain

The FFmpeg cross-build uses the pinned llvm-mingw 20260616 UCRT toolchain with
LLVM 22.1.8. LLVM, Clang, LLD, and compiler-rt are covered by Apache-2.0 WITH
LLVM-exception. The incorporated mingw-w64 headers, startup code, and runtime
materials retain their ZPL-2.1 and collected permissive runtime terms. Exact
source revisions and artifact license paths are recorded in
[`third-party/ffmpeg-artifact.json`](third-party/ffmpeg-artifact.json), and the
applicable license files are included in each portable ZIP and corresponding-
source bundle.
