# Security Policy

## Supported versions

Security fixes are applied to the current `main` branch. This proof of concept
does not currently promise maintenance for older commits, tags, or local binary
builds.

## Reporting a vulnerability

Use GitHub's private vulnerability-reporting form from the repository's
**Security** tab. Include affected versions or commits, the attacker model,
reproduction steps, impact, and any suggested mitigation. Do not include
working exploit details or private information in a public issue.

If private vulnerability reporting is temporarily unavailable, open a public
issue containing only a request for a private security contact channel. For
ordinary reliability bugs without sensitive details, use a normal issue.

You should receive an acknowledgement within seven days. Timelines for
validation, remediation, and disclosure depend on severity and reproducibility.
Please allow maintainers a reasonable opportunity to investigate before public
disclosure.

## Scope notes

The repository publishes source only. FFmpeg binaries, DLLs, codecs, downloaded
archives, portable packages, installers, and user-built executables are not
project-distributed artifacts. Reports about an upstream FFmpeg build should be
sent to the responsible upstream project unless Terminal Video Player's own
configuration or invocation creates the vulnerability.
