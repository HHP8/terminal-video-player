[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$MetadataPath,
    [Parameter(Mandatory)] [string]$ReleasePackageListPath,
    [Parameter(Mandatory)] [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleaseTools.psm1') -Force
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
        throw "Dependency has no discoverable license or notice file: $PackageId"
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
