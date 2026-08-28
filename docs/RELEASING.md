# Portable Prerelease Procedure

This document is for maintainers of Terminal Video Player. Portable releases
are public prereleases built by GitHub Actions from immutable version tags.
They are not installers and must not be assembled or uploaded manually.

## Required review before changing FFmpeg

1. Select an official FFmpeg point-release archive and its detached signature.
2. Record the release tag, source commit, exact byte size, SHA-256, signing-key
   fingerprint, and signing-key SHA-256 in `third-party/ffmpeg-artifact.json`.
3. Review upstream `LICENSE.md`, FFmpeg's legal checklist, and every enabled
   source component. GPL, nonfree, version3, external codec, network, TLS, and
   hardware-acceleration enablement are prohibited for this package.
4. Derive protocols, formats, codecs, parsers, filters, devices, and libraries
   from actual player commands and tests. Update
   `third-party/ffmpeg-components.json` only after reviewing each addition.
5. Select a stable version-specific llvm-mingw artifact. Record its release,
   commit, size, SHA-256, component licenses, and license-file paths.
6. Run every release-script test and a nonpublishing manual workflow. Review
   FFmpeg configuration, component inventories, license output, PE imports,
   embedded-string scan, runtime tests, and both-build hash comparison.
7. Update the corresponding-source and portable documentation with the exact
   supported and disabled functionality. A broader upstream FFmpeg claim must
   never be copied into the portable package documentation.
8. Review the resolved `ImageOS`, `ImageVersion`, compiler, linker, assembler,
   resource compiler, compiler-rt and mingw-w64 source revisions, Make, GnuPG,
   tar, xz, and jq versions captured by both builds. Hosted runner
   labels are not immutable image digests, so a runner-image change requires a
   new manual validation and evidence review even when source hashes are stable.
   Confirm that the reproducibility report contains the exact resolved metadata
   for both isolated Windows builds. That volatile metadata must remain outside
   the portable payload so truthful provenance does not make the archive vary.
9. Review the generated Rust dependency license bundle. Every package in the
   `x86_64-pc-windows-msvc` normal/build release graph must match the reviewed
   inventory and have detected license or notice files. Development-only and
   irrelevant target packages must be absent, and the portable manifest must
   hash every bundled file under `licenses/Rust`.

Hash changes require evidence that the upstream identity changed for an
expected reason. Never rotate a hash merely to make a failed download pass.

## Validation release procedure

Run the Portable Prerelease workflow manually from `main`. Manual runs never
publish. Require all metadata, Rust, FFmpeg build, audit, package, extraction,
runtime, security, and reproducibility jobs to pass. Download the validation
artifacts and independently compare their inventories and SHA-256 values.

Confirm that the ordinary CI workflow also succeeds at the same commit. Review
the exact staged files and diff, secret and privacy scans, Persian/Arabic scan,
non-ASCII review, package allowlists, ignored artifacts, workflow permissions,
and action commit pins before pushing a release commit.

The manual run must be launched from the exact `main` commit intended for the
tag. Compare both FFmpeg binaries, both player binaries, both portable ZIPs,
both corresponding-source bundles, manifests, SBOMs, and provenance records.
The seven independently assembled build assets must be bit-for-bit identical.
The separately generated reproducibility report must record both resolved
hosted-runner images and matching player and FFmpeg binary hashes. Any
unexplained byte difference is a publication blocker.

## Publishing

1. Fetch `main`, tags, and releases without modifying history.
2. Require a clean working tree and exact equality between local `main` and
   `origin/main`.
3. Confirm the intended semantic version tag and GitHub release do not exist.
4. Confirm the tag version equals the Cargo package version.
5. Create one annotated version tag at the reviewed commit and push only that
   tag.
6. Monitor the tag-triggered workflow. Only its final job has `contents: write`
   and it may publish only after every preceding job succeeds.
7. Verify the resulting GitHub release is public and marked as a prerelease.
8. Download every asset anonymously, require HTTP 200, recompute hashes, and
   compare the package and corresponding-source contents with their manifests.

## Rollback and failure handling

Before publication, cancel the workflow and leave the tag uncreated whenever a
stop condition is found. After an immutable tag has been published, do not move
the tag, overwrite assets, or replace the release. Fix repository-caused issues
on `main`, increment the patch version, repeat the full nonpublishing
validation, and publish a new prerelease.

If a workflow created a release entry but failed before uploading the complete
reviewed asset set, stop and assess it as an incident. Do not delete or replace
public evidence automatically. Document the failure and obtain explicit
maintainer approval for any GitHub-side cleanup.
