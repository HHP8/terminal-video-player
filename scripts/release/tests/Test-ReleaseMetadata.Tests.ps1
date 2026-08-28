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

$MutationRoot = Join-Path $RepoRoot 'target\release-policy-tests\missing-wrapped-avframe'
if (Test-Path -LiteralPath $MutationRoot) {
    Remove-Item -LiteralPath $MutationRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $MutationRoot -Force | Out-Null
try {
    $MutatedComponentsPath = Join-Path $MutationRoot 'ffmpeg-components.json'
    $MutatedComponents = Get-Content -LiteralPath $ComponentsPath -Raw | ConvertFrom-Json
    $MutatedComponents.decoders = @($MutatedComponents.decoders | Where-Object { $_ -cne 'wrapped_avframe' })
    $MutatedComponents | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $MutatedComponentsPath -Encoding utf8NoBOM

    $ValidationFailure = $null
    try {
        & $ValidatorPath `
            -MetadataPath $MetadataPath `
            -ComponentsPath $MutatedComponentsPath `
            -ActionsPath $ActionsPath
    }
    catch {
        $ValidationFailure = $_.Exception.Message
    }
    if ($null -eq $ValidationFailure) {
        throw 'Release metadata validation accepted a component allowlist that cannot consume lavfi video fixtures.'
    }
    if (-not $ValidationFailure.Contains('wrapped_avframe', [StringComparison]::Ordinal)) {
        throw "The missing lavfi fixture decoder produced an unexpected validation error: $ValidationFailure"
    }
}
finally {
    Remove-Item -LiteralPath $MutationRoot -Recurse -Force -ErrorAction SilentlyContinue
}

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
foreach ($LicensePath in @(
    'licenses/Toolchain/LLVM-LICENSE.txt',
    'licenses/Toolchain/MINGW-W64-COPYING.txt',
    'licenses/Toolchain/MINGW-W64-RUNTIME.txt'
)) {
    if ($LicensePath -notin @($Metadata.package.runtime_files)) {
        throw "Required incorporated-toolchain notice is missing from the package allowlist: $LicensePath"
    }
}
foreach ($License in @($Metadata.toolchain.licenses)) {
    if ([string]::IsNullOrWhiteSpace($License.artifact_path)) {
        throw "Toolchain license entry is missing artifact_path: $($License.component)"
    }
}

$KeyEol = git -C $RepoRoot check-attr eol -- third-party/ffmpeg-release-signing-key.asc
if ($LASTEXITCODE -ne 0 -or $KeyEol -notmatch ': eol: lf$') {
    throw 'The vendored FFmpeg signing key must be checked out with LF line endings.'
}

$ProbeSource = Get-Content -LiteralPath (Join-Path $RepoRoot 'src\media\probe.rs') -Raw
foreach ($RequiredField in @('ffmpeg: FfmpegIdentity', 'build: FfmpegBuildPolicy', 'rejected_configuration_terms')) {
    if (-not $ProbeSource.Contains($RequiredField, [StringComparison]::Ordinal)) {
        throw "Rust runtime validation is not coupled to schema-2 release metadata: $RequiredField"
    }
}
if ($ProbeSource.Contains('runtime_version_token:', [StringComparison]::Ordinal)) {
    throw 'Rust runtime validation still depends on the removed prebuilt-provider version token.'
}

Write-Host 'Release metadata validation passed.'
