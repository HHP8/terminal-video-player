# Locked dependency inventory

`Cargo.lock` is committed and direct requirements are exact-pinned. The Windows
x64 normal/build graph currently resolves to 73 unique package/version pairs.
The broader Windows graph including development and benchmark dependencies
resolves to 103. Cargo metadata reports a non-empty SPDX-style license
expression for every package in those graphs.

## Direct runtime dependencies

| Package | Version | Declared license |
| --- | ---: | --- |
| `anyhow` | 1.0.104 | MIT OR Apache-2.0 |
| `clap` | 4.6.4 | MIT OR Apache-2.0 |
| `crossbeam-channel` | 0.5.16 | MIT OR Apache-2.0 |
| `crossterm` | 0.29.0 | MIT |
| `ctrlc` | 3.5.2 | MIT/Apache-2.0 |
| `image` | 0.25.10 | MIT OR Apache-2.0 |
| `serde` | 1.0.229 | MIT OR Apache-2.0 |
| `serde_json` | 1.0.151 | MIT OR Apache-2.0 |
| `thiserror` | 2.0.19 | MIT OR Apache-2.0 |
| `unicode-width` | 0.2.2 | MIT OR Apache-2.0 |
| `cpal` | 0.18.1 | Apache-2.0 |
| `windows` | 0.62.2 | MIT OR Apache-2.0 |

## Direct development dependencies

| Package | Version | Declared license |
| --- | ---: | --- |
| `criterion` | 0.8.2 | Apache-2.0 OR MIT |
| `tempfile` | 3.27.0 | MIT OR Apache-2.0 |

This metadata check is not a complete legal review and does not produce the
license texts required for public redistribution. In particular, the
transitive graph includes Unicode-3.0 and several BSD/Zlib/Unlicense choices.
Before a public release, generate a reviewed notice bundle and SBOM with
`cargo-about` or `cargo-deny`; do not infer approval from the absence of missing
Cargo license fields.
