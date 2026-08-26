[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$BuilderPath = Join-Path $RepoRoot 'scripts\release\build-ffmpeg.sh'
$AuditorPath = Join-Path $RepoRoot 'scripts\release\Audit-Ffmpeg.ps1'
$LegacyFetcherPath = Join-Path $RepoRoot 'scripts\Fetch-Ffmpeg.ps1'

foreach ($RequiredPath in @($BuilderPath, $AuditorPath)) {
    if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) {
        throw "Required FFmpeg release program is missing: $RequiredPath"
    }
}
if (Test-Path -LiteralPath $LegacyFetcherPath) {
    throw 'The obsolete prebuilt FFmpeg fetcher must be removed.'
}

$Builder = Get-Content -LiteralPath $BuilderPath -Raw
foreach ($RequiredTerm in @(
    'set -euo pipefail',
    '--disable-everything',
    '--disable-network',
    '--disable-shared',
    '--enable-static',
    'SOURCE_DATE_EPOCH',
    '-ffile-prefix-map=',
    '--no-insert-timestamp',
    'gpg --batch --verify',
    'sha256sum --check',
    'tar -tf'
    '.toolchain.licenses[]'
    'licenses/toolchain'
)) {
    if (-not $Builder.Contains($RequiredTerm, [StringComparison]::Ordinal)) {
        throw "FFmpeg builder is missing required policy term: $RequiredTerm"
    }
}
foreach ($ForbiddenTerm in @('apt-get', 'brew ', 'choco ', 'pacman ', 'BtbN', 'Gyan', '/latest/')) {
    if ($Builder.Contains($ForbiddenTerm, [StringComparison]::OrdinalIgnoreCase)) {
        throw "FFmpeg builder contains forbidden term: $ForbiddenTerm"
    }
}

$HashIndex = $Builder.IndexOf('sha256sum --check', [StringComparison]::Ordinal)
$ExtractIndex = $Builder.IndexOf('tar -xf', [StringComparison]::Ordinal)
if ($HashIndex -lt 0 -or $ExtractIndex -lt 0 -or $HashIndex -gt $ExtractIndex) {
    throw 'FFmpeg builder must verify hashes before archive extraction.'
}

$Auditor = Get-Content -LiteralPath $AuditorPath -Raw
foreach ($RequiredTerm in @(
    '-buildconf', '-version', '-L', '-protocols', '-formats', '-decoders',
    '-encoders', '-filters', '-devices', 'allowed_pe_imports',
    '--enable-gpl', '--enable-nonfree', '--enable-version3'
)) {
    if (-not $Auditor.Contains($RequiredTerm, [StringComparison]::Ordinal)) {
        throw "FFmpeg auditor is missing required policy term: $RequiredTerm"
    }
}

$FixtureGenerator = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\Generate-TestMedia.ps1') -Raw
if ($FixtureGenerator.Contains('libopenh264', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test-media generation must not require the external libopenh264 encoder.'
}
if (-not $FixtureGenerator.Contains('-c:v mpeg4', [StringComparison]::Ordinal)) {
    throw 'Test-media generation must use the reviewed native MPEG-4 encoder.'
}

Write-Host 'FFmpeg build-policy validation passed.'
