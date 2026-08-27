#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
validator="$repo_root/scripts/release/Validate-TarArchive.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

mkdir -p "$test_root/safe/expected-root"
printf 'safe\n' > "$test_root/safe/expected-root/file.txt"
tar -cf "$test_root/safe.tar" -C "$test_root/safe" expected-root
"$validator" "$test_root/safe.tar" expected-root

mkdir -p "$test_root/link/expected-root"
printf 'linked\n' > "$test_root/link/expected-root/original"
ln "$test_root/link/expected-root/original" "$test_root/link/expected-root/escape"
tar -cf "$test_root/link.tar" -C "$test_root/link" expected-root
"$validator" "$test_root/link.tar" expected-root

mkdir -p "$test_root/wrong/unexpected-root"
printf 'wrong\n' > "$test_root/wrong/unexpected-root/file.txt"
tar -cf "$test_root/wrong-root.tar" -C "$test_root/wrong" unexpected-root
if "$validator" "$test_root/wrong-root.tar" expected-root; then
    echo 'Tar validation accepted an unexpected top-level root.' >&2
    exit 1
fi

echo 'Tar archive validation tests passed.'
