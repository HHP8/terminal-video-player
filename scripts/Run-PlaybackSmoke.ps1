[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Media,
    [Parameter(Mandatory = $true)]
    [string]$Report,
    [string]$Executable,
    [ValidateSet('default', 'classic-ascii', 'detailed-ascii', 'gradient', 'half-block')]
    [string]$DisplayMode = 'default',
    [switch]$NoAudio
)

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($Executable)) {
    $Executable = Join-Path (Join-Path (Join-Path $RepoRoot 'target') 'release') `
        'terminal-video-player.exe'
}
$Executable = [IO.Path]::GetFullPath($Executable)
$Media = [IO.Path]::GetFullPath($Media)
$Report = [IO.Path]::GetFullPath($Report)

if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
    throw "Playback executable not found: $Executable"
}
if (-not (Test-Path -LiteralPath $Media -PathType Leaf)) {
    throw "Playback fixture not found: $Media"
}

$FfmpegDirectory = Join-Path (Join-Path ([IO.Path]::GetDirectoryName($Executable)) 'tools') 'ffmpeg'
if (-not (Test-Path -LiteralPath (Join-Path $FfmpegDirectory 'ffmpeg.exe') -PathType Leaf)) {
    $FfmpegDirectory = Join-Path (Join-Path $RepoRoot 'tools') 'ffmpeg'
}

$arguments = @(
    $Media,
    '--display-mode', $DisplayMode,
    '--start-muted',
    '--ffmpeg-dir', $FfmpegDirectory
)
if ($NoAudio) {
    $arguments = @(
        $Media,
        '--display-mode', $DisplayMode,
        '--no-audio',
        '--ffmpeg-dir', $FfmpegDirectory
    )
}

$started = [Diagnostics.Stopwatch]::StartNew()
& $Executable @arguments
$exitCode = $LASTEXITCODE
$started.Stop()

$result = @(
    "exit_code=$exitCode"
    "elapsed_ms=$([math]::Round($started.Elapsed.TotalMilliseconds, 1))"
    "media_name=$([IO.Path]::GetFileName($Media))"
    "no_audio=$($NoAudio.IsPresent)"
    "display_mode=$DisplayMode"
)
Set-Content -LiteralPath $Report -Value $result -Encoding UTF8
if ($exitCode -ne 0) {
    throw "Playback smoke failed with exit code $exitCode"
}
