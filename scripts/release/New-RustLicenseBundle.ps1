[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$MetadataPath,
    [Parameter(Mandatory)] [string]$ReleasePackageListPath,
    [Parameter(Mandatory)] [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleaseTools.psm1') -Force
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$FallbackMetadataPath = Join-Path $RepoRoot 'third-party\rust-license-fallbacks.json'
$FallbackMetadata = Get-Content -LiteralPath $FallbackMetadataPath -Raw | ConvertFrom-Json
if ($FallbackMetadata.schema -ne 1) { throw 'Unsupported Rust license fallback metadata schema.' }
$Metadata = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
$ReleasePackageListPath = [IO.Path]::GetFullPath($ReleasePackageListPath)
if (-not (Test-Path -LiteralPath $ReleasePackageListPath -PathType Leaf)) {
    throw "Rust release package list is missing: $ReleasePackageListPath"
}
$ReleaseKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($Line in Get-Content -LiteralPath $ReleasePackageListPath) {
    if ([string]::IsNullOrWhiteSpace($Line)) { continue }
    if ($Line -cnotmatch '^(?<name>[^ ]+) v(?<version>[^ ]+)(?: .*)?$') {
        throw "Malformed cargo tree package line: $Line"
    }
    [void]$ReleaseKeys.Add("$($Matches.name)`0$($Matches.version)")
}
if ($ReleaseKeys.Count -eq 0) { throw 'Rust release package list is empty.' }

$MetadataPackages = @($Metadata.packages | Where-Object { $null -ne $_.source })
foreach ($Key in $ReleaseKeys) {
    $Matches = @($MetadataPackages | Where-Object { "$($_.name)`0$($_.version)" -ceq $Key })
    if ($Matches.Count -gt 1) { throw "Rust release graph package is ambiguous: $($Key.Replace("`0", ' '))" }
    if ($Matches.Count -eq 0 -and -not $Key.StartsWith('terminal-video-player' + "`0", [StringComparison]::Ordinal)) {
        throw "Rust release graph package is absent from cargo metadata: $($Key.Replace("`0", ' '))"
    }
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null

$Inventory = foreach ($Package in @($MetadataPackages | Where-Object {
    $ReleaseKeys.Contains("$($_.name)`0$($_.version)")
} | Sort-Object name, version)) {
    $PackageRoot = Split-Path -Parent ([string]$Package.manifest_path)
    $PackageId = "$($Package.name)-$($Package.version)"
    Assert-SafeRelativePath $PackageId
    $DestinationRoot = Join-Path $OutputDirectory $PackageId
    New-Item -ItemType Directory -Path $DestinationRoot | Out-Null
    $LicenseMaterialSource = 'crate-package'
    $VcsRevision = $null

    $Candidates = [Collections.Generic.List[IO.FileInfo]]::new()
    if ($null -ne $Package.license_file -and -not [string]::IsNullOrWhiteSpace([string]$Package.license_file)) {
        $Declared = [string]$Package.license_file
        if (-not [IO.Path]::IsPathRooted($Declared)) { $Declared = Join-Path $PackageRoot $Declared }
        $Candidates.Add((Get-Item -LiteralPath $Declared))
    }
    foreach ($File in Get-ChildItem -LiteralPath $PackageRoot -File) {
        if ($File.Name -match '^(?i:LICENSE|COPYING|NOTICE|UNLICENSE)(?:$|[._-].*)') {
            $Candidates.Add($File)
        }
    }
    $Candidates = @($Candidates | Sort-Object FullName -Unique)
    if ($Candidates.Count -eq 0) {
        $Fallbacks = @($FallbackMetadata.packages | Where-Object {
            $_.name -ceq [string]$Package.name -and
            $_.version -ceq [string]$Package.version -and
            $_.source -ceq [string]$Package.source -and
            $_.license_expression -ceq [string]$Package.license
        })
        if ($Fallbacks.Count -ne 1) {
            throw "Dependency has no discoverable license or uniquely pinned fallback notice: $PackageId"
        }
        $Fallback = $Fallbacks[0]
        $VcsInfoPath = Join-Path $PackageRoot '.cargo_vcs_info.json'
        if (-not (Test-Path -LiteralPath $VcsInfoPath -PathType Leaf)) {
            throw "Fallback dependency is missing Cargo VCS provenance: $PackageId"
        }
        $VcsInfo = Get-Content -LiteralPath $VcsInfoPath -Raw | ConvertFrom-Json
        $VcsRevision = [string]$VcsInfo.git.sha1
        if ($VcsRevision -cne [string]$Fallback.vcs_revision) {
            throw "Fallback dependency VCS revision mismatch: $PackageId"
        }
        foreach ($FallbackFile in @($Fallback.files)) {
            Assert-SafeRelativePath ([string]$FallbackFile.path)
            $FallbackPath = Join-Path $RepoRoot ([string]$FallbackFile.path)
            if (-not (Test-Path -LiteralPath $FallbackPath -PathType Leaf)) {
                throw "Pinned fallback license file is missing: $($FallbackFile.path)"
            }
            $ActualHash = (Get-FileHash -LiteralPath $FallbackPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($ActualHash -cne [string]$FallbackFile.sha256) {
                throw "Pinned fallback license hash mismatch: $($FallbackFile.path)"
            }
            $Candidates += Get-Item -LiteralPath $FallbackPath
        }
        $Candidates = @($Candidates | Sort-Object FullName -Unique)
        if ($Candidates.Count -eq 0) { throw "Pinned fallback license set is empty: $PackageId" }
        $LicenseMaterialSource = 'pinned-upstream-fallback'
    }

    $Files = foreach ($File in $Candidates) {
        if (($File.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Dependency license input is a reparse point: $($File.FullName)"
        }
        Assert-SafeRelativePath $File.Name
        $Destination = Join-Path $DestinationRoot $File.Name
        if (Test-Path -LiteralPath $Destination) {
            throw "Dependency license bundle contains a duplicate filename: $PackageId/$($File.Name)"
        }
        Copy-Item -LiteralPath $File.FullName -Destination $Destination
        [ordered]@{
            path = "$PackageId/$($File.Name)"
            size = [int64]$File.Length
            sha256 = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    [ordered]@{
        name = [string]$Package.name
        version = [string]$Package.version
        source = [string]$Package.source
        licenseExpression = [string]$Package.license
        licenseMaterialSource = $LicenseMaterialSource
        vcsRevision = $VcsRevision
        files = @($Files)
    }
}

if (@($Inventory).Count -eq 0) { throw 'Cargo metadata contains no third-party dependency packages.' }
[ordered]@{
    schema = 1
    target = 'x86_64-pc-windows-msvc'
    dependencyEdges = @('normal', 'build')
    packages = @($Inventory)
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'RUST-DEPENDENCIES.json') -Encoding utf8NoBOM

Write-Host "Rust dependency license bundle created for $(@($Inventory).Count) packages."
