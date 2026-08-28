[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$MetadataPath,
    [Parameter(Mandatory)] [ValidatePattern('^\d+\.\d+\.\d+$')] [string]$Version,
    [Parameter(Mandatory)] [string]$ReplicaA,
    [Parameter(Mandatory)] [string]$ReplicaB,
    [Parameter(Mandatory)] [string]$RunnerMetadataA,
    [Parameter(Mandatory)] [string]$RunnerMetadataB,
    [Parameter(Mandatory)] [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$Metadata = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
$GeneratedSuffixes = @($Metadata.package.generated_asset_suffixes)
if (($GeneratedSuffixes -join "`n") -cne '-reproducibility.json') {
    throw 'Unexpected generated release-asset policy.'
}
$Expected = @($Metadata.package.published_asset_suffixes | Where-Object {
    $_ -notin $GeneratedSuffixes
} | ForEach-Object {
    "terminal-video-player-v$Version$([string]$_)"
} | Sort-Object -CaseSensitive)

function Get-AssetInventory {
    param([string]$Root, [string]$Label)
    $Resolved = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $Resolved -PathType Container)) { throw "$Label directory is missing: $Resolved" }
    $Directories = @(Get-ChildItem -LiteralPath $Resolved -Directory -Recurse)
    if ($Directories.Count -ne 0) { throw "$Label contains unexpected directories." }
    $Files = @(Get-ChildItem -LiteralPath $Resolved -File | Sort-Object Name -CaseSensitive)
    $Names = @($Files.Name)
    if (($Names -join "`n") -cne ($Expected -join "`n")) {
        throw "$Label asset inventory differs from the reviewed allowlist."
    }
    return @($Files | ForEach-Object {
        [pscustomobject]@{
            name = $_.Name
            size = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            path = $_.FullName
        }
    })
}

$First = @(Get-AssetInventory $ReplicaA 'Replica A')
$Second = @(Get-AssetInventory $ReplicaB 'Replica B')
for ($Index = 0; $Index -lt $First.Count; $Index++) {
    if ($First[$Index].name -cne $Second[$Index].name -or
        $First[$Index].size -ne $Second[$Index].size -or
        $First[$Index].sha256 -cne $Second[$Index].sha256) {
        throw "Unexplained reproducibility difference: $($First[$Index].name)"
    }
}

$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) { Remove-Item -LiteralPath $OutputDirectory -Recurse -Force }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
foreach ($Asset in $First) {
    Copy-Item -LiteralPath $Asset.path -Destination (Join-Path $OutputDirectory $Asset.name)
}

function Read-RunnerMetadata {
    param([string]$Path, [string]$Label)
    $Resolved = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $Resolved -PathType Leaf)) { throw "$Label is missing: $Resolved" }
    $Runner = Get-Content -LiteralPath $Resolved -Raw | ConvertFrom-Json
    $ExpectedProperties = @('image_os', 'image_release', 'image_version', 'runner_arch', 'runner_os')
    $ActualProperties = @($Runner.PSObject.Properties.Name | Sort-Object -CaseSensitive)
    if (($ActualProperties -join "`n") -cne (($ExpectedProperties | Sort-Object -CaseSensitive) -join "`n")) {
        throw "$Label has an unexpected schema."
    }
    foreach ($Required in @('image_os', 'image_version', 'runner_arch', 'runner_os')) {
        if ([string]::IsNullOrWhiteSpace([string]$Runner.$Required)) { throw "$Label is missing $Required." }
    }
    return $Runner
}

$RunnerA = Read-RunnerMetadata $RunnerMetadataA 'Runner metadata A'
$RunnerB = Read-RunnerMetadata $RunnerMetadataB 'Runner metadata B'
foreach ($StableProperty in @('image_os', 'runner_arch', 'runner_os')) {
    if ([string]$RunnerA.$StableProperty -cne [string]$RunnerB.$StableProperty) {
        throw "Isolated builds used incompatible runner metadata: $StableProperty"
    }
}

$ManifestName = "terminal-video-player-v$Version-manifest.json"
$Manifest = Get-Content -LiteralPath (Join-Path $ReplicaA $ManifestName) -Raw | ConvertFrom-Json
$BinaryHashes = [ordered]@{}
foreach ($Path in @('terminal-video-player.exe', 'tools/ffmpeg/ffmpeg.exe', 'tools/ffmpeg/ffprobe.exe')) {
    $Matches = @($Manifest.files | Where-Object { $_.path -ceq $Path })
    if ($Matches.Count -ne 1 -or [string]$Matches[0].sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Replica manifest is missing a unique binary hash: $Path"
    }
    $BinaryHashes[$Path] = [string]$Matches[0].sha256
}

$ReportName = "terminal-video-player-v$Version-reproducibility.json"
[ordered]@{
    schema = 1
    version = $Version
    result = 'bit-for-bit-identical'
    comparedAssetCount = $First.Count
    comparedAssets = @($First | ForEach-Object {
        [ordered]@{ name = $_.name; size = $_.size; sha256 = $_.sha256 }
    })
    binarySha256 = $BinaryHashes
    hostedRunner = [ordered]@{
        requestedImage = 'windows-2025'
        exactImagePinningAvailable = $false
        replicaA = $RunnerA
        replicaB = $RunnerB
        note = 'Exact resolved image metadata is recorded separately because GitHub-hosted runner labels are mutable; it is not embedded in the reproducible portable payload.'
    }
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory $ReportName) -Encoding utf8NoBOM

$PublishedNames = @(Get-ChildItem -LiteralPath $OutputDirectory -File | Sort-Object Name -CaseSensitive | Select-Object -ExpandProperty Name)
$ExpectedPublished = @($Metadata.package.published_asset_suffixes | ForEach-Object {
    "terminal-video-player-v$Version$([string]$_)"
} | Sort-Object -CaseSensitive)
if (($PublishedNames -join "`n") -cne ($ExpectedPublished -join "`n")) {
    throw 'Verified release output differs from the reviewed publication inventory.'
}

Write-Host "Two isolated release replicas are bit-for-bit identical across $($First.Count) build assets; exact hosted-runner resolutions were recorded separately."
