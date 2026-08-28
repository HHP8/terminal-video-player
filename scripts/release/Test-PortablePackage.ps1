[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$RepositoryRoot,
    [Parameter(Mandatory)] [string]$ArchivePath,
    [Parameter(Mandatory)] [string]$MetadataPath,
    [Parameter(Mandatory)] [string]$ExtractionDirectory,
    [switch]$SkipRuntime
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
Import-Module (Join-Path $PSScriptRoot 'ReleaseTools.psm1') -Force
$Metadata = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
Expand-SafeZip -ArchivePath $ArchivePath -DestinationDirectory $ExtractionDirectory
$ExtractionDirectory = [IO.Path]::GetFullPath($ExtractionDirectory)

$ActualPaths = @((Get-TreeManifest -Root $ExtractionDirectory).path | Sort-Object -CaseSensitive)
$ExpectedPaths = @($Metadata.package.runtime_files | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)
$ExpectedPrefixes = @($Metadata.package.runtime_prefixes | ForEach-Object { [string]$_ })
$Missing = @($ExpectedPaths | Where-Object { $_ -notin $ActualPaths })
$Unexpected = @($ActualPaths | Where-Object {
    $Path = $_
    $Path -notin $ExpectedPaths -and @($ExpectedPrefixes | Where-Object {
        $Path.StartsWith($_, [StringComparison]::Ordinal)
    }).Count -eq 0
})
if ($Missing.Count -ne 0 -or $Unexpected.Count -ne 0) {
    throw 'Extracted portable inventory differs from the reviewed allowlist.'
}

$ManifestPath = Join-Path $ExtractionDirectory 'manifest\PACKAGE-MANIFEST.json'
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$ManifestPaths = @($Manifest.files.path | Sort-Object -CaseSensitive)
$ExpectedManifestPaths = @($ActualPaths | Where-Object { $_ -notin @('manifest/PACKAGE-MANIFEST.json', 'manifest/SHA256SUMS') })
if (($ManifestPaths -join "`n") -cne ($ExpectedManifestPaths -join "`n")) {
    throw 'Internal package manifest does not cover every payload file.'
}
foreach ($Entry in @($Manifest.files)) {
    Assert-SafeRelativePath ([string]$Entry.path)
    $Path = Join-Path $ExtractionDirectory ([string]$Entry.path).Replace('/', '\')
    $File = Get-Item -LiteralPath $Path
    if ($File.Length -ne [int64]$Entry.size) { throw "Package size mismatch: $($Entry.path)" }
    $Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Hash -cne [string]$Entry.sha256) { throw "Package SHA-256 mismatch: $($Entry.path)" }
}

$SumLines = Get-Content -LiteralPath (Join-Path $ExtractionDirectory 'manifest\SHA256SUMS')
foreach ($Line in $SumLines) {
    if ($Line -cnotmatch '^(?<hash>[0-9a-f]{64})  (?<path>.+)$') { throw "Malformed SHA256SUMS line: $Line" }
    Assert-SafeRelativePath $Matches.path
    $Path = Join-Path $ExtractionDirectory $Matches.path.Replace('/', '\')
    $Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Hash -cne $Matches.hash) { throw "SHA256SUMS mismatch: $($Matches.path)" }
}

$Executables = @($ActualPaths | Where-Object { [IO.Path]::GetExtension($_) -ieq '.exe' })
$ExpectedExecutables = @('terminal-video-player.exe', 'tools/ffmpeg/ffmpeg.exe', 'tools/ffmpeg/ffprobe.exe')
if (($Executables -join "`n") -cne ($ExpectedExecutables -join "`n")) {
    throw 'Portable package contains an unexpected executable.'
}
if (@($ActualPaths | Where-Object { [IO.Path]::GetExtension($_) -in @('.dll', '.pdb', '.msi', '.7z', '.rar', '.tar', '.xz') }).Count -ne 0) {
    throw 'Portable package contains a forbidden binary, debug, installer, or archive file.'
}

$TextExtensions = @('.md', '.txt', '.json', '')
foreach ($Relative in $ActualPaths) {
    if ([IO.Path]::GetExtension($Relative).ToLowerInvariant() -notin $TextExtensions) { continue }
    $Text = Get-Content -LiteralPath (Join-Path $ExtractionDirectory $Relative.Replace('/', '\')) -Raw
    if ($Text -match '[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF]') { throw "Persian or Arabic script found in package text: $Relative" }
    if ($Text -match '(?i)(C:\\Users\\|/home/runner/|GITHUB_TOKEN|ghp_[A-Za-z0-9]+|BEGIN (RSA |OPENSSH )?PRIVATE KEY)') {
        throw "Sensitive or machine-specific text found in package: $Relative"
    }
}

if (-not $SkipRuntime) {
    $Player = Join-Path $ExtractionDirectory 'terminal-video-player.exe'
    $FfmpegDirectory = Join-Path $ExtractionDirectory 'tools\ffmpeg'
    $Ffmpeg = Join-Path $FfmpegDirectory 'ffmpeg.exe'
    $Ffprobe = Join-Path $FfmpegDirectory 'ffprobe.exe'
    $Before = @(Get-Process -Name 'terminal-video-player', 'ffmpeg', 'ffprobe' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

    $Help = (& $Player --help 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'Packaged player --help failed.' }
    foreach ($Mode in @('default', 'classic-ascii', 'detailed-ascii', 'gradient', 'half-block')) {
        if (-not $Help.Contains($Mode, [StringComparison]::Ordinal)) { throw "Player help is missing display mode: $Mode" }
    }
    $OriginalPath = $env:PATH
    try {
        $env:PATH = "$env:SystemRoot\System32"
        $Diagnostics = (& $Player diagnostics 2>&1 | Out-String)
        $DiagnosticsExitCode = $LASTEXITCODE
    } finally {
        $env:PATH = $OriginalPath
    }
    if ($DiagnosticsExitCode -ne 0) { throw 'Packaged player diagnostics failed.' }
    if (-not $Diagnostics.Contains("FFmpeg directory: $FfmpegDirectory", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Packaged player did not resolve FFmpeg from its portable directory.'
    }

    $FixtureDirectory = Join-Path (Split-Path -Parent $ExtractionDirectory) 'runtime validation 漢字'
    New-Item -ItemType Directory -Path $FixtureDirectory -Force | Out-Null
    $Still = Join-Path $FixtureDirectory 'validation-still.png'
    $Gif = Join-Path $FixtureDirectory 'validation-animation.gif'
    & (Join-Path $RepositoryRoot 'scripts\release\New-PortableValidationImages.ps1') -OutputDirectory $FixtureDirectory
    & (Join-Path $RepositoryRoot 'scripts\Generate-TestMedia.ps1') -DurationSeconds 10 -Resolution '320x180' -FfmpegDirectory $FfmpegDirectory -OutputDirectory $FixtureDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Packaged FFmpeg fixture generation failed.' }
    $Fixture = Join-Path $FixtureDirectory 'flash-click-320x180-10s.mp4'
    if (-not (Test-Path -LiteralPath $Fixture -PathType Leaf)) { throw 'Packaged FFmpeg did not create the validation fixture.' }
    foreach ($Media in @($Still, $Gif, $Fixture)) {
        foreach ($Mode in @('default', 'classic-ascii', 'detailed-ascii', 'gradient', 'half-block')) {
            & $Player --ffmpeg-dir $FfmpegDirectory --display-mode $Mode validate-media $Media
            if ($LASTEXITCODE -ne 0) {
                throw "Packaged player media validation failed for $([IO.Path]::GetFileName($Media)) in $Mode mode."
            }
        }
    }
    & $Player --ffmpeg-dir $FfmpegDirectory validate-media 'concat:https://example.invalid/video.mp4' 2>$null
    if ($LASTEXITCODE -eq 0) { throw 'Packaged player unexpectedly accepted a nested network input.' }
    & $Ffprobe -v error -protocol_whitelist file,pipe -show_entries 'stream=codec_name,codec_type' -of json -i $Fixture | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Packaged ffprobe could not inspect the generated fixture.' }
    & $Ffprobe -v error -protocol_whitelist file,pipe -i 'concat:https://example.invalid/video.mp4' 2>$null
    if ($LASTEXITCODE -eq 0) { throw 'Packaged FFmpeg unexpectedly accepted a nested network input.' }

    Start-Sleep -Milliseconds 500
    $After = @(Get-Process -Name 'terminal-video-player', 'ffmpeg', 'ffprobe' -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $Before })
    if ($After.Count -ne 0) { throw "Portable validation left media processes running: $($After.Id -join ', ')" }
}

Write-Host 'Extracted portable package validation passed.'
