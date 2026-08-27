[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$MetadataPath,
    [Parameter(Mandatory)] [ValidatePattern('^\d+\.\d+\.\d+$')] [string]$Version,
    [Parameter(Mandatory)] [string]$ReplicaA,
    [Parameter(Mandatory)] [string]$ReplicaB,
    [Parameter(Mandatory)] [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$Metadata = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
$Expected = @($Metadata.package.published_asset_suffixes | ForEach-Object {
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

Write-Host "Two isolated release replicas are bit-for-bit identical across $($First.Count) assets."
