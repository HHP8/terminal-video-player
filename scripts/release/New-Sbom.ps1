[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$RepositoryRoot,
    [Parameter(Mandatory)] [ValidatePattern('^\d+\.\d+\.\d+$')] [string]$Version,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{40}$')] [string]$Commit,
    [Parameter(Mandatory)] [long]$SourceDateEpoch,
    [Parameter(Mandatory)] [string]$PackageManifestPath,
    [Parameter(Mandatory)] [string]$RustDependencyInventoryPath,
    [string]$ReviewedLicenseInventoryPath,
    [Parameter(Mandatory)] [string]$ToolchainLicenseDirectory,
    [Parameter(Mandatory)] [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$Metadata = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'third-party\ffmpeg-artifact.json') -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($ReviewedLicenseInventoryPath)) {
    $ReviewedLicenseInventoryPath = Join-Path $RepositoryRoot 'third-party\rust-dependencies.csv'
}
$InventoryRows = @(Import-Csv -LiteralPath $ReviewedLicenseInventoryPath)
$Inventory = @{}
foreach ($Row in $InventoryRows) {
    $Key = "$($Row.name)`0$($Row.version)"
    if ($Inventory.ContainsKey($Key)) { throw "Duplicate Rust dependency inventory entry: $($Row.name) $($Row.version)" }
    if ([string]::IsNullOrWhiteSpace($Row.detected_license) -or $Row.detected_license -match '(?i)unknown|unlicensed|proprietary') {
        throw "Blocked Rust dependency license: $($Row.name) $($Row.version)"
    }
    $Inventory[$Key] = $Row
}

$ReleaseInventory = Get-Content -LiteralPath $RustDependencyInventoryPath -Raw | ConvertFrom-Json
if ($ReleaseInventory.target -cne 'x86_64-pc-windows-msvc' -or
    (@($ReleaseInventory.dependencyEdges) -join ',') -cne 'normal,build') {
    throw 'Rust dependency inventory is not the reviewed Windows normal/build release graph.'
}
$Packages = [Collections.Generic.List[object]]::new()
$Relationships = [Collections.Generic.List[object]]::new()
$ExtractedLicenses = [Collections.Generic.List[object]]::new()
$AppId = 'SPDXRef-Package-terminal-video-player'
$Packages.Add([ordered]@{
    name = 'terminal-video-player'
    SPDXID = $AppId
    versionInfo = $Version
    downloadLocation = 'https://github.com/HHP8/terminal-video-player'
    filesAnalyzed = $false
    licenseConcluded = 'MIT'
    licenseDeclared = 'MIT'
    copyrightText = 'NOASSERTION'
})
$Relationships.Add([ordered]@{
    spdxElementId = 'SPDXRef-DOCUMENT'
    relationshipType = 'DESCRIBES'
    relatedSpdxElement = $AppId
})

foreach ($ReleasePackage in @($ReleaseInventory.packages)) {
    $Name = [string]$ReleasePackage.name
    $PackageVersion = [string]$ReleasePackage.version
    $Key = "$Name`0$PackageVersion"
    if (-not $Inventory.ContainsKey($Key)) { throw "Rust dependency license inventory is missing $Name $PackageVersion." }
    $License = ([string]$Inventory[$Key].detected_license).Replace('/', ' OR ')
    $SpdxId = 'SPDXRef-Package-' + (($Name + '-' + $PackageVersion) -replace '[^A-Za-z0-9.-]', '-')
    $Package = [ordered]@{
        name = $Name
        SPDXID = $SpdxId
        versionInfo = $PackageVersion
        downloadLocation = [string]$ReleasePackage.source
        filesAnalyzed = $false
        licenseConcluded = $License
        licenseDeclared = $License
        copyrightText = 'NOASSERTION'
        externalRefs = @([ordered]@{
            referenceCategory = 'PACKAGE-MANAGER'
            referenceType = 'purl'
            referenceLocator = "pkg:cargo/$Name@$PackageVersion"
        })
    }
    $Packages.Add($Package)
    $Relationships.Add([ordered]@{
        spdxElementId = $AppId
        relationshipType = 'DEPENDS_ON'
        relatedSpdxElement = $SpdxId
    })
}

$FfmpegId = 'SPDXRef-Package-FFmpeg'
$Packages.Add([ordered]@{
    name = 'FFmpeg'
    SPDXID = $FfmpegId
    versionInfo = $Metadata.ffmpeg.version
    downloadLocation = $Metadata.ffmpeg.source_archive.url
    filesAnalyzed = $false
    checksums = @([ordered]@{ algorithm = 'SHA256'; checksumValue = $Metadata.ffmpeg.source_archive.sha256 })
    licenseConcluded = $Metadata.ffmpeg.expected_license
    licenseDeclared = $Metadata.ffmpeg.expected_license
    copyrightText = 'NOASSERTION'
})
$Relationships.Add([ordered]@{ spdxElementId = $AppId; relationshipType = 'DEPENDS_ON'; relatedSpdxElement = $FfmpegId })

foreach ($ToolLicense in @($Metadata.toolchain.licenses)) {
    $Id = 'SPDXRef-Package-' + (($ToolLicense.component) -replace '[^A-Za-z0-9.-]', '-')
    $Packages.Add([ordered]@{
        name = $ToolLicense.component
        SPDXID = $Id
        versionInfo = $Metadata.toolchain.release
        downloadLocation = $ToolLicense.source
        filesAnalyzed = $false
        licenseConcluded = $ToolLicense.spdx
        licenseDeclared = $ToolLicense.spdx
        copyrightText = 'NOASSERTION'
    })
    if ([string]$ToolLicense.spdx -like 'LicenseRef-*') {
        $LicensePath = Join-Path $ToolchainLicenseDirectory ([string]$ToolLicense.output_name)
        if (-not (Test-Path -LiteralPath $LicensePath -PathType Leaf)) {
            throw "Custom toolchain license text is missing: $LicensePath"
        }
        $LicenseText = Get-Content -LiteralPath $LicensePath -Raw
        if ([string]::IsNullOrWhiteSpace($LicenseText)) { throw "Custom toolchain license text is empty: $LicensePath" }
        $ExtractedLicenses.Add([ordered]@{
            licenseId = [string]$ToolLicense.spdx
            extractedText = $LicenseText
            name = [string]$ToolLicense.component
            comment = 'Verified license text copied from the pinned llvm-mingw artifact.'
        })
    }
    $Relationships.Add([ordered]@{ spdxElementId = $Id; relationshipType = 'BUILD_DEPENDENCY_OF'; relatedSpdxElement = $FfmpegId })
}

$Manifest = Get-Content -LiteralPath $PackageManifestPath -Raw | ConvertFrom-Json
$Files = @($Manifest.files | ForEach-Object {
    $FileId = 'SPDXRef-File-' + (($_.path) -replace '[^A-Za-z0-9.-]', '-')
    $Relationships.Add([ordered]@{ spdxElementId = $AppId; relationshipType = 'CONTAINS'; relatedSpdxElement = $FileId })
    [ordered]@{
        fileName = './' + $_.path
        SPDXID = $FileId
        checksums = @([ordered]@{ algorithm = 'SHA256'; checksumValue = $_.sha256 })
        licenseConcluded = 'NOASSERTION'
        copyrightText = 'NOASSERTION'
    }
})

$Created = [DateTimeOffset]::FromUnixTimeSeconds($SourceDateEpoch).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
$Document = [ordered]@{
    spdxVersion = 'SPDX-2.3'
    dataLicense = 'CC0-1.0'
    SPDXID = 'SPDXRef-DOCUMENT'
    name = "terminal-video-player-v$Version-portable"
    documentNamespace = "https://github.com/HHP8/terminal-video-player/releases/tag/v$Version#spdx-$Commit"
    creationInfo = [ordered]@{
        created = $Created
        creators = @('Tool: Terminal Video Player release pipeline')
    }
    packages = @($Packages | Sort-Object SPDXID)
    files = @($Files | Sort-Object SPDXID)
    relationships = @($Relationships | Sort-Object spdxElementId, relationshipType, relatedSpdxElement)
}
if ($ExtractedLicenses.Count -ne 0) {
    $Document['hasExtractedLicensingInfos'] = @($ExtractedLicenses | Sort-Object licenseId)
}

New-Item -ItemType Directory -Path (Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))) -Force | Out-Null
$Document | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Host "SPDX 2.3 SBOM created: $OutputPath"
