[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$RepositoryRoot,
    [Parameter(Mandatory)] [ValidatePattern('^\d+\.\d+\.\d+$')] [string]$Version,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{40}$')] [string]$Commit,
    [Parameter(Mandatory)] [long]$SourceDateEpoch,
    [Parameter(Mandatory)] [string[]]$SubjectPaths,
    [Parameter(Mandatory)] [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$MetadataPath = Join-Path $RepositoryRoot 'third-party\ffmpeg-artifact.json'
$Metadata = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json

$Subjects = @($SubjectPaths | Sort-Object -CaseSensitive | ForEach-Object {
    $Resolved = [IO.Path]::GetFullPath($_)
    if (-not (Test-Path -LiteralPath $Resolved -PathType Leaf)) { throw "Provenance subject is missing: $Resolved" }
    [ordered]@{
        name = Split-Path $Resolved -Leaf
        digest = [ordered]@{ sha256 = (Get-FileHash -LiteralPath $Resolved -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
})

$Materials = @(
    [ordered]@{
        uri = $Metadata.ffmpeg.source_archive.url
        digest = [ordered]@{ sha256 = $Metadata.ffmpeg.source_archive.sha256 }
    },
    [ordered]@{
        uri = $Metadata.toolchain.artifact.url
        digest = [ordered]@{ sha256 = $Metadata.toolchain.artifact.sha256 }
    },
    [ordered]@{
        uri = "git+https://github.com/HHP8/terminal-video-player@$Commit"
        digest = [ordered]@{ gitCommit = $Commit }
    }
)

$Statement = [ordered]@{
    _type = 'https://in-toto.io/Statement/v1'
    subject = $Subjects
    predicateType = 'https://slsa.dev/provenance/v1'
    predicate = [ordered]@{
        buildDefinition = [ordered]@{
            buildType = 'https://github.com/HHP8/terminal-video-player/source-built-ffmpeg-portable/v1'
            externalParameters = [ordered]@{
                version = $Version
                ffmpegVersion = $Metadata.ffmpeg.version
                ffmpegConfiguration = @($Metadata.build.configuration_flags)
                componentAllowlist = 'third-party/ffmpeg-components.json'
            }
            internalParameters = [ordered]@{
                sourceDateEpoch = $SourceDateEpoch
                reproducibilityReplicaCount = 2
            }
            resolvedDependencies = $Materials
        }
        runDetails = [ordered]@{
            builder = [ordered]@{ id = 'https://github.com/actions/runner' }
            metadata = [ordered]@{
                invocationId = "https://github.com/HHP8/terminal-video-player/actions/runs/$($env:GITHUB_RUN_ID ?? 'local')"
            }
        }
    }
}

$Parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
New-Item -ItemType Directory -Path $Parent -Force | Out-Null
$Statement | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Host "Provenance record created: $OutputPath"
