[CmdletBinding()]
param(
    [string]$Destination,
    [string]$CacheDirectory,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$ManifestPath = Join-Path (Join-Path $RepoRoot 'third-party') 'ffmpeg-artifact.json'
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$ArtifactUrl = [string]$Manifest.asset_url
$ArtifactName = [string]$Manifest.asset
$ExpectedSha256 = ([string]$Manifest.sha256).ToLowerInvariant()
$ExpectedVersion = [string]$Manifest.runtime_version_token
$FfmpegCommit = [string]$Manifest.ffmpeg_source_commit
$FfmpegSourceUrl = [string]$Manifest.ffmpeg_source_url
$BuildCommit = [string]$Manifest.build_repository_commit
$LicenseFiles = @($Manifest.license_files)

if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path (Join-Path $RepoRoot 'tools') 'ffmpeg'
}
if ([string]::IsNullOrWhiteSpace($CacheDirectory)) {
    $CacheDirectory = Join-Path (Join-Path $RepoRoot '.cache') 'ffmpeg'
}
$Destination = [IO.Path]::GetFullPath($Destination)
$CacheDirectory = [IO.Path]::GetFullPath($CacheDirectory)

function Assert-ProjectPath {
    param([string]$Path, [string]$Label)
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = $RepoRoot.TrimEnd('\') + '\'
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under the repository root: $full"
    }
}

Assert-ProjectPath -Path $Destination -Label 'Destination'
Assert-ProjectPath -Path $CacheDirectory -Label 'Cache directory'

if ($PSVersionTable.PSVersion.Major -le 5) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

New-Item -ItemType Directory -Path $CacheDirectory -Force | Out-Null
$ArchivePath = Join-Path $CacheDirectory $ArtifactName
$PartialPath = $ArchivePath + '.partial'

$needsDownload = -not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)
if (-not $needsDownload) {
    $cachedHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $needsDownload = $cachedHash -ne $ExpectedSha256
}

if ($needsDownload) {
    if (Test-Path -LiteralPath $PartialPath) {
        Remove-Item -LiteralPath $PartialPath -Force
    }
    Write-Host "Downloading pinned FFmpeg artifact..."
    Invoke-WebRequest -Uri $ArtifactUrl -OutFile $PartialPath -UseBasicParsing
    $downloadHash = (Get-FileHash -LiteralPath $PartialPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($downloadHash -ne $ExpectedSha256) {
        Remove-Item -LiteralPath $PartialPath -Force
        throw "FFmpeg SHA-256 mismatch. Expected $ExpectedSha256, received $downloadHash."
    }
    Move-Item -LiteralPath $PartialPath -Destination $ArchivePath -Force
}

$verifiedHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($verifiedHash -ne $ExpectedSha256) {
    throw "Cached FFmpeg SHA-256 mismatch. Delete $ArchivePath and retry."
}

$ExpandDirectory = Join-Path $CacheDirectory 'expanded'
if (Test-Path -LiteralPath $ExpandDirectory) {
    Assert-ProjectPath -Path $ExpandDirectory -Label 'Expansion directory'
    Remove-Item -LiteralPath $ExpandDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $ExpandDirectory -Force | Out-Null
Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExpandDirectory -Force

$ffmpegExecutable = Get-ChildItem -LiteralPath $ExpandDirectory -Recurse -File -Filter 'ffmpeg.exe' |
    Select-Object -First 1
if ($null -eq $ffmpegExecutable) {
    throw 'The verified archive does not contain ffmpeg.exe.'
}
$BinDirectory = $ffmpegExecutable.Directory.FullName
$ffprobeExecutable = Join-Path $BinDirectory 'ffprobe.exe'
if (-not (Test-Path -LiteralPath $ffprobeExecutable -PathType Leaf)) {
    throw 'The verified archive does not contain ffprobe.exe beside ffmpeg.exe.'
}

$buildConfiguration = (& $ffmpegExecutable.FullName -hide_banner -buildconf 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
    throw 'The verified FFmpeg binary could not report its build configuration.'
}
$normalizedConfiguration = $buildConfiguration.ToLowerInvariant()
foreach ($required in @($Manifest.expected_flags)) {
    if (-not $normalizedConfiguration.Contains($required)) {
        throw "FFmpeg is missing required build flag $required."
    }
}
foreach ($rejected in @($Manifest.rejected_flags)) {
    if ($normalizedConfiguration.Contains($rejected)) {
        throw "FFmpeg contains rejected build flag $rejected."
    }
}
$versionText = (& $ffmpegExecutable.FullName -version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or -not $versionText.Contains($ExpectedVersion)) {
    throw "FFmpeg version mismatch. Expected token $ExpectedVersion."
}

if (Test-Path -LiteralPath $Destination) {
    if (-not $Force) {
        throw "Destination already exists: $Destination. Re-run with -Force to replace it."
    }
    Assert-ProjectPath -Path $Destination -Label 'Destination'
    Remove-Item -LiteralPath $Destination -Recurse -Force
}
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
foreach ($runtimeFile in @('ffmpeg.exe', 'ffprobe.exe')) {
    Copy-Item -LiteralPath (Join-Path $BinDirectory $runtimeFile) -Destination $Destination -Force
}
Copy-Item -Path (Join-Path $BinDirectory '*.dll') -Destination $Destination -Force

$licenseDirectory = Join-Path $Destination 'LICENSES'
New-Item -ItemType Directory -Path $licenseDirectory -Force | Out-Null
foreach ($license in $LicenseFiles) {
    $cachedLicense = Join-Path $CacheDirectory ([string]$license.name)
    $licenseNeedsDownload = -not (Test-Path -LiteralPath $cachedLicense -PathType Leaf)
    if (-not $licenseNeedsDownload) {
        $licenseHash = (Get-FileHash -LiteralPath $cachedLicense -Algorithm SHA256).Hash.ToLowerInvariant()
        $licenseNeedsDownload = $licenseHash -ne ([string]$license.sha256)
    }
    if ($licenseNeedsDownload) {
        Invoke-WebRequest -Uri ([string]$license.url) -OutFile $cachedLicense -UseBasicParsing
    }
    $licenseHash = (Get-FileHash -LiteralPath $cachedLicense -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($licenseHash -ne ([string]$license.sha256)) {
        throw "License file $($license.name) failed SHA-256 verification."
    }
    Copy-Item -LiteralPath $cachedLicense -Destination $licenseDirectory -Force
}
$archiveLicense = Join-Path $ffmpegExecutable.Directory.Parent.FullName 'LICENSE.txt'
if (-not (Test-Path -LiteralPath $archiveLicense -PathType Leaf)) {
    throw 'The verified FFmpeg archive does not contain its top-level LICENSE.txt.'
}
Copy-Item -LiteralPath $archiveLicense `
    -Destination (Join-Path $licenseDirectory 'BtbN-FFmpeg-LICENSE.txt') -Force

Set-Content -LiteralPath (Join-Path $Destination 'BUILD-CONFIG.txt') -Value $buildConfiguration -Encoding UTF8
Set-Content -LiteralPath (Join-Path $Destination 'VERSION.txt') -Value $versionText -Encoding UTF8
$sourceText = @"
Artifact: $ArtifactUrl
SHA-256: $ExpectedSha256
FFmpeg source commit: $FfmpegCommit
Corresponding source: $FfmpegSourceUrl
Build recipe commit: $BuildCommit
Build recipe: https://github.com/BtbN/FFmpeg-Builds/commit/$BuildCommit
"@
Set-Content -LiteralPath (Join-Path $Destination 'SOURCE.txt') -Value $sourceText -Encoding UTF8

Write-Host "Verified FFmpeg runtime installed at $Destination"
Write-Host "SHA-256: $ExpectedSha256"
