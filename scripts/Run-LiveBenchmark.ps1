[CmdletBinding()]
param(
    [ValidateRange(1, 3600)]
    [int]$Seconds = 10,
    [ValidateSet('motion', 'noise')]
    [string]$Pattern = 'motion',
    [ValidateSet('adaptive', 'full', 'delta', 'rows')]
    [string]$Renderer = 'adaptive',
    [ValidateSet('default', 'classic-ascii', 'detailed-ascii', 'gradient', 'half-block')]
    [string]$DisplayMode = 'default',
    [ValidateSet('auto', 'truecolor', 'color256', 'mono')]
    [string]$Color = 'auto',
    [ValidateRange(1, 60)]
    [int]$TargetFps = 30,
    [Parameter(Mandatory = $true)]
    [string]$Report,
    [string]$Executable
)

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($Executable)) {
    $Executable = Join-Path (Join-Path (Join-Path $RepoRoot 'target') 'release') `
        'terminal-video-player.exe'
}
$Executable = [IO.Path]::GetFullPath($Executable)
$Report = [IO.Path]::GetFullPath($Report)

if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
    throw "Benchmark executable not found: $Executable"
}

& $Executable `
    --display-mode $DisplayMode `
    --color $Color `
    benchmark `
    --seconds $Seconds `
    --live `
    --renderer $Renderer `
    --pattern $Pattern `
    --target-fps $TargetFps `
    --report $Report
if ($LASTEXITCODE -ne 0) {
    throw "Live benchmark failed with exit code $LASTEXITCODE"
}
