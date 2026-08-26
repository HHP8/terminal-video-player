[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$ValidatorPath = Join-Path $RepoRoot 'scripts\release\Test-ReleaseMetadata.ps1'
$MetadataPath = Join-Path $RepoRoot 'third-party\ffmpeg-artifact.json'
$ComponentsPath = Join-Path $RepoRoot 'third-party\ffmpeg-components.json'
$ActionsPath = Join-Path $RepoRoot 'third-party\release-actions.json'

if (-not (Test-Path -LiteralPath $ValidatorPath -PathType Leaf)) {
    throw "Release metadata validator is missing: $ValidatorPath"
}

& $ValidatorPath `
    -MetadataPath $MetadataPath `
    -ComponentsPath $ComponentsPath `
    -ActionsPath $ActionsPath

$Metadata = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
if ($Metadata.schema -ne 2) {
    throw 'FFmpeg release metadata must use schema 2.'
}
if ($Metadata.ffmpeg.expected_license -ne 'LGPL-2.1-or-later') {
    throw 'The FFmpeg license posture must be LGPL-2.1-or-later.'
}
foreach ($Flag in @('--enable-gpl', '--enable-nonfree', '--enable-version3')) {
    if ($Flag -notin @($Metadata.ffmpeg.rejected_flags)) {
        throw "Rejected FFmpeg flag is missing: $Flag"
    }
}

$KeyEol = git -C $RepoRoot check-attr eol -- third-party/ffmpeg-release-signing-key.asc
if ($LASTEXITCODE -ne 0 -or $KeyEol -notmatch ': eol: lf$') {
    throw 'The vendored FFmpeg signing key must be checked out with LF line endings.'
}

Write-Host 'Release metadata validation passed.'
