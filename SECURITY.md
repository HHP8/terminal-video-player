# Security Policy

## Supported versions

Security fixes are applied to the current `main` branch and the latest portable
prerelease. This proof of concept does not promise maintenance for older
commits, tags, prereleases, or user-built binaries.

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

The historical `v0.1.0` prerelease is source-only. Later tagged portable
prereleases may contain the project executable plus the specifically audited
FFmpeg tools built by this repository's workflow. Reports about the packaging
workflow, bundled configuration, executable resolution, archive validation, or
invocation policy are in scope. Vulnerabilities solely in upstream FFmpeg
should also be reported to FFmpeg through its published security process.
