#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C
export LANG=C
export TZ=UTC
umask 022

usage() {
    echo "Usage: build-ffmpeg.sh --metadata FILE --components FILE --work DIR --output DIR" >&2
    exit 64
}

metadata_path=""
components_path=""
work_root=""
output_root=""
while (($#)); do
    case "$1" in
        --metadata) metadata_path="${2-}"; shift 2 ;;
        --components) components_path="${2-}"; shift 2 ;;
        --work) work_root="${2-}"; shift 2 ;;
        --output) output_root="${2-}"; shift 2 ;;
        *) usage ;;
    esac
done

[[ -n "$metadata_path" && -f "$metadata_path" ]] || usage
[[ -n "$components_path" && -f "$components_path" ]] || usage
[[ -n "$work_root" && "$work_root" = /* ]] || usage
[[ -n "$output_root" && "$output_root" = /* ]] || usage
[[ -n "${SOURCE_DATE_EPOCH:-}" && "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || {
    echo "SOURCE_DATE_EPOCH must be a Unix timestamp." >&2
    exit 65
}

for command_name in curl gpg jq make sha256sum tar xz; do
    command -v "$command_name" >/dev/null || {
        echo "Required preinstalled command is missing: $command_name" >&2
        exit 69
    }
done

case "$work_root" in
    "${GITHUB_WORKSPACE:-/nonexistent}"/*|"${RUNNER_TEMP:-/nonexistent}"/*|/tmp/terminal-video-player-ffmpeg-*) ;;
    *) echo "Work directory is outside an approved runner root: $work_root" >&2; exit 65 ;;
esac
case "$output_root" in
    "${GITHUB_WORKSPACE:-/nonexistent}"/*|"${RUNNER_TEMP:-/nonexistent}"/*|/tmp/terminal-video-player-ffmpeg-*) ;;
    *) echo "Output directory is outside an approved runner root: $output_root" >&2; exit 65 ;;
esac

rm -rf -- "$work_root" "$output_root"
mkdir -p -- "$work_root/downloads" "$work_root/extracted" "$output_root/bin" \
    "$output_root/licenses/ffmpeg" "$output_root/licenses/toolchain" "$output_root/provenance"

json_value() { jq -er "$1" "$2"; }
download_verified() {
    local url="$1" destination="$2" expected_size="$3" expected_hash="$4"
    local partial="${destination}.partial"
    rm -f -- "$partial" "$destination"
    curl --fail --location --proto '=https' --tlsv1.2 \
        --retry 4 --retry-all-errors --connect-timeout 30 \
        --output "$partial" "$url"
    local actual_size
    actual_size="$(stat --format='%s' "$partial")"
    [[ "$actual_size" == "$expected_size" ]] || {
        echo "Downloaded size mismatch for $(basename "$destination")." >&2
        exit 1
    }
    printf '%s  %s\n' "$expected_hash" "$partial" | sha256sum --check --strict
    mv -- "$partial" "$destination"
}

assert_safe_tar() {
    local archive="$1"
    local entries="$work_root/tar-entries.txt"
    tar -tf "$archive" > "$entries"
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        case "$entry" in
            /*|*\\*|[A-Za-z]:*|../*|*/../*|*/..|..) echo "Unsafe archive entry: $entry" >&2; exit 1 ;;
        esac
    done < "$entries"
}

source_name="$(json_value '.ffmpeg.source_archive.name' "$metadata_path")"
source_url="$(json_value '.ffmpeg.source_archive.url' "$metadata_path")"
source_size="$(json_value '.ffmpeg.source_archive.size_bytes' "$metadata_path")"
source_hash="$(json_value '.ffmpeg.source_archive.sha256' "$metadata_path")"
signature_name="$(json_value '.ffmpeg.source_signature.name' "$metadata_path")"
signature_url="$(json_value '.ffmpeg.source_signature.url' "$metadata_path")"
signature_size="$(json_value '.ffmpeg.source_signature.size_bytes' "$metadata_path")"
signature_hash="$(json_value '.ffmpeg.source_signature.sha256' "$metadata_path")"
key_relative="$(json_value '.ffmpeg.signing_key.path' "$metadata_path")"
key_hash="$(json_value '.ffmpeg.signing_key.sha256' "$metadata_path")"
key_fingerprint="$(json_value '.ffmpeg.signing_key.fingerprint' "$metadata_path")"
toolchain_name="$(json_value '.toolchain.artifact.name' "$metadata_path")"
toolchain_url="$(json_value '.toolchain.artifact.url' "$metadata_path")"
toolchain_size="$(json_value '.toolchain.artifact.size_bytes' "$metadata_path")"
toolchain_hash="$(json_value '.toolchain.artifact.sha256' "$metadata_path")"
target="$(json_value '.toolchain.target' "$metadata_path")"

repo_root="$(cd "$(dirname "$metadata_path")/.." && pwd -P)"
signing_key="$repo_root/$key_relative"
[[ -f "$signing_key" ]] || { echo "Vendored signing key is missing." >&2; exit 1; }
printf '%s  %s\n' "$key_hash" "$signing_key" | sha256sum --check --strict

source_archive="$work_root/downloads/$source_name"
source_signature="$work_root/downloads/$signature_name"
toolchain_archive="$work_root/downloads/$toolchain_name"
download_verified "$source_url" "$source_archive" "$source_size" "$source_hash"
download_verified "$signature_url" "$source_signature" "$signature_size" "$signature_hash"
download_verified "$toolchain_url" "$toolchain_archive" "$toolchain_size" "$toolchain_hash"

gnupg_home="$work_root/gnupg"
mkdir -m 700 -- "$gnupg_home"
GNUPGHOME="$gnupg_home" gpg --batch --import "$signing_key" >/dev/null 2>&1
actual_fingerprint="$(GNUPGHOME="$gnupg_home" gpg --batch --with-colons --fingerprint | awk -F: '$1 == "fpr" { print $10; exit }')"
[[ "$actual_fingerprint" == "$key_fingerprint" ]] || {
    echo "FFmpeg signing-key fingerprint mismatch." >&2
    exit 1
}
GNUPGHOME="$gnupg_home" gpg --batch --verify "$source_signature" "$source_archive"

assert_safe_tar "$source_archive"
assert_safe_tar "$toolchain_archive"
tar -xf "$source_archive" -C "$work_root/extracted" --no-same-owner --no-same-permissions
tar -xf "$toolchain_archive" -C "$work_root/extracted" --no-same-owner --no-same-permissions

source_dir="$work_root/extracted/ffmpeg-$(json_value '.ffmpeg.version' "$metadata_path")"
toolchain_dir="$(find "$work_root/extracted" -mindepth 1 -maxdepth 1 -type d -name 'llvm-mingw-*' -print -quit)"
[[ -d "$source_dir" && -n "$toolchain_dir" && -d "$toolchain_dir" ]] || {
    echo "Verified archives did not produce the expected source and toolchain directories." >&2
    exit 1
}

cross_prefix="$toolchain_dir/bin/$target-"
for tool in clang llvm-ar llvm-ranlib llvm-strip llvm-objdump llvm-strings; do
    [[ -x "$toolchain_dir/bin/$tool" || -x "${cross_prefix}${tool#llvm-}" || -x "${cross_prefix}$tool" ]] || {
        echo "Pinned toolchain is missing required tool: $tool" >&2
        exit 1
    }
done

mapfile -t base_flags < <(jq -er '.build.configuration_flags[]' "$metadata_path")
for required_flag in --disable-everything --disable-network --disable-shared --enable-static; do
    printf '%s\n' "${base_flags[@]}" | grep -Fx -- "$required_flag" >/dev/null || {
        echo "Release metadata is missing mandatory FFmpeg flag: $required_flag" >&2
        exit 1
    }
done
configure_args=(
    "${base_flags[@]}"
    "--target-os=$(json_value '.build.target_os' "$metadata_path")"
    "--arch=$(json_value '.build.architecture' "$metadata_path")"
    "--cross-prefix=$cross_prefix"
    "--cc=${cross_prefix}clang"
    "--cxx=${cross_prefix}clang++"
    "--ar=${cross_prefix}ar"
    "--ranlib=${cross_prefix}ranlib"
    "--strip=${cross_prefix}strip"
    "--pkg-config=false"
    "--enable-w32threads"
    "--extra-version=terminal-video-player"
    "--extra-cflags=-O2 -ffile-prefix-map=$source_dir=. -fdebug-prefix-map=$source_dir=."
    "--extra-ldflags=-Wl,--no-insert-timestamp"
)

append_components() {
    local property="$1" configure_name="$2"
    local joined
    joined="$(jq -er --arg property "$property" '[.[$property][]] | join(",")' "$components_path")"
    configure_args+=("--enable-${configure_name}=$joined")
}
for library in $(jq -er '.libraries[]' "$components_path"); do
    configure_args+=("--enable-$library")
done
append_components protocols protocol
append_components demuxers demuxer
append_components decoders decoder
append_components parsers parser
append_components encoders encoder
append_components muxers muxer
append_components filters filter
append_components indevs indev

printf '%q ' "${configure_args[@]}" > "$output_root/provenance/CONFIGURE-COMMAND.txt"
printf '\n' >> "$output_root/provenance/CONFIGURE-COMMAND.txt"

pushd "$source_dir" >/dev/null
./configure "${configure_args[@]}"
make -j2 ffmpeg.exe ffprobe.exe
"${cross_prefix}strip" --strip-all ffmpeg.exe ffprobe.exe
cp -- ffmpeg.exe ffprobe.exe "$output_root/bin/"
cp -- config.h config_components.h "$output_root/provenance/"
popd >/dev/null

cp -- "$source_archive" "$source_signature" "$signing_key" "$output_root/provenance/"
cp -- "$source_dir/LICENSE.md" "$source_dir/COPYING.LGPLv2.1" "$output_root/licenses/ffmpeg/"
while IFS=$'\t' read -r artifact_path output_name; do
    license_source="$toolchain_dir/$artifact_path"
    [[ -f "$license_source" ]] || {
        echo "Pinned toolchain license file is missing: $artifact_path" >&2
        exit 1
    }
    cp -- "$license_source" "$output_root/licenses/toolchain/$output_name"
done < <(jq -er '.toolchain.licenses[] | [.artifact_path, .output_name] | @tsv' "$metadata_path")

{
    echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
    echo "SOURCE_SHA256=$source_hash"
    echo "SOURCE_COMMIT=$(json_value '.ffmpeg.source_commit' "$metadata_path")"
    echo "TOOLCHAIN_SHA256=$toolchain_hash"
    echo "TOOLCHAIN_COMMIT=$(json_value '.toolchain.source_commit' "$metadata_path")"
    "${cross_prefix}clang" --version
    "${cross_prefix}ld" --version
    "${cross_prefix}ar" --version
    "${cross_prefix}strip" --version
    jq --version
    make --version | head -n 1
    gpg --version | head -n 1
    tar --version | head -n 1
    xz --version | head -n 1
} > "$output_root/provenance/TOOLCHAIN.txt"

jq -n \
    --arg image_os "${ImageOS:-unknown}" \
    --arg image_version "${ImageVersion:-unknown}" \
    --arg image_release "${ImageRelease:-unknown}" \
    --arg runner_arch "${RUNNER_ARCH:-unknown}" \
    --arg runner_os "${RUNNER_OS:-unknown}" \
    '{image_os:$image_os,image_version:$image_version,image_release:$image_release,runner_arch:$runner_arch,runner_os:$runner_os}' \
    > "$output_root/provenance/RUNNER.json"

pushd "$output_root" >/dev/null
find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
popd >/dev/null
echo "Verified FFmpeg source build completed: $output_root"
