[CmdletBinding()]
param(
    [string]$CargoPath = 'cargo',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Artifacts = Join-Path $RepoRoot 'artifacts'
$RuntimeFfmpeg = Join-Path (Join-Path $RepoRoot 'tools') 'ffmpeg'
$MsvcTarget = 'x86_64-pc-windows-msvc'
$Executable = if ($SkipBuild) {
    Join-Path (Join-Path (Join-Path $RepoRoot 'target') 'release') 'terminal-video-player.exe'
}
else {
    Join-Path (Join-Path (Join-Path (Join-Path $RepoRoot 'target') $MsvcTarget) 'release') `
        'terminal-video-player.exe'
}
$cargoManifest = Get-Content -LiteralPath (Join-Path $RepoRoot 'Cargo.toml') -Raw
$versionMatch = [regex]::Match($cargoManifest, '(?m)^version\s*=\s*"([^"]+)"\s*$')
if (-not $versionMatch.Success) {
    throw 'Could not read the package version from Cargo.toml.'
}
$BuildLabel = if ($SkipBuild) { 'unverified-build' } else { 'msvc' }
$PackageName = "terminal-video-player-$($versionMatch.Groups[1].Value)-poc-windows-x64-$BuildLabel"
$Stage = Join-Path $Artifacts $PackageName
$Zip = Join-Path $Artifacts ($PackageName + '.zip')

function Assert-ArtifactsPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = $Artifacts.TrimEnd('\') + '\'
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package output must remain below $Artifacts"
    }
}

# Reconstruct the runtime from the hash-verified archive on every package run.
# This rejects partial, stale, modified, GPL, or nonfree payloads before copying.
& (Join-Path $PSScriptRoot 'Fetch-Ffmpeg.ps1') -Destination $RuntimeFfmpeg -Force

if (-not $SkipBuild) {
    Push-Location $RepoRoot
    try {
        & $CargoPath build --release --locked --target $MsvcTarget
        if ($LASTEXITCODE -ne 0) {
            throw "cargo build failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}
if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
    throw "Release executable not found: $Executable"
}
if ($SkipBuild) {
    Write-Warning 'Packaging an existing executable without proving its Rust target; the archive will be labeled unverified-build.'
}
else {
    $binaryText = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Executable))
    if ($binaryText.IndexOf('msvcrt.dll', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw 'The release executable appears to use the GNU runtime, but the POC package requires the MSVC target.'
    }
}

New-Item -ItemType Directory -Path $Artifacts -Force | Out-Null
foreach ($path in @($Stage, $Zip, ($Zip + '.sha256'))) {
    if (Test-Path -LiteralPath $path) {
        Assert-ArtifactsPath -Path $path
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

New-Item -ItemType Directory -Path $Stage -Force | Out-Null
Copy-Item -LiteralPath $Executable -Destination $Stage
Copy-Item -LiteralPath (Join-Path (Join-Path $RepoRoot 'docs') 'PORTABLE.md') `
    -Destination (Join-Path $Stage 'README.md')
Copy-Item -LiteralPath (Join-Path $RepoRoot 'README.md') `
    -Destination (Join-Path $Stage 'DEVELOPER.md')
Copy-Item -LiteralPath (Join-Path $RepoRoot 'LICENSE') -Destination $Stage
Copy-Item -LiteralPath (Join-Path $RepoRoot 'THIRD-PARTY-NOTICES.md') -Destination $Stage
$DocsStage = Join-Path $Stage 'docs'
Copy-Item -LiteralPath (Join-Path $RepoRoot 'docs') -Destination $DocsStage -Recurse
$ThirdPartyStage = Join-Path $Stage 'third-party'
New-Item -ItemType Directory -Path $ThirdPartyStage -Force | Out-Null
Copy-Item -LiteralPath (Join-Path (Join-Path $RepoRoot 'third-party') 'ffmpeg-artifact.json') `
    -Destination $ThirdPartyStage
$ToolStage = Join-Path (Join-Path $Stage 'tools') 'ffmpeg'
New-Item -ItemType Directory -Path $ToolStage -Force | Out-Null
Copy-Item -Path (Join-Path $RuntimeFfmpeg '*') -Destination $ToolStage -Recurse -Force
$StagedExecutable = Join-Path $Stage 'terminal-video-player.exe'
& $StagedExecutable --ffmpeg-dir $ToolStage diagnostics | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'The staged executable rejected the pinned FFmpeg runtime.'
}

$fileManifest = Join-Path $Stage 'PACKAGE-FILES.sha256'
$manifestLines = Get-ChildItem -LiteralPath $Stage -Recurse -File |
    Where-Object { $_.FullName -ne $fileManifest } |
    Sort-Object FullName |
    ForEach-Object {
        $relative = $_.FullName.Substring($Stage.Length + 1).Replace('\', '/')
        $fileHash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$fileHash  $relative"
    }
Set-Content -LiteralPath $fileManifest -Value $manifestLines -Encoding ASCII

Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath ($Zip + '.sha256') -Value "$hash  $([IO.Path]::GetFileName($Zip))" -Encoding ASCII

Write-Host "POC archive: $Zip"
Write-Host "SHA-256: $hash"
