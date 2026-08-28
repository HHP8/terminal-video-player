# Rust Dependency License Inventory

The application keeps `Cargo.lock` in source control. On 2026-08-26, the full
locked graph was read with:

```powershell
cargo metadata --format-version 1 --locked --offline
```

The resulting conservative inventory contains 174 third-party package/version
pairs across normal, development, build, target-specific, and transitive
dependencies. It is stored in
[`../third-party/rust-dependencies.csv`](../third-party/rust-dependencies.csv).

## Review result

- Missing or unknown Cargo license expressions: **0**
- Non-commercial or source-available-only expressions: **0**
- Expressions without a compatible permissive choice: **0**
- Review blocker: **none identified**

The detected expressions use MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, Zlib,
0BSD, Unlicense, Unicode-3.0, and the LLVM exception. Expressions containing
`LGPL-2.1-or-later` provide an explicit `MIT OR Apache-2.0` alternative in the
locked metadata; this project relies on a permissive alternative rather than
selecting LGPL for that dependency. `unicode-ident` combines a permissive
MIT/Apache choice with Unicode-3.0, whose notice must also be respected.

This inventory records Cargo's declared metadata, not a legal opinion. The
portable workflow derives the exact Windows release package set with
`cargo tree --locked --target x86_64-pc-windows-msvc --edges normal,build`,
matches that set against target-filtered Cargo metadata and the reviewed CSV,
and excludes development-only and irrelevant target packages from the portable
license bundle and SBOM. It fails if a selected dependency has no discoverable
license or notice file. The `dasp_sample` 0.11.0 crate package omits the notices
present at its recorded
[upstream VCS revision](https://github.com/RustAudio/dasp/tree/97c3bb9b2363c0b46ac1633858bf1054fd02a980),
so the repository carries exact hash-pinned copies of those two upstream notice
files. The workflow accepts them only when the crate name, version, registry
source, declared license expression, and Cargo VCS revision all match the
reviewed fallback metadata. It then bundles all detected or pinned files plus a
hashed dependency-license inventory under `licenses/Rust`. Dependency source
is not vendored into this repository.

## Direct dependencies

Direct runtime dependencies are `anyhow`, `clap`, `crossbeam-channel`,
`crossterm`, `ctrlc`, `image`, `serde`, `serde_json`, `thiserror`, and
`unicode-width`, plus Windows-only `cpal` and `windows`. Development dependencies
are `criterion` and `tempfile`. Exact versions and the full transitive graph are
authoritative in `Cargo.lock` and the CSV inventory.
