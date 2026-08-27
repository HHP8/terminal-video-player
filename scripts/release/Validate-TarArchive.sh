#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 || ! -f "$1" || -z "$2" || "$2" == */* ]]; then
    echo 'Usage: Validate-TarArchive.sh ARCHIVE EXPECTED_ROOT' >&2
    exit 64
fi

archive="$1"
expected_root="$2"
inventory="$(mktemp -d)"
trap 'rm -rf -- "$inventory"' EXIT

tar --list --file "$archive" --quoting-style=escape > "$inventory/names"
tar --list --verbose --file "$archive" --quoting-style=escape > "$inventory/verbose"

name_count="$(wc -l < "$inventory/names" | tr -d ' ')"
type_count="$(wc -l < "$inventory/verbose" | tr -d ' ')"
[[ "$name_count" -gt 0 && "$name_count" == "$type_count" ]] || {
    echo 'Archive inventory is empty or internally inconsistent.' >&2
    exit 1
}

if [[ -n "$(sort "$inventory/names" | uniq -d)" ]]; then
    echo 'Archive contains duplicate paths.' >&2
    exit 1
fi

while IFS= read -r entry; do
    [[ -n "$entry" ]] || { echo 'Archive contains an empty path.' >&2; exit 1; }
    case "$entry" in
        /*|*\\*|[A-Za-z]:*|../*|*/../*|*/..|..)
            echo "Unsafe archive entry: $entry" >&2
            exit 1
            ;;
    esac
    [[ "$entry" == "$expected_root" || "$entry" == "$expected_root/" || "$entry" == "$expected_root/"* ]] || {
        echo "Archive entry is outside the expected root $expected_root: $entry" >&2
        exit 1
    }
done < "$inventory/names"

mapfile -t names < "$inventory/names"
mapfile -t listings < "$inventory/verbose"
synthetic_root="/archive/$expected_root"
for index in "${!listings[@]}"; do
    listing="${listings[$index]}"
    entry="${names[$index]}"
    entry="${entry%/}"
    case "${listing:0:1}" in
        -|d) ;;
        l)
            [[ "$listing" == *' -> '* ]] || { echo 'Malformed symbolic-link inventory.' >&2; exit 1; }
            target="${listing##* -> }"
            case "$target" in /*|*\\*|[A-Za-z]:*) echo 'Unsafe symbolic-link target.' >&2; exit 1 ;; esac
            resolved="$(realpath -m -- "/archive/$(dirname -- "$entry")/$target")"
            [[ "$resolved" == "$synthetic_root" || "$resolved" == "$synthetic_root/"* ]] || {
                echo 'Symbolic-link target escapes the expected archive root.' >&2
                exit 1
            }
            ;;
        h)
            [[ "$listing" == *' link to '* ]] || { echo 'Malformed hard-link inventory.' >&2; exit 1; }
            target="${listing##* link to }"
            case "$target" in /*|*\\*|[A-Za-z]:*) echo 'Unsafe hard-link target.' >&2; exit 1 ;; esac
            resolved="$(realpath -m -- "/archive/$target")"
            [[ "$resolved" == "$synthetic_root" || "$resolved" == "$synthetic_root/"* ]] || {
                echo 'Hard-link target escapes the expected archive root.' >&2
                exit 1
            }
            ;;
        *) echo 'Archive contains a special entry.' >&2; exit 1 ;;
    esac
done

echo "Archive inventory is safe under root: $expected_root"
