[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ReplicaA,
    [Parameter(Mandatory)] [string]$ReplicaB,
    [Parameter(Mandatory)] [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleaseTools.psm1') -Force

$ReplicaA = [IO.Path]::GetFullPath($ReplicaA).TrimEnd('\', '/')
$ReplicaB = [IO.Path]::GetFullPath($ReplicaB).TrimEnd('\', '/')
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\', '/')
foreach ($Root in @($ReplicaA, $ReplicaB)) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Replica directory is missing: $Root"
    }
}
foreach ($Replica in @($ReplicaA, $ReplicaB)) {
    if ($OutputDirectory.StartsWith($Replica + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Verified output must not be inside a replica directory.'
    }
}

$First = @(Get-TreeManifest -Root $ReplicaA)
$Second = @(Get-TreeManifest -Root $ReplicaB)
if (($First | ConvertTo-Json -Depth 4) -cne ($Second | ConvertTo-Json -Depth 4)) {
    throw 'Replica directories have unexplained filename, size, or SHA-256 differences.'
}

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
foreach ($File in $First) {
    $Destination = Join-Path $OutputDirectory $File.path.Replace('/', '\')
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $ReplicaA $File.path.Replace('/', '\')) -Destination $Destination
}

Write-Host "Two isolated directory replicas are bit-for-bit identical across $($First.Count) files."
