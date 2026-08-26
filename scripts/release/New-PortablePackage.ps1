[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$RepositoryRoot,
    [Parameter(Mandatory)] [ValidatePattern('^\d+\.\d+\.\d+$')] [string]$Version,
    [Parameter(Mandatory)] [long]$SourceDateEpoch,
    [Parameter(Mandatory)] [string]$PlayerExecutable,
    [Parameter(Mandatory)] [string]$FfmpegBuildRoot,
    [Parameter(Mandatory)] [string]$AuditDirectory,
    [Parameter(Mandatory)] [string]$ProvenancePath,
    [Parameter(Mandatory)] [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
Import-Module (Join-Path $PSScriptRoot 'ReleaseTools.psm1') -Force
$Metadata = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'third-party\ffmpeg-artifact.json') -Raw | ConvertFrom-Json
$AssetStem = "terminal-video-player-v$Version"
$Stage = Join-Path $OutputDirectory 'portable-stage'
if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
New-Item -ItemType Directory -Path $Stage -Force | Out-Null

function Copy-RequiredFile {
    param([string]$Source, [string]$RelativeDestination)
    $Source = [IO.Path]::GetFullPath($Source)
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Required package input is missing: $Source" }
    Assert-SafeRelativePath $RelativeDestination
    $Destination = Join-Path $Stage $RelativeDestination.Replace('/', '\')
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination
}

Copy-RequiredFile $PlayerExecutable 'terminal-video-player.exe'
Copy-RequiredFile (Join-Path $FfmpegBuildRoot 'bin\ffmpeg.exe') 'tools/ffmpeg/ffmpeg.exe'
Copy-RequiredFile (Join-Path $FfmpegBuildRoot 'bin\ffprobe.exe') 'tools/ffmpeg/ffprobe.exe'
Copy-RequiredFile (Join-Path $RepositoryRoot 'portable\README-PORTABLE.md') 'README-PORTABLE.md'
Copy-RequiredFile (Join-Path $RepositoryRoot 'LICENSE') 'LICENSE'
Copy-RequiredFile (Join-Path $RepositoryRoot 'THIRD-PARTY-NOTICES.md') 'THIRD-PARTY-NOTICES.md'
Copy-RequiredFile (Join-Path $FfmpegBuildRoot 'licenses\ffmpeg\LICENSE.md') 'licenses/FFmpeg/LICENSE.md'
Copy-RequiredFile (Join-Path $FfmpegBuildRoot 'licenses\ffmpeg\COPYING.LGPLv2.1') 'licenses/FFmpeg/COPYING.LGPLv2.1'
Copy-RequiredFile (Join-Path $FfmpegBuildRoot 'licenses\toolchain\LLVM-LICENSE.txt') 'licenses/Toolchain/LLVM-LICENSE.txt'
Copy-RequiredFile (Join-Path $FfmpegBuildRoot 'licenses\toolchain\MINGW-W64-COPYING.txt') 'licenses/Toolchain/MINGW-W64-COPYING.txt'
Copy-RequiredFile (Join-Path $FfmpegBuildRoot 'licenses\toolchain\MINGW-W64-RUNTIME.txt') 'licenses/Toolchain/MINGW-W64-RUNTIME.txt'

foreach ($Name in @(
    'FFMPEG-BUILDCONF.txt', 'FFMPEG-COMPONENTS.json', 'FFMPEG-DECODERS.txt',
    'FFMPEG-DEVICES.txt', 'FFMPEG-ENCODERS.txt', 'FFMPEG-FILTERS.txt',
    'FFMPEG-FORMATS.txt', 'FFMPEG-LICENSE.txt', 'FFMPEG-PE-IMPORTS.json',
    'FFMPEG-PROTOCOLS.txt', 'FFMPEG-VERSION.txt', 'FFPROBE-VERSION.txt'
)) {
    Copy-RequiredFile (Join-Path $AuditDirectory $Name) "provenance/$Name"
}
foreach ($Name in @('CONFIGURE-COMMAND.txt', 'RUNNER.json', 'TOOLCHAIN.txt')) {
    Copy-RequiredFile (Join-Path $FfmpegBuildRoot "provenance\$Name") "provenance/$Name"
}
Copy-RequiredFile $ProvenancePath 'provenance/PROVENANCE.json'

$ManifestDirectory = Join-Path $Stage 'manifest'
New-Item -ItemType Directory -Path $ManifestDirectory -Force | Out-Null
$PayloadFiles = @(Get-TreeManifest -Root $Stage -Exclude @('manifest/PACKAGE-MANIFEST.json', 'manifest/SHA256SUMS'))
$Manifest = [ordered]@{
    schema = 1
    package = $AssetStem
    generated = [DateTimeOffset]::FromUnixTimeSeconds($SourceDateEpoch).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    files = $PayloadFiles
}
$InternalManifest = Join-Path $ManifestDirectory 'PACKAGE-MANIFEST.json'
$Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $InternalManifest -Encoding utf8NoBOM
$HashedFiles = @(Get-TreeManifest -Root $Stage -Exclude @('manifest/SHA256SUMS'))
$HashLines = @($HashedFiles | ForEach-Object { "$($_.sha256)  $($_.path)" })
Set-Content -LiteralPath (Join-Path $ManifestDirectory 'SHA256SUMS') -Value $HashLines -Encoding utf8NoBOM

$ActualPaths = @((Get-TreeManifest -Root $Stage).path | Sort-Object -CaseSensitive)
$ExpectedPaths = @($Metadata.package.runtime_files | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)
if (($ActualPaths -join "`n") -cne ($ExpectedPaths -join "`n")) {
    throw "Portable package inventory differs from its allowlist. Expected [$($ExpectedPaths -join ', ')], found [$($ActualPaths -join ', ')]."
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$ArchivePath = Join-Path $OutputDirectory "$AssetStem-portable-windows-x86_64.zip"
$ExternalManifest = Join-Path $OutputDirectory "$AssetStem-manifest.json"
Copy-Item -LiteralPath $InternalManifest -Destination $ExternalManifest
New-DeterministicZip -SourceDirectory $Stage -DestinationPath $ArchivePath
$ArchiveHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$ArchivePath.sha256" -Value "$ArchiveHash  $(Split-Path $ArchivePath -Leaf)" -Encoding ascii

Write-Host "Portable ZIP created: $ArchivePath"
Write-Host "Portable ZIP SHA-256: $ArchiveHash"
