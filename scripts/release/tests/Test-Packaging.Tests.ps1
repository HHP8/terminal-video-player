[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$ModulePath = Join-Path $RepoRoot 'scripts\release\ReleaseTools.psm1'
$RequiredPrograms = @(
    'New-PortablePackage.ps1',
    'New-CorrespondingSource.ps1',
    'New-Sbom.ps1',
    'New-Provenance.ps1',
    'Test-PortablePackage.ps1'
)
if (-not (Test-Path -LiteralPath $ModulePath -PathType Leaf)) {
    throw "Release-tools module is missing: $ModulePath"
}
foreach ($Program in $RequiredPrograms) {
    $Path = Join-Path (Join-Path $RepoRoot 'scripts\release') $Program
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required packaging program is missing: $Path"
    }
    [void][ScriptBlock]::Create((Get-Content -LiteralPath $Path -Raw))
}

Import-Module $ModulePath -Force
$TestRoot = Join-Path (Join-Path $RepoRoot '.cache\release-tests') ([Guid]::NewGuid().ToString('N'))
$InputRoot = Join-Path $TestRoot 'payload'
$FirstZip = Join-Path $TestRoot 'first.zip'
$SecondZip = Join-Path $TestRoot 'second.zip'
$ExtractRoot = Join-Path $TestRoot 'extracted path 漢字'
New-Item -ItemType Directory -Path (Join-Path $InputRoot 'nested') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $InputRoot 'alpha.txt') -Value 'alpha' -Encoding utf8NoBOM
Set-Content -LiteralPath (Join-Path $InputRoot 'nested\beta.txt') -Value 'beta' -Encoding utf8NoBOM

$FirstManifest = @(Get-TreeManifest -Root $InputRoot)
if (($FirstManifest.path -join ',') -cne 'alpha.txt,nested/beta.txt') {
    throw 'Tree manifest paths are not normalized and sorted.'
}
foreach ($Entry in $FirstManifest) {
    if ($Entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $Entry.size -le 0) {
        throw 'Tree manifest contains an invalid hash or size.'
    }
}

New-DeterministicZip -SourceDirectory $InputRoot -DestinationPath $FirstZip
Start-Sleep -Milliseconds 20
New-DeterministicZip -SourceDirectory $InputRoot -DestinationPath $SecondZip
$FirstHash = (Get-FileHash -LiteralPath $FirstZip -Algorithm SHA256).Hash
$SecondHash = (Get-FileHash -LiteralPath $SecondZip -Algorithm SHA256).Hash
if ($FirstHash -cne $SecondHash) {
    throw 'Deterministic ZIP creation produced different hashes from identical inputs.'
}

Expand-SafeZip -ArchivePath $FirstZip -DestinationDirectory $ExtractRoot
$ExtractedManifest = @(Get-TreeManifest -Root $ExtractRoot)
if (($FirstManifest | ConvertTo-Json -Depth 4) -cne ($ExtractedManifest | ConvertTo-Json -Depth 4)) {
    throw 'Extracted files do not match the original deterministic manifest.'
}

$MaliciousZip = Join-Path $TestRoot 'traversal.zip'
$Stream = [IO.File]::Open($MaliciousZip, [IO.FileMode]::CreateNew)
try {
    $Archive = [IO.Compression.ZipArchive]::new($Stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $Entry = $Archive.CreateEntry('../escape.txt')
        $Writer = [IO.StreamWriter]::new($Entry.Open())
        try { $Writer.Write('blocked') } finally { $Writer.Dispose() }
    } finally { $Archive.Dispose() }
} finally { $Stream.Dispose() }

$Rejected = $false
try {
    Expand-SafeZip -ArchivePath $MaliciousZip -DestinationDirectory (Join-Path $TestRoot 'unsafe')
} catch {
    $Rejected = $true
}
if (-not $Rejected) {
    throw 'Safe ZIP extraction accepted a traversal entry.'
}

$Epoch = 1787691600
$ManifestPath = Join-Path $TestRoot 'package-manifest.json'
([ordered]@{ schema = 1; package = 'synthetic'; generated = '2026-08-25T17:00:00Z'; files = $FirstManifest } |
    ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $ManifestPath -Encoding utf8NoBOM
$ProvenanceOne = Join-Path $TestRoot 'provenance-one.json'
$ProvenanceTwo = Join-Path $TestRoot 'provenance-two.json'
$ProvenanceProgram = Join-Path $RepoRoot 'scripts\release\New-Provenance.ps1'
& $ProvenanceProgram -RepositoryRoot $RepoRoot -Version '0.1.1' `
    -Commit '0123456789abcdef0123456789abcdef01234567' -SourceDateEpoch $Epoch `
    -SubjectPaths (Join-Path $InputRoot 'alpha.txt') -OutputPath $ProvenanceOne
& $ProvenanceProgram -RepositoryRoot $RepoRoot -Version '0.1.1' `
    -Commit '0123456789abcdef0123456789abcdef01234567' -SourceDateEpoch $Epoch `
    -SubjectPaths (Join-Path $InputRoot 'alpha.txt') -OutputPath $ProvenanceTwo
if ((Get-FileHash $ProvenanceOne).Hash -cne (Get-FileHash $ProvenanceTwo).Hash) {
    throw 'Provenance generation is not deterministic.'
}
$Provenance = Get-Content -LiteralPath $ProvenanceOne -Raw | ConvertFrom-Json
if ($Provenance.predicateType -cne 'https://slsa.dev/provenance/v1' -or $Provenance.subject.Count -ne 1) {
    throw 'Provenance output is not the expected in-toto SLSA v1 statement.'
}

$SbomOne = Join-Path $TestRoot 'sbom-one.spdx.json'
$SbomTwo = Join-Path $TestRoot 'sbom-two.spdx.json'
$SbomProgram = Join-Path $RepoRoot 'scripts\release\New-Sbom.ps1'
$ReleaseMetadata = Get-Content -LiteralPath (Join-Path $RepoRoot 'third-party\ffmpeg-artifact.json') -Raw | ConvertFrom-Json
$ToolchainLicenses = Join-Path $TestRoot 'toolchain-licenses'
New-Item -ItemType Directory -Path $ToolchainLicenses | Out-Null
foreach ($License in @($ReleaseMetadata.toolchain.licenses)) {
    Set-Content -LiteralPath (Join-Path $ToolchainLicenses $License.output_name) `
        -Value "Synthetic test copy of $($License.component) terms." -Encoding utf8NoBOM
}
& $SbomProgram -RepositoryRoot $RepoRoot -Version '0.1.1' `
    -Commit '0123456789abcdef0123456789abcdef01234567' -SourceDateEpoch $Epoch `
    -PackageManifestPath $ManifestPath -ToolchainLicenseDirectory $ToolchainLicenses -OutputPath $SbomOne
& $SbomProgram -RepositoryRoot $RepoRoot -Version '0.1.1' `
    -Commit '0123456789abcdef0123456789abcdef01234567' -SourceDateEpoch $Epoch `
    -PackageManifestPath $ManifestPath -ToolchainLicenseDirectory $ToolchainLicenses -OutputPath $SbomTwo
if ((Get-FileHash $SbomOne).Hash -cne (Get-FileHash $SbomTwo).Hash) {
    throw 'SPDX generation is not deterministic.'
}
$Sbom = Get-Content -LiteralPath $SbomOne -Raw | ConvertFrom-Json
if ($Sbom.spdxVersion -cne 'SPDX-2.3' -or $Sbom.packages.Count -lt 2 -or $Sbom.files.Count -ne 2) {
    throw 'SPDX output does not contain the expected packages and files.'
}
if (@($Sbom.hasExtractedLicensingInfos).Count -ne 1 -or
    $Sbom.hasExtractedLicensingInfos[0].licenseId -cne 'LicenseRef-mingw-w64-runtime') {
    throw 'SPDX output does not define the custom mingw-w64 runtime license reference.'
}
$BuildDependencies = @($Sbom.relationships | Where-Object {
    $_.relationshipType -eq 'BUILD_DEPENDENCY_OF' -and
    $_.relatedSpdxElement -eq 'SPDXRef-Package-FFmpeg'
})
if ($BuildDependencies.Count -ne $ReleaseMetadata.toolchain.licenses.Count) {
    throw 'SPDX toolchain build-dependency relationships point in the wrong direction or are incomplete.'
}

$SyntheticBuild = Join-Path $TestRoot 'synthetic-ffmpeg'
$SyntheticAudit = Join-Path $TestRoot 'synthetic-audit'
$SyntheticPlayer = Join-Path $TestRoot 'terminal-video-player.exe'
New-Item -ItemType Directory -Path (Join-Path $SyntheticBuild 'bin'), `
    (Join-Path $SyntheticBuild 'licenses\ffmpeg'), `
    (Join-Path $SyntheticBuild 'licenses\toolchain'), `
    (Join-Path $SyntheticBuild 'provenance'), $SyntheticAudit -Force | Out-Null
Set-Content -LiteralPath $SyntheticPlayer -Value 'synthetic player' -Encoding ascii
Set-Content -LiteralPath (Join-Path $SyntheticBuild 'bin\ffmpeg.exe') -Value 'synthetic ffmpeg' -Encoding ascii
Set-Content -LiteralPath (Join-Path $SyntheticBuild 'bin\ffprobe.exe') -Value 'synthetic ffprobe' -Encoding ascii
Set-Content -LiteralPath (Join-Path $SyntheticBuild 'licenses\ffmpeg\LICENSE.md') -Value 'FFmpeg LGPL notice' -Encoding ascii
Set-Content -LiteralPath (Join-Path $SyntheticBuild 'licenses\ffmpeg\COPYING.LGPLv2.1') -Value 'LGPL 2.1 terms' -Encoding ascii
foreach ($License in @($ReleaseMetadata.toolchain.licenses)) {
    Set-Content -LiteralPath (Join-Path $SyntheticBuild "licenses\toolchain\$($License.output_name)") `
        -Value "Verified $($License.component) terms" -Encoding utf8NoBOM
}
foreach ($Name in @('CONFIGURE-COMMAND.txt', 'TOOLCHAIN.txt')) {
    Set-Content -LiteralPath (Join-Path $SyntheticBuild "provenance\$Name") -Value "synthetic $Name" -Encoding ascii
}
Set-Content -LiteralPath (Join-Path $SyntheticBuild 'provenance\RUNNER.json') -Value '{}' -Encoding ascii
foreach ($Name in @(
    'FFMPEG-BUILDCONF.txt', 'FFMPEG-DECODERS.txt', 'FFMPEG-DEVICES.txt',
    'FFMPEG-ENCODERS.txt', 'FFMPEG-FILTERS.txt', 'FFMPEG-FORMATS.txt',
    'FFMPEG-LICENSE.txt', 'FFMPEG-PROTOCOLS.txt', 'FFMPEG-VERSION.txt',
    'FFPROBE-VERSION.txt'
)) {
    Set-Content -LiteralPath (Join-Path $SyntheticAudit $Name) -Value "synthetic $Name" -Encoding ascii
}
Set-Content -LiteralPath (Join-Path $SyntheticAudit 'FFMPEG-COMPONENTS.json') -Value '{}' -Encoding ascii
Set-Content -LiteralPath (Join-Path $SyntheticAudit 'FFMPEG-PE-IMPORTS.json') -Value '{}' -Encoding ascii

$PackageOne = Join-Path $TestRoot 'package-one'
$PackageTwo = Join-Path $TestRoot 'package-two'
$PackageProgram = Join-Path $RepoRoot 'scripts\release\New-PortablePackage.ps1'
foreach ($Output in @($PackageOne, $PackageTwo)) {
    & $PackageProgram -RepositoryRoot $RepoRoot -Version '0.1.1' -SourceDateEpoch $Epoch `
        -PlayerExecutable $SyntheticPlayer -FfmpegBuildRoot $SyntheticBuild `
        -AuditDirectory $SyntheticAudit -ProvenancePath $ProvenanceOne -OutputDirectory $Output
}
$PortableOne = Join-Path $PackageOne 'terminal-video-player-v0.1.1-portable-windows-x86_64.zip'
$PortableTwo = Join-Path $PackageTwo 'terminal-video-player-v0.1.1-portable-windows-x86_64.zip'
if ((Get-FileHash $PortableOne).Hash -cne (Get-FileHash $PortableTwo).Hash) {
    throw 'Complete portable package creation is not deterministic.'
}
& (Join-Path $RepoRoot 'scripts\release\Test-PortablePackage.ps1') `
    -RepositoryRoot $RepoRoot -ArchivePath $PortableOne `
    -MetadataPath (Join-Path $RepoRoot 'third-party\ffmpeg-artifact.json') `
    -ExtractionDirectory (Join-Path $TestRoot 'portable extracted 漢字') -SkipRuntime

Set-Content -LiteralPath (Join-Path $SyntheticBuild "provenance\$($ReleaseMetadata.ffmpeg.source_archive.name)") -Value 'synthetic source' -Encoding ascii
Set-Content -LiteralPath (Join-Path $SyntheticBuild "provenance\$($ReleaseMetadata.ffmpeg.source_signature.name)") -Value 'synthetic signature' -Encoding ascii
Copy-Item -LiteralPath (Join-Path $RepoRoot 'third-party\ffmpeg-release-signing-key.asc') `
    -Destination (Join-Path $SyntheticBuild 'provenance\ffmpeg-release-signing-key.asc')
$SourceOne = Join-Path $TestRoot 'source-one'
$SourceTwo = Join-Path $TestRoot 'source-two'
$SourceProgram = Join-Path $RepoRoot 'scripts\release\New-CorrespondingSource.ps1'
foreach ($Output in @($SourceOne, $SourceTwo)) {
    & $SourceProgram -RepositoryRoot $RepoRoot -Version '0.1.1' -SourceDateEpoch $Epoch `
        -FfmpegBuildRoot $SyntheticBuild -AuditDirectory $SyntheticAudit -OutputDirectory $Output
}
$SourceZipOne = Join-Path $SourceOne 'terminal-video-player-v0.1.1-ffmpeg-corresponding-source.zip'
$SourceZipTwo = Join-Path $SourceTwo 'terminal-video-player-v0.1.1-ffmpeg-corresponding-source.zip'
if ((Get-FileHash $SourceZipOne).Hash -cne (Get-FileHash $SourceZipTwo).Hash) {
    throw 'Corresponding-source bundle creation is not deterministic.'
}

Write-Host 'Deterministic packaging and extraction validation passed.'
