[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$MetadataPath,
    [Parameter(Mandatory)] [string]$ComponentsPath,
    [Parameter(Mandatory)] [string]$ActionsPath
)

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

function Resolve-RepositoryFile {
    param([string]$Path, [string]$Label)
    $Candidate = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $RepoRoot $Path }
    $Resolved = [IO.Path]::GetFullPath($Candidate)
    $Prefix = $RepoRoot.TrimEnd('\') + '\'
    if (-not $Resolved.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay inside the repository: $Resolved"
    }
    if (-not (Test-Path -LiteralPath $Resolved -PathType Leaf)) {
        throw "$Label is missing: $Resolved"
    }
    return $Resolved
}

function Assert-ExactProperties {
    param([object]$Value, [string[]]$Names, [string]$Label)
    $Actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $Expected = @($Names | Sort-Object)
    if (($Actual -join "`n") -cne ($Expected -join "`n")) {
        throw "$Label properties differ. Expected [$($Expected -join ', ')], found [$($Actual -join ', ')]."
    }
}

function Assert-Sha256 {
    param([string]$Value, [string]$Label)
    if ($Value -cnotmatch '^[0-9a-f]{64}$') { throw "$Label must be a lowercase SHA-256 value." }
}

function Assert-Commit {
    param([string]$Value, [string]$Label)
    if ($Value -cnotmatch '^[0-9a-f]{40}$') { throw "$Label must be a full lowercase Git commit SHA." }
}

function Assert-ImmutableUrl {
    param([string]$Value, [string]$Identity, [string]$Label)
    $Uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$Uri) -or $Uri.Scheme -ne 'https') {
        throw "$Label must be an absolute HTTPS URL."
    }
    if ($Value -match '(?i)(/latest/|/latest$|/master/|/main/|snapshot)') {
        throw "$Label uses a mutable reference."
    }
    if (-not $Value.Contains($Identity, [StringComparison]::Ordinal)) {
        throw "$Label does not contain its pinned identity $Identity."
    }
}

function Assert-SortedUniqueStrings {
    param([object[]]$Values, [string]$Label)
    if ($Values.Count -eq 0) { throw "$Label must not be empty." }
    $Strings = @($Values | ForEach-Object { [string]$_ })
    if (@($Strings | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -ne 0) {
        throw "$Label contains an empty value."
    }
    $Expected = @($Strings | Sort-Object -CaseSensitive -Unique)
    if (($Strings -join "`n") -cne ($Expected -join "`n")) {
        throw "$Label must be sorted and unique."
    }
}

$MetadataFile = Resolve-RepositoryFile $MetadataPath 'FFmpeg metadata'
$ComponentsFile = Resolve-RepositoryFile $ComponentsPath 'FFmpeg components'
$ActionsFile = Resolve-RepositoryFile $ActionsPath 'Release actions'
$Metadata = Get-Content -LiteralPath $MetadataFile -Raw | ConvertFrom-Json
$Components = Get-Content -LiteralPath $ComponentsFile -Raw | ConvertFrom-Json
$Actions = Get-Content -LiteralPath $ActionsFile -Raw | ConvertFrom-Json

Assert-ExactProperties $Metadata @('schema', 'ffmpeg', 'toolchain', 'build', 'package') 'Metadata root'
if ($Metadata.schema -ne 2) { throw 'FFmpeg metadata schema must equal 2.' }
Assert-ExactProperties $Metadata.ffmpeg @(
    'project', 'version', 'release_tag', 'source_commit', 'source_archive',
    'source_signature', 'signing_key', 'expected_license', 'rejected_flags',
    'rejected_configuration_terms'
) 'FFmpeg metadata'
if ($Metadata.ffmpeg.version -ne '9.0.1' -or $Metadata.ffmpeg.release_tag -ne 'n9.0.1') {
    throw 'FFmpeg version and release tag are not the reviewed 9.0.1 release.'
}
Assert-Commit $Metadata.ffmpeg.source_commit 'FFmpeg source commit'
Assert-ImmutableUrl $Metadata.ffmpeg.source_archive.url $Metadata.ffmpeg.version 'FFmpeg source URL'
Assert-ImmutableUrl $Metadata.ffmpeg.source_signature.url $Metadata.ffmpeg.version 'FFmpeg signature URL'
Assert-Sha256 $Metadata.ffmpeg.source_archive.sha256 'FFmpeg source hash'
Assert-Sha256 $Metadata.ffmpeg.source_signature.sha256 'FFmpeg signature hash'
Assert-Sha256 $Metadata.ffmpeg.signing_key.sha256 'FFmpeg signing-key hash'
if ($Metadata.ffmpeg.signing_key.fingerprint -cnotmatch '^[0-9A-F]{40}$') {
    throw 'FFmpeg signing-key fingerprint must be 40 uppercase hexadecimal characters.'
}
$SigningKey = Resolve-RepositoryFile $Metadata.ffmpeg.signing_key.path 'FFmpeg signing key'
$SigningKeyHash = (Get-FileHash -LiteralPath $SigningKey -Algorithm SHA256).Hash.ToLowerInvariant()
if ($SigningKeyHash -cne $Metadata.ffmpeg.signing_key.sha256) {
    throw 'The vendored FFmpeg signing key does not match its pinned SHA-256.'
}
if ($Metadata.ffmpeg.expected_license -cne 'LGPL-2.1-or-later') {
    throw 'FFmpeg expected_license must equal LGPL-2.1-or-later.'
}
Assert-SortedUniqueStrings @($Metadata.ffmpeg.rejected_flags) 'Rejected FFmpeg flags'
foreach ($Flag in @('--enable-gpl', '--enable-nonfree', '--enable-version3')) {
    if ($Flag -notin @($Metadata.ffmpeg.rejected_flags)) { throw "Rejected FFmpeg flag is missing: $Flag" }
}

Assert-ExactProperties $Metadata.toolchain @(
    'project', 'release', 'source_commit', 'llvm_version', 'artifact', 'target',
    'crt', 'licenses'
) 'Toolchain metadata'
Assert-Commit $Metadata.toolchain.source_commit 'Toolchain source commit'
Assert-ImmutableUrl $Metadata.toolchain.artifact.url $Metadata.toolchain.release 'Toolchain URL'
Assert-Sha256 $Metadata.toolchain.artifact.sha256 'Toolchain hash'
foreach ($License in @($Metadata.toolchain.licenses)) {
    if ([string]::IsNullOrWhiteSpace($License.component) -or
        [string]::IsNullOrWhiteSpace($License.spdx) -or
        [string]::IsNullOrWhiteSpace($License.source)) {
        throw 'Every toolchain license entry must contain component, spdx, and source.'
    }
}

Assert-SortedUniqueStrings @($Metadata.build.configuration_flags) 'FFmpeg configuration flags'
foreach ($Flag in @('--disable-everything', '--disable-network', '--disable-shared', '--enable-static')) {
    if ($Flag -notin @($Metadata.build.configuration_flags)) { throw "Required FFmpeg flag is missing: $Flag" }
}
Assert-SortedUniqueStrings @($Metadata.package.runtime_files) 'Portable runtime files'
Assert-SortedUniqueStrings @($Metadata.package.published_asset_suffixes) 'Published asset suffixes'

if ($Components.schema -ne 1) { throw 'FFmpeg component schema must equal 1.' }
Assert-ExactProperties $Components @(
    'schema', 'libraries', 'protocols', 'demuxers', 'decoders', 'parsers',
    'encoders', 'muxers', 'filters', 'indevs', 'allowed_pe_imports'
) 'FFmpeg components'
foreach ($Property in @(
    'libraries', 'protocols', 'demuxers', 'decoders', 'parsers', 'encoders',
    'muxers', 'filters', 'indevs', 'allowed_pe_imports'
)) {
    Assert-SortedUniqueStrings @($Components.$Property) "FFmpeg $Property"
}
if (($Components.protocols -join ',') -cne 'file,pipe') {
    throw 'Portable FFmpeg protocols must be exactly file and pipe.'
}

if ($Actions.schema -ne 1) { throw 'Release-actions schema must equal 1.' }
Assert-SortedUniqueStrings @($Actions.actions.repository) 'Release action repositories'
foreach ($Action in @($Actions.actions)) {
    Assert-Commit $Action.commit "Action commit for $($Action.repository)"
    if ($Action.release -notmatch '^v\d+\.\d+\.\d+$') {
        throw "Action release is not a semantic tag: $($Action.repository)"
    }
}

Write-Host 'Release metadata files are valid.'
