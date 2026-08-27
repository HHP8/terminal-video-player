[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$Program = Join-Path $RepoRoot 'scripts\release\Get-PeImports.ps1'
if (-not (Test-Path -LiteralPath $Program -PathType Leaf)) {
    throw "PE import inspector is missing: $Program"
}
$Output = Join-Path (Join-Path $RepoRoot '.cache\release-tests') 'system-pe-imports.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $Output) -Force | Out-Null
& $Program -ExecutablePath "$env:SystemRoot\System32\where.exe" -OutputPath $Output
$Imports = @(Get-Content -LiteralPath $Output -Raw | ConvertFrom-Json)
if ($Imports.Count -eq 0 -or @($Imports | Where-Object { $_ -notmatch '(?i)\.dll$' }).Count -ne 0) {
    throw 'PE import inspector did not return a valid DLL inventory.'
}
if ('KERNEL32.dll' -notin $Imports) {
    throw 'PE import inspector did not find the expected KERNEL32.dll import.'
}
Write-Host 'PE import inspection validation passed.'
