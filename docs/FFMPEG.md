# Pinned FFmpeg artifact

The POC does not link FFmpeg and does not require FFmpeg headers. Its runtime
sidecars are fetched from one exact asset and kept out of Git.

| Field | Value |
| --- | --- |
| Distributor | BtbN/FFmpeg-Builds |
| Release | `autobuild-2026-06-30-13-34` |
| Asset | `ffmpeg-n8.1.2-21-gce3c09c101-win64-lgpl-shared-8.1.zip` |
| Size | `70,103,338` bytes |
| SHA-256 | `27bcaf58b5140171dfe838a0b365d12c60607d71fc168424456410bad6a834da` |
| Build recipe commit | `7a83528ea3431e9eca982a712bc3a7cd0789d5d0` |
| FFmpeg commit | `ce3c09c101c83add623774d414a9f9498caf5c25` |

The script fails closed on a hash mismatch. It also checks the binary's
version token and `-buildconf` output against the same JSON manifest consumed by
the Rust runtime. Expected flags are:

```text
--enable-version3
--enable-shared
--disable-static
```

and rejects:

```text
--enable-gpl
--enable-nonfree
```

The GitHub release is not marked immutable. The URL and SHA-256 are therefore
both required, and a disappearing asset must be replaced through an explicit
manifest review rather than by selecting "latest."

Authoritative references:

- FFmpeg download policy: <https://ffmpeg.org/download.html>
- FFmpeg legal guidance: <https://ffmpeg.org/legal.html>
- Build repository: <https://github.com/BtbN/FFmpeg-Builds>
- FFmpeg source commit:
  <https://github.com/FFmpeg/FFmpeg/commit/ce3c09c101c83add623774d414a9f9498caf5c25>
- Build recipe commit:
  <https://github.com/BtbN/FFmpeg-Builds/commit/7a83528ea3431e9eca982a712bc3a7cd0789d5d0>

The current artifact was selected for the architecture proof, not approved for
a public/commercial release. Before redistribution, inspect every external
library reported by `-buildconf`, preserve license/source materials, and obtain
appropriate legal review.
