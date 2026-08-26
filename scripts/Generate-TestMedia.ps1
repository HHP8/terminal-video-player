[CmdletBinding()]
param(
    [ValidateRange(10, 3600)]
    [int]$DurationSeconds = 600,
    [ValidatePattern('^\d+x\d+$')]
    [string]$Resolution = '1920x1080',
    [string]$FfmpegDirectory,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($FfmpegDirectory)) {
    $FfmpegDirectory = Join-Path (Join-Path $RepoRoot 'tools') 'ffmpeg'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path (Join-Path $RepoRoot '.cache') 'test-media'
}
$Ffmpeg = Join-Path $FfmpegDirectory 'ffmpeg.exe'
if (-not (Test-Path -LiteralPath $Ffmpeg -PathType Leaf)) {
    throw "Compatible ffmpeg.exe not found at $Ffmpeg. Provide the verified source-built tools."
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$Output = Join-Path $OutputDirectory ("flash-click-{0}-{1}s.mp4" -f $Resolution, $DurationSeconds)
$videoFilter = "drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='lt(mod(t,1),0.08)'"
$audioExpression = "if(lt(mod(t\,1)\,0.05)\,0.8*sin(2*PI*1000*t)\,0)"

& $Ffmpeg -hide_banner -y `
    -f lavfi -i "color=c=black:s=${Resolution}:r=30:d=$DurationSeconds" `
    -f lavfi -i "aevalsrc=${audioExpression}:s=48000:d=$DurationSeconds" `
    -vf $videoFilter `
    -c:v mpeg4 -q:v 5 -pix_fmt yuv420p `
    -c:a aac -ar 48000 -ac 2 -shortest `
    $Output
if ($LASTEXITCODE -ne 0) {
    throw "FFmpeg test-media generation failed with exit code $LASTEXITCODE"
}
Write-Host "Generated synchronized flash/click fixture: $Output"
