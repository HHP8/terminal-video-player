[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$Still = Join-Path $OutputDirectory 'validation-still.png'
$Animation = Join-Path $OutputDirectory 'validation-animation.gif'
[IO.File]::WriteAllBytes($Still, [Convert]::FromBase64String(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNgYGD4DwABBAEAgLvRWwAAAABJRU5ErkJggg=='))
[IO.File]::WriteAllBytes($Animation, [Convert]::FromBase64String(
    'R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=='))
