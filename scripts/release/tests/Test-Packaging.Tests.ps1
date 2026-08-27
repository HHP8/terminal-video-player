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
    'New-RustLicenseBundle.ps1',
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
Set-Content -LiteralPath (Join-Path $InputRoot 'nested\tool.sh') -Value '#!/usr/bin/env bash' -Encoding utf8NoBOM

$SyntheticRegistry = Join-Path $TestRoot 'cargo-registry\example-1.2.3'
$SyntheticRustLicenses = Join-Path $TestRoot 'rust-licenses'
New-Item -ItemType Directory -Path $SyntheticRegistry -Force | Out-Null
Set-Content -LiteralPath (Join-Path $SyntheticRegistry 'Cargo.toml') -Value '[package]' -Encoding ascii
Set-Content -LiteralPath (Join-Path $SyntheticRegistry 'LICENSE-MIT') -Value 'MIT terms' -Encoding ascii
Set-Content -LiteralPath (Join-Path $SyntheticRegistry 'NOTICE') -Value 'Required notice' -Encoding ascii
$SyntheticDevRegistry = Join-Path $TestRoot 'cargo-registry\dev-only-9.9.9'
New-Item -ItemType Directory -Path $SyntheticDevRegistry -Force | Out-Null
Set-Content -LiteralPath (Join-Path $SyntheticDevRegistry 'Cargo.toml') -Value '[package]' -Encoding ascii
Set-Content -LiteralPath (Join-Path $SyntheticDevRegistry 'LICENSE') -Value 'Dev-only terms' -Encoding ascii
$SyntheticCargoMetadata = Join-Path $TestRoot 'cargo-metadata.json'
@{
    packages = @(
        @{
            name = 'terminal-video-player'; version = '0.1.1'; source = $null
            manifest_path = (Join-Path $RepoRoot 'Cargo.toml'); license = 'MIT'; license_file = $null
        },
        @{
            name = 'example'; version = '1.2.3'; source = 'registry+https://github.com/rust-lang/crates.io-index'
            manifest_path = (Join-Path $SyntheticRegistry 'Cargo.toml'); license = 'MIT'; license_file = $null
        },
        @{
            name = 'dev-only'; version = '9.9.9'; source = 'registry+https://github.com/rust-lang/crates.io-index'
            manifest_path = (Join-Path $SyntheticDevRegistry 'Cargo.toml'); license = 'MIT'; license_file = $null
        }
    )
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $SyntheticCargoMetadata -Encoding utf8NoBOM
$SyntheticReleaseGraph = Join-Path $TestRoot 'release-packages.txt'
@('terminal-video-player v0.1.1', 'example v1.2.3') |
    Set-Content -LiteralPath $SyntheticReleaseGraph -Encoding utf8NoBOM
& (Join-Path $RepoRoot 'scripts\release\New-RustLicenseBundle.ps1') `
    -MetadataPath $SyntheticCargoMetadata -ReleasePackageListPath $SyntheticReleaseGraph `
    -OutputDirectory $SyntheticRustLicenses
$RustLicenseFiles = @((Get-TreeManifest -Root $SyntheticRustLicenses).path)
foreach ($ExpectedLicense in @(
    'RUST-DEPENDENCIES.json', 'example-1.2.3/LICENSE-MIT', 'example-1.2.3/NOTICE'
)) {
    if ($ExpectedLicense -notin $RustLicenseFiles) {
        throw "Rust dependency license bundle is missing: $ExpectedLicense"
    }
}
if ($RustLicenseFiles -contains 'dev-only-9.9.9/LICENSE') {
    throw 'Rust license bundle included a dev-only package outside the Windows release graph.'
}

$FirstManifest = @(Get-TreeManifest -Root $InputRoot)
if (($FirstManifest.path -join ',') -cne 'alpha.txt,nested/beta.txt,nested/tool.sh') {
    throw 'Tree manifest paths are not normalized and sorted.'
}
foreach ($Entry in $FirstManifest) {
    if ($Entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $Entry.size -le 0) {
        throw 'Tree manifest contains an invalid hash or size.'
    }
}

New-DeterministicZip -SourceDirectory $InputRoot -DestinationPath $FirstZip `
    -ExecutablePaths @('nested/tool.sh')
Start-Sleep -Milliseconds 20
New-DeterministicZip -SourceDirectory $InputRoot -DestinationPath $SecondZip `
    -ExecutablePaths @('nested/tool.sh')
$FirstHash = (Get-FileHash -LiteralPath $FirstZip -Algorithm SHA256).Hash
$SecondHash = (Get-FileHash -LiteralPath $SecondZip -Algorithm SHA256).Hash
if ($FirstHash -cne $SecondHash) {
    throw 'Deterministic ZIP creation produced different hashes from identical inputs.'
}
$ZipInspection = [IO.Compression.ZipFile]::OpenRead($FirstZip)
try {
    $ToolEntry = $ZipInspection.GetEntry('nested/tool.sh')
    if ($null -eq $ToolEntry -or (($ToolEntry.ExternalAttributes -shr 16) -band 511) -ne 493) {
        throw 'Deterministic ZIP did not preserve the reviewed executable mode for tool.sh.'
    }
} finally {
    $ZipInspection.Dispose()
}
$ZipBytes = [IO.File]::ReadAllBytes($FirstZip)
$CentralHeaders = 0
for ($Index = 0; $Index -le $ZipBytes.Length - 6; $Index++) {
    if ($ZipBytes[$Index] -eq 0x50 -and $ZipBytes[$Index + 1] -eq 0x4b -and
        $ZipBytes[$Index + 2] -eq 0x01 -and $ZipBytes[$Index + 3] -eq 0x02) {
        $CentralHeaders++
        if ($ZipBytes[$Index + 5] -ne 3) {
            throw 'Deterministic ZIP did not identify Unix mode metadata as Unix-originated.'
        }
    }
}
if ($CentralHeaders -ne $FirstManifest.Count) {
    throw 'Deterministic ZIP central-directory inspection did not cover every payload file.'
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

$Rejected = $false
$RejectionMessage = ''
try {
    Expand-SafeZip -ArchivePath $FirstZip `
        -DestinationDirectory (Join-Path $TestRoot 'oversized') -MaxTotalBytes 1
} catch {
    $Rejected = $true
    $RejectionMessage = $_.Exception.Message
}
if (-not $Rejected -or $RejectionMessage -notlike '*aggregate uncompressed size*') {
    throw 'Safe ZIP extraction accepted content beyond its aggregate byte budget.'
}

$Rejected = $false
$RejectionMessage = ''
try {
    Expand-SafeZip -ArchivePath $FirstZip `
        -DestinationDirectory (Join-Path $TestRoot 'too-many-entries') -MaxEntries 1
} catch {
    $Rejected = $true
    $RejectionMessage = $_.Exception.Message
}
if (-not $Rejected -or $RejectionMessage -notlike '*entry-count limit*') {
    throw 'Safe ZIP extraction accepted more entries than its entry-count budget.'
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
if ($null -ne $Provenance.predicate.runDetails.metadata.startedOn -or
    $null -ne $Provenance.predicate.runDetails.metadata.finishedOn) {
    throw 'Provenance must not present SOURCE_DATE_EPOCH as truthful workflow execution time.'
}

$SbomOne = Join-Path $TestRoot 'sbom-one.spdx.json'
$SbomTwo = Join-Path $TestRoot 'sbom-two.spdx.json'
$SbomProgram = Join-Path $RepoRoot 'scripts\release\New-Sbom.ps1'
$SyntheticReviewedLicenses = Join-Path $TestRoot 'reviewed-rust-licenses.csv'
@(
    'name,version,detected_license,source',
    '"example","1.2.3","MIT","registry+https://github.com/rust-lang/crates.io-index"'
) | Set-Content -LiteralPath $SyntheticReviewedLicenses -Encoding utf8NoBOM
$ReleaseMetadata = Get-Content -LiteralPath (Join-Path $RepoRoot 'third-party\ffmpeg-artifact.json') -Raw | ConvertFrom-Json
$ToolchainLicenses = Join-Path $TestRoot 'toolchain-licenses'
New-Item -ItemType Directory -Path $ToolchainLicenses | Out-Null
foreach ($License in @($ReleaseMetadata.toolchain.licenses)) {
    Set-Content -LiteralPath (Join-Path $ToolchainLicenses $License.output_name) `
        -Value "Synthetic test copy of $($License.component) terms." -Encoding utf8NoBOM
}
& $SbomProgram -RepositoryRoot $RepoRoot -Version '0.1.1' `
    -Commit '0123456789abcdef0123456789abcdef01234567' -SourceDateEpoch $Epoch `
    -PackageManifestPath $ManifestPath `
    -RustDependencyInventoryPath (Join-Path $SyntheticRustLicenses 'RUST-DEPENDENCIES.json') `
    -ReviewedLicenseInventoryPath $SyntheticReviewedLicenses `
    -ToolchainLicenseDirectory $ToolchainLicenses -OutputPath $SbomOne
& $SbomProgram -RepositoryRoot $RepoRoot -Version '0.1.1' `
    -Commit '0123456789abcdef0123456789abcdef01234567' -SourceDateEpoch $Epoch `
    -PackageManifestPath $ManifestPath `
    -RustDependencyInventoryPath (Join-Path $SyntheticRustLicenses 'RUST-DEPENDENCIES.json') `
    -ReviewedLicenseInventoryPath $SyntheticReviewedLicenses `
    -ToolchainLicenseDirectory $ToolchainLicenses -OutputPath $SbomTwo
if ((Get-FileHash $SbomOne).Hash -cne (Get-FileHash $SbomTwo).Hash) {
    throw 'SPDX generation is not deterministic.'
}
$Sbom = Get-Content -LiteralPath $SbomOne -Raw | ConvertFrom-Json
if ($Sbom.spdxVersion -cne 'SPDX-2.3' -or $Sbom.packages.Count -lt 2 -or $Sbom.files.Count -ne 3) {
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
if (@($Sbom.packages | Where-Object name -eq 'dev-only').Count -ne 0) {
    throw 'SPDX SBOM included a dev-only package outside the Windows release graph.'
}

$SyntheticBuild = Join-Path $TestRoot 'synthetic-ffmpeg'
$SyntheticAudit = Join-Path $TestRoot 'synthetic-audit'
$SyntheticPlayerEvidence = Join-Path $TestRoot 'synthetic-player-evidence'
$SyntheticPlayer = Join-Path $TestRoot 'terminal-video-player.exe'
New-Item -ItemType Directory -Path (Join-Path $SyntheticBuild 'bin'), `
    (Join-Path $SyntheticBuild 'licenses\ffmpeg'), `
    (Join-Path $SyntheticBuild 'licenses\toolchain'), `
    (Join-Path $SyntheticBuild 'provenance'), $SyntheticAudit, $SyntheticPlayerEvidence -Force | Out-Null
Set-Content -LiteralPath $SyntheticPlayer -Value 'synthetic player' -Encoding ascii
Set-Content -LiteralPath (Join-Path $SyntheticBuild 'bin\ffmpeg.exe') -Value 'synthetic ffmpeg' -Encoding ascii
Set-Content -LiteralPath (Join-Path $SyntheticBuild 'bin\ffprobe.exe') -Value 'synthetic ffprobe' -Encoding ascii
Set-Content -LiteralPath (Join-Path $SyntheticBuild 'licenses\ffmpeg\LICENSE.md') -Value 'FFmpeg LGPL notice' -Encoding ascii
Set-Content -LiteralPath (Join-Path $SyntheticBuild 'licenses\ffmpeg\COPYING.LGPLv2.1') -Value 'LGPL 2.1 terms' -Encoding ascii
foreach ($License in @($ReleaseMetadata.toolchain.licenses)) {
    Set-Content -LiteralPath (Join-Path $SyntheticBuild "licenses\toolchain\$($License.output_name)") `
        -Value "Verified $($License.component) terms" -Encoding utf8NoBOM
}
foreach ($Name in @('BINARY-STRINGS-SCAN.txt', 'CONFIGURE-COMMAND.txt', 'TOOLCHAIN.txt')) {
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
Set-Content -LiteralPath (Join-Path $SyntheticPlayerEvidence 'PLAYER-BINARY-STRINGS-SCAN.txt') -Value 'no forbidden paths' -Encoding ascii
Set-Content -LiteralPath (Join-Path $SyntheticPlayerEvidence 'PLAYER-PE-IMPORTS.json') -Value '[]' -Encoding ascii
Set-Content -LiteralPath (Join-Path $SyntheticPlayerEvidence 'RUST-TOOLCHAIN.txt') -Value 'rustc 1.97.1' -Encoding ascii
Set-Content -LiteralPath (Join-Path $SyntheticPlayerEvidence 'WINDOWS-RUNNER.json') -Value '{}' -Encoding ascii

$PackageOne = Join-Path $TestRoot 'package-one'
$PackageTwo = Join-Path $TestRoot 'package-two'
$PackageProgram = Join-Path $RepoRoot 'scripts\release\New-PortablePackage.ps1'
foreach ($Output in @($PackageOne, $PackageTwo)) {
    & $PackageProgram -RepositoryRoot $RepoRoot -Version '0.1.1' -SourceDateEpoch $Epoch `
        -PlayerExecutable $SyntheticPlayer -PlayerEvidenceDirectory $SyntheticPlayerEvidence `
        -RustLicenseDirectory $SyntheticRustLicenses `
        -FfmpegBuildRoot $SyntheticBuild `
        -AuditDirectory $SyntheticAudit -ProvenancePath $ProvenanceOne -OutputDirectory $Output
}
$PortableOne = Join-Path $PackageOne 'terminal-video-player-v0.1.1-portable-windows-x86_64.zip'
$PortableTwo = Join-Path $PackageTwo 'terminal-video-player-v0.1.1-portable-windows-x86_64.zip'
if ((Get-FileHash $PortableOne).Hash -cne (Get-FileHash $PortableTwo).Hash) {
    throw 'Complete portable package creation is not deterministic.'
}
$PortableLicenseCheck = Join-Path $TestRoot 'portable-license-check'
Expand-SafeZip -ArchivePath $PortableOne -DestinationDirectory $PortableLicenseCheck
foreach ($ExpectedLicense in @(
    'licenses\Rust\RUST-DEPENDENCIES.json',
    'licenses\Rust\example-1.2.3\LICENSE-MIT',
    'licenses\Rust\example-1.2.3\NOTICE'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $PortableLicenseCheck $ExpectedLicense) -PathType Leaf)) {
        throw "Portable package omitted a Rust dependency license file: $ExpectedLicense"
    }
}
foreach ($Output in @($PackageOne, $PackageTwo)) {
    if (Test-Path -LiteralPath (Join-Path $Output 'portable-stage')) {
        throw 'Portable package staging directory was retained as a candidate release artifact.'
    }
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
$SourceInspection = [IO.Compression.ZipFile]::OpenRead($SourceZipOne)
try {
    foreach ($Executable in @('scripts/release/build-ffmpeg.sh', 'scripts/release/Validate-TarArchive.sh')) {
        $Entry = $SourceInspection.GetEntry($Executable)
        if ($null -eq $Entry -or (($Entry.ExternalAttributes -shr 16) -band 511) -ne 493) {
            throw "Corresponding-source ZIP lost the executable mode for $Executable."
        }
    }
} finally {
    $SourceInspection.Dispose()
}
$SourceExtraction = Join-Path $TestRoot 'source clean extraction'
Expand-SafeZip -ArchivePath $SourceZipOne -DestinationDirectory $SourceExtraction
foreach ($RequiredRebuildInput in @(
    'scripts\release\build-ffmpeg.sh',
    'scripts\release\Validate-TarArchive.sh',
    'third-party\ffmpeg-artifact.json',
    'third-party\ffmpeg-components.json',
    'upstream\ffmpeg-9.0.1.tar.xz'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceExtraction $RequiredRebuildInput) -PathType Leaf)) {
        throw "Clean corresponding-source extraction is missing rebuild input: $RequiredRebuildInput"
    }
}
foreach ($Output in @($SourceOne, $SourceTwo)) {
    if (Test-Path -LiteralPath (Join-Path $Output 'corresponding-source-stage')) {
        throw 'Corresponding-source staging directory was retained as a candidate release artifact.'
    }
}

Write-Host 'Deterministic packaging and extraction validation passed.'
