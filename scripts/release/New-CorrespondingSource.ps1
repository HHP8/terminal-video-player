[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$RepositoryRoot,
    [Parameter(Mandatory)] [ValidatePattern('^\d+\.\d+\.\d+$')] [string]$Version,
    [Parameter(Mandatory)] [long]$SourceDateEpoch,
    [Parameter(Mandatory)] [string]$FfmpegBuildRoot,
    [Parameter(Mandatory)] [string]$AuditDirectory,
    [Parameter(Mandatory)] [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
Import-Module (Join-Path $PSScriptRoot 'ReleaseTools.psm1') -Force
$Metadata = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'third-party\ffmpeg-artifact.json') -Raw | ConvertFrom-Json
$AssetStem = "terminal-video-player-v$Version"
$Stage = Join-Path $OutputDirectory 'corresponding-source-stage'
if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
New-Item -ItemType Directory -Path $Stage -Force | Out-Null

function Copy-SourceFile {
    param([string]$Source, [string]$RelativeDestination)
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Required corresponding-source input is missing: $Source" }
    Assert-SafeRelativePath $RelativeDestination
    $Destination = Join-Path $Stage $RelativeDestination.Replace('/', '\')
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination
}

$SourceName = [string]$Metadata.ffmpeg.source_archive.name
$SignatureName = [string]$Metadata.ffmpeg.source_signature.name
Copy-SourceFile (Join-Path $FfmpegBuildRoot "provenance\$SourceName") "upstream/$SourceName"
Copy-SourceFile (Join-Path $FfmpegBuildRoot "provenance\$SignatureName") "upstream/$SignatureName"
Copy-SourceFile (Join-Path $FfmpegBuildRoot 'provenance\ffmpeg-release-signing-key.asc') 'upstream/ffmpeg-release-signing-key.asc'

foreach ($Relative in @(
    'third-party/ffmpeg-artifact.json',
    'third-party/ffmpeg-components.json',
    'third-party/ffmpeg-release-signing-key.asc',
    'third-party/release-actions.json',
    'portable/PATCHES.md',
    'portable/REBUILD-FFMPEG.md',
    'docs/FFMPEG.md',
    'docs/RELEASING.md',
    'docs/superpowers/specs/2026-08-26-source-built-ffmpeg-portable-release-design.md'
)) {
    Copy-SourceFile (Join-Path $RepositoryRoot $Relative.Replace('/', '\')) $Relative
}

$ReleaseScriptsRoot = Join-Path $RepositoryRoot 'scripts\release'
foreach ($File in Get-ChildItem -LiteralPath $ReleaseScriptsRoot -Recurse -File) {
    $Relative = [IO.Path]::GetRelativePath($ReleaseScriptsRoot, $File.FullName).Replace('\', '/')
    Copy-SourceFile $File.FullName "scripts/release/$Relative"
}
foreach ($File in Get-ChildItem -LiteralPath (Join-Path $FfmpegBuildRoot 'licenses') -Recurse -File) {
    $Relative = [IO.Path]::GetRelativePath((Join-Path $FfmpegBuildRoot 'licenses'), $File.FullName).Replace('\', '/')
    Copy-SourceFile $File.FullName "licenses/$Relative"
}
foreach ($File in Get-ChildItem -LiteralPath (Join-Path $FfmpegBuildRoot 'provenance') -File) {
    if ($File.Name -in @($SourceName, $SignatureName, 'ffmpeg-release-signing-key.asc')) { continue }
    Copy-SourceFile $File.FullName "build-evidence/$($File.Name)"
}
foreach ($File in Get-ChildItem -LiteralPath $AuditDirectory -File) {
    Copy-SourceFile $File.FullName "audit-evidence/$($File.Name)"
}

$ManifestFiles = @(Get-TreeManifest -Root $Stage -Exclude @('SOURCE-MANIFEST.json', 'SHA256SUMS'))
$Manifest = [ordered]@{
    schema = 1
    package = "$AssetStem-ffmpeg-corresponding-source"
    generated = [DateTimeOffset]::FromUnixTimeSeconds($SourceDateEpoch).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    ffmpegVersion = $Metadata.ffmpeg.version
    ffmpegSourceCommit = $Metadata.ffmpeg.source_commit
    patchesApplied = 0
    files = $ManifestFiles
}
$Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Stage 'SOURCE-MANIFEST.json') -Encoding utf8NoBOM
$HashFiles = @(Get-TreeManifest -Root $Stage -Exclude @('SHA256SUMS'))
Set-Content -LiteralPath (Join-Path $Stage 'SHA256SUMS') -Value @($HashFiles | ForEach-Object { "$($_.sha256)  $($_.path)" }) -Encoding utf8NoBOM

$ArchivePath = Join-Path $OutputDirectory "$AssetStem-ffmpeg-corresponding-source.zip"
New-DeterministicZip -SourceDirectory $Stage -DestinationPath $ArchivePath -ExecutablePaths @(
    'scripts/release/build-ffmpeg.sh',
    'scripts/release/Validate-TarArchive.sh',
    'scripts/release/tests/Test-SafeTar.Tests.sh'
)
$ArchiveHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$ArchivePath.sha256" -Value "$ArchiveHash  $(Split-Path $ArchivePath -Leaf)" -Encoding ascii
Remove-Item -LiteralPath $Stage -Recurse -Force
Write-Host "Corresponding-source ZIP created: $ArchivePath"
Write-Host "Corresponding-source ZIP SHA-256: $ArchiveHash"
