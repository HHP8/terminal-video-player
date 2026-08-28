[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$Program = Join-Path $RepoRoot 'scripts\release\Compare-ReleaseReplicas.ps1'
$DirectoryProgram = Join-Path $RepoRoot 'scripts\release\Compare-DirectoryReplicas.ps1'
foreach ($RequiredProgram in @($Program, $DirectoryProgram)) {
    if (-not (Test-Path -LiteralPath $RequiredProgram -PathType Leaf)) {
        throw "Replica comparator is missing: $RequiredProgram"
    }
}
$Metadata = Get-Content -LiteralPath (Join-Path $RepoRoot 'third-party\ffmpeg-artifact.json') -Raw | ConvertFrom-Json
$Root = Join-Path (Join-Path $RepoRoot '.cache\release-tests') ([Guid]::NewGuid().ToString('N'))
$A = Join-Path $Root 'a'
$B = Join-Path $Root 'b'
$Verified = Join-Path $Root 'verified'
New-Item -ItemType Directory -Path $A, $B | Out-Null
$GeneratedSuffixes = @($Metadata.package.generated_asset_suffixes)
$ReplicaSuffixes = @($Metadata.package.published_asset_suffixes | Where-Object { $_ -notin $GeneratedSuffixes })
foreach ($Suffix in $ReplicaSuffixes) {
    $Name = "terminal-video-player-v0.1.1$Suffix"
    if ($Suffix -ceq '-manifest.json') {
        [ordered]@{
            schema = 1
            files = @(
                [ordered]@{ path = 'terminal-video-player.exe'; size = 1; sha256 = ('1'.PadLeft(64, '1')) },
                [ordered]@{ path = 'tools/ffmpeg/ffmpeg.exe'; size = 1; sha256 = ('2'.PadLeft(64, '2')) },
                [ordered]@{ path = 'tools/ffmpeg/ffprobe.exe'; size = 1; sha256 = ('3'.PadLeft(64, '3')) }
            )
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $A $Name) -Encoding utf8NoBOM
    } else {
        Set-Content -LiteralPath (Join-Path $A $Name) -Value "synthetic $Suffix" -Encoding utf8NoBOM
    }
    Copy-Item -LiteralPath (Join-Path $A $Name) -Destination (Join-Path $B $Name)
}
$RunnerA = Join-Path $Root 'runner-a.json'
$RunnerB = Join-Path $Root 'runner-b.json'
[ordered]@{ image_os = 'win25-vs2026'; image_version = '1'; image_release = ''; runner_arch = 'X64'; runner_os = 'Windows' } |
    ConvertTo-Json | Set-Content -LiteralPath $RunnerA -Encoding utf8NoBOM
[ordered]@{ image_os = 'win25-vs2026'; image_version = '2'; image_release = ''; runner_arch = 'X64'; runner_os = 'Windows' } |
    ConvertTo-Json | Set-Content -LiteralPath $RunnerB -Encoding utf8NoBOM

& $Program -MetadataPath (Join-Path $RepoRoot 'third-party\ffmpeg-artifact.json') `
    -Version '0.1.1' -ReplicaA $A -ReplicaB $B -RunnerMetadataA $RunnerA `
    -RunnerMetadataB $RunnerB -OutputDirectory $Verified
if (@(Get-ChildItem -LiteralPath $Verified -File).Count -ne $Metadata.package.published_asset_suffixes.Count) {
    throw 'Replica comparator did not emit the exact verified asset inventory.'
}
$Report = Get-Content -LiteralPath (Join-Path $Verified 'terminal-video-player-v0.1.1-reproducibility.json') -Raw | ConvertFrom-Json
if ($Report.result -cne 'bit-for-bit-identical' -or $Report.comparedAssetCount -ne $ReplicaSuffixes.Count -or
    $Report.hostedRunner.replicaA.image_version -cne '1' -or $Report.hostedRunner.replicaB.image_version -cne '2') {
    throw 'Replica comparator did not preserve exact hosted-runner provenance separately.'
}

$Changed = Join-Path $B "terminal-video-player-v0.1.1$($ReplicaSuffixes[0])"
Add-Content -LiteralPath $Changed -Value 'difference'
$Rejected = $false
try {
    & $Program -MetadataPath (Join-Path $RepoRoot 'third-party\ffmpeg-artifact.json') `
        -Version '0.1.1' -ReplicaA $A -ReplicaB $B -RunnerMetadataA $RunnerA `
        -RunnerMetadataB $RunnerB -OutputDirectory (Join-Path $Root 'rejected')
} catch {
    $Rejected = $true
}
if (-not $Rejected) { throw 'Replica comparator accepted unexplained differing output.' }

$TreeA = Join-Path $Root 'tree-a'
$TreeB = Join-Path $Root 'tree-b'
$VerifiedTree = Join-Path $Root 'verified-tree'
New-Item -ItemType Directory -Path (Join-Path $TreeA 'bin'), (Join-Path $TreeB 'bin') | Out-Null
Set-Content -LiteralPath (Join-Path $TreeA 'bin\ffmpeg.exe') -Value 'identical binary' -Encoding ascii
Copy-Item -LiteralPath (Join-Path $TreeA 'bin\ffmpeg.exe') -Destination (Join-Path $TreeB 'bin\ffmpeg.exe')
& $DirectoryProgram -ReplicaA $TreeA -ReplicaB $TreeB -OutputDirectory $VerifiedTree
if ((Get-Content -LiteralPath (Join-Path $VerifiedTree 'bin\ffmpeg.exe') -Raw).TrimEnd() -cne 'identical binary') {
    throw 'Directory comparator did not preserve the verified relative tree.'
}

Add-Content -LiteralPath (Join-Path $TreeB 'bin\ffmpeg.exe') -Value 'difference'
$Rejected = $false
try {
    & $DirectoryProgram -ReplicaA $TreeA -ReplicaB $TreeB `
        -OutputDirectory (Join-Path $Root 'rejected-tree')
} catch {
    $Rejected = $true
}
if (-not $Rejected) { throw 'Directory comparator accepted differing file content.' }

Write-Host 'Release reproducibility comparison validation passed.'
