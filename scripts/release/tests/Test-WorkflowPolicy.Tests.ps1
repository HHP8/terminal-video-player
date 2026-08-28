[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$WorkflowPath = Join-Path $RepoRoot '.github\workflows\portable-release.yml'
if (-not (Test-Path -LiteralPath $WorkflowPath -PathType Leaf)) {
    throw "Portable release workflow is missing: $WorkflowPath"
}
$Workflow = Get-Content -LiteralPath $WorkflowPath -Raw
$Actions = Get-Content -LiteralPath (Join-Path $RepoRoot 'third-party\release-actions.json') -Raw | ConvertFrom-Json

foreach ($Term in @(
    'workflow_dispatch:',
    'pull_request:',
    "'v[0-9]+.[0-9]+.[0-9]+'",
    'contents: read',
    'metadata:',
    'rust-quality:',
    'ffmpeg-build:',
    'ffmpeg-reproducibility:',
    'ffmpeg-audit:',
    'player-build:',
    'package:',
    'runtime-validation:',
    'reproducibility:',
    'publish:',
    'matrix:',
    'replica: [a, b]',
    'persist-credentials: false',
    'contents: write',
    'gh release create',
    '--prerelease'
)) {
    if (-not $Workflow.Contains($Term, [StringComparison]::Ordinal)) {
        throw "Portable workflow is missing required policy term: $Term"
    }
}

foreach ($Action in @($Actions.actions)) {
    $Use = "uses: $($Action.repository)@$($Action.commit)"
    if (-not $Workflow.Contains($Use, [StringComparison]::Ordinal)) {
        throw "Portable workflow does not use the reviewed action commit: $Use"
    }
}
$Uses = @([regex]::Matches($Workflow, '(?m)^\s*uses:\s*([^\s]+)$') | ForEach-Object { $_.Groups[1].Value })
foreach ($Use in $Uses) {
    if ($Use -notmatch '@[0-9a-f]{40}$') { throw "Workflow action is not pinned to a full commit SHA: $Use" }
}
if ([regex]::Matches($Workflow, '(?m)^\s+contents:\s+write\s*$').Count -ne 1) {
    throw 'Exactly one workflow job may receive contents: write.'
}
if ($Workflow -match '(?i)(pull_request_target|force-push|--force|release delete|tag -d|workflow_dispatch:\s*\r?\n\s*inputs:)') {
    throw 'Portable workflow contains a forbidden trigger, destructive command, or arbitrary manual input.'
}
if ($Workflow -notmatch "(?s)publish:.*needs:.*reproducibility.*if:.*refs/tags/v") {
    throw 'Publication is not gated on reproducibility and an authorized version tag.'
}
$FfmpegCompare = $Workflow.IndexOf('ffmpeg-reproducibility:', [StringComparison]::Ordinal)
$FfmpegAudit = $Workflow.IndexOf('ffmpeg-audit:', [StringComparison]::Ordinal)
$PackageCompare = $Workflow.IndexOf("`n  reproducibility:", [StringComparison]::Ordinal)
$Runtime = $Workflow.IndexOf('runtime-validation:', [StringComparison]::Ordinal)
if ($FfmpegCompare -lt 0 -or $FfmpegAudit -lt 0 -or $FfmpegCompare -gt $FfmpegAudit) {
    throw 'FFmpeg replicas must be compared before audit or execution.'
}
if ($PackageCompare -lt 0 -or $Runtime -lt 0 -or $PackageCompare -gt $Runtime) {
    throw 'Release assets must be compared before extracted runtime validation.'
}
if ($Workflow -notmatch '(?s)publish:.*permissions:\s*\r?\n\s*contents: write') {
    throw 'Only the final publication job may request write permission.'
}

$PortableValidator = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\release\Test-PortablePackage.ps1') -Raw
foreach ($RuntimeContract in @(
    'validate-media',
    'validation-still.png',
    'validation-animation.gif',
    'flash-click-320x180-10s.mp4',
    "@('default', 'classic-ascii', 'detailed-ascii', 'gradient', 'half-block')"
)) {
    if (-not $PortableValidator.Contains($RuntimeContract, [StringComparison]::Ordinal)) {
        throw "Extracted-package validation is missing runtime contract: $RuntimeContract"
    }
}
if ($Workflow -match '(?s)Run packaged FFmpeg integration tests.*cargo test') {
    throw 'Runtime validation must exercise the extracted packaged player rather than a checkout-built test binary.'
}
if (-not $Workflow.Contains('target-feature=+crt-static', [StringComparison]::Ordinal)) {
    throw 'Portable player builds must statically link the MSVC runtime.'
}
foreach ($RemapRoot in @('$env:USERPROFILE', '$env:CARGO_HOME', '$env:RUSTUP_HOME', '$env:RUNNER_TEMP')) {
    if (-not $Workflow.Contains($RemapRoot, [StringComparison]::Ordinal)) {
        throw "Portable player builds do not remap private build-host root: $RemapRoot"
    }
}
foreach ($RunnerProvenanceTerm in @(
    "requested_image = 'windows-2025'",
    'WINDOWS-RUNNER-RESOLVED.json',
    'RunnerMetadataA',
    'RunnerMetadataB',
    'generated_asset_suffixes'
)) {
    if (-not $Workflow.Contains($RunnerProvenanceTerm, [StringComparison]::Ordinal)) {
        throw "Portable workflow does not separate reproducible payload metadata from exact runner provenance: $RunnerProvenanceTerm"
    }
}
if ($Workflow.Contains('$Assets.Count -ne 7', [StringComparison]::Ordinal)) {
    throw 'Publication inventory count must be derived from reviewed metadata.'
}

$Components = Get-Content -LiteralPath (Join-Path $RepoRoot 'third-party\ffmpeg-components.json') -Raw | ConvertFrom-Json
if (@($Components.allowed_player_pe_imports | Where-Object { $_ -match '(?i)^VCRUNTIME.*\.dll$' }).Count -ne 0) {
    throw 'Portable player import policy must not allow a redistributable VC runtime DLL.'
}

Write-Host 'Portable workflow policy validation passed.'
