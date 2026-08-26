# Contributing

Thank you for considering a contribution to Terminal Video Player. The project
is a Windows-first proof of concept, so changes should remain narrow, measurable,
and honest about what has and has not been validated.

## Before opening a change

- Use English for repository content, documentation, comments, command-line
  text, commit messages, and issue or pull-request descriptions.
- Discuss large architectural changes in an issue before implementation.
- Do not add executables, DLLs, downloaded FFmpeg files, generated media,
  archives, logs, reports, editor state, credentials, or machine-specific paths.
- Keep `Cargo.lock` updated and tracked because this repository is an
  application.
- Do not weaken tests, warnings, benchmark thresholds, safety limits, terminal
  cleanup, or process containment.

## Development setup

Follow the source-build and FFmpeg instructions in [`README.md`](README.md).
Use the pinned Rust toolchain and locked dependency graph.

Before submitting:

```powershell
cargo fmt --all -- --check
cargo check --all-targets --locked
cargo clippy --all-targets --locked -- -D warnings
cargo test --all-targets --locked
git diff --check
```

Run the opt-in FFmpeg tests when changing probing, decoding, playback, audio,
process containment, or cleanup. Run the rendering benchmarks when changing
sampling, glyphs, colors, or ANSI update strategies.

## Pull requests

Explain the user-visible behavior, the evidence behind the change, the commands
you ran, and every check that remains unverified. Keep unrelated changes out of
the same pull request. New behavior and bug fixes require focused regression
tests.

By contributing, you agree that your contribution is licensed under the
project's [MIT License](LICENSE).
