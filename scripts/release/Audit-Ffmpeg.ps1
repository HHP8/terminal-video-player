[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$BuildRoot,
    [Parameter(Mandatory)] [string]$MetadataPath,
    [Parameter(Mandatory)] [string]$ComponentsPath,
    [Parameter(Mandatory)] [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$Metadata = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
$Components = Get-Content -LiteralPath $ComponentsPath -Raw | ConvertFrom-Json
$Ffmpeg = Join-Path $BuildRoot 'bin\ffmpeg.exe'
$Ffprobe = Join-Path $BuildRoot 'bin\ffprobe.exe'
$ConfigComponents = Join-Path $BuildRoot 'provenance\config_components.h'
$PeImportsPath = Join-Path $BuildRoot 'provenance\PE-IMPORTS.json'
$StringsEvidence = Join-Path $BuildRoot 'provenance\BINARY-STRINGS-SCAN.txt'

foreach ($Path in @($Ffmpeg, $Ffprobe, $ConfigComponents, $PeImportsPath, $StringsEvidence)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required FFmpeg audit input is missing: $Path"
    }
}
if ((Get-ChildItem -LiteralPath (Join-Path $BuildRoot 'bin') -File -Filter '*.dll').Count -ne 0) {
    throw 'The FFmpeg build output unexpectedly contains DLL files.'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$SumsPath = Join-Path $BuildRoot 'SHA256SUMS'
foreach ($Line in Get-Content -LiteralPath $SumsPath) {
    if ($Line -cnotmatch '^(?<hash>[0-9a-f]{64})  \./(?<path>.+)$') { throw "Malformed FFmpeg build checksum line: $Line" }
    $Path = Join-Path $BuildRoot $Matches.path.Replace('/', '\')
    $Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Hash -cne $Matches.hash) { throw "FFmpeg build artifact hash mismatch: $($Matches.path)" }
}

function Invoke-Captured {
    param([string]$Executable, [string[]]$Arguments, [string]$Label)
    $Text = (& $Executable @Arguments 2>&1 | Out-String).TrimEnd()
    if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit code $LASTEXITCODE." }
    return $Text
}

$Version = Invoke-Captured $Ffmpeg @('-hide_banner', '-version') 'ffmpeg -version'
$ProbeVersion = Invoke-Captured $Ffprobe @('-hide_banner', '-version') 'ffprobe -version'
$BuildConf = Invoke-Captured $Ffmpeg @('-hide_banner', '-buildconf') 'ffmpeg -buildconf'
$License = Invoke-Captured $Ffmpeg @('-hide_banner', '-L') 'ffmpeg -L'
$Protocols = Invoke-Captured $Ffmpeg @('-hide_banner', '-protocols') 'ffmpeg -protocols'
$Formats = Invoke-Captured $Ffmpeg @('-hide_banner', '-formats') 'ffmpeg -formats'
$Decoders = Invoke-Captured $Ffmpeg @('-hide_banner', '-decoders') 'ffmpeg -decoders'
$Encoders = Invoke-Captured $Ffmpeg @('-hide_banner', '-encoders') 'ffmpeg -encoders'
$Filters = Invoke-Captured $Ffmpeg @('-hide_banner', '-filters') 'ffmpeg -filters'
$Devices = Invoke-Captured $Ffmpeg @('-hide_banner', '-devices') 'ffmpeg -devices'

if (-not $Version.Contains("ffmpeg version $($Metadata.ffmpeg.version)", [StringComparison]::Ordinal)) {
    throw 'ffmpeg.exe does not report the pinned FFmpeg version.'
}
if (-not $ProbeVersion.Contains("ffprobe version $($Metadata.ffmpeg.version)", [StringComparison]::Ordinal)) {
    throw 'ffprobe.exe does not report the pinned FFmpeg version.'
}
$MandatoryRejectedFlags = @('--enable-gpl', '--enable-nonfree', '--enable-version3')
foreach ($MandatoryFlag in $MandatoryRejectedFlags) {
    if ($MandatoryFlag -notin @($Metadata.ffmpeg.rejected_flags)) {
        throw "Mandatory rejected FFmpeg flag is absent from metadata: $MandatoryFlag"
    }
}
foreach ($Rejected in @($Metadata.ffmpeg.rejected_flags) + @($Metadata.ffmpeg.rejected_configuration_terms)) {
    if ($BuildConf.Contains([string]$Rejected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "FFmpeg build configuration contains rejected term: $Rejected"
    }
}
foreach ($Required in @($Metadata.build.configuration_flags)) {
    if (-not $BuildConf.Contains([string]$Required, [StringComparison]::Ordinal)) {
        throw "FFmpeg build configuration is missing required flag: $Required"
    }
}
if ($License -notmatch 'GNU Lesser General Public\s+License') {
    throw 'FFmpeg license output does not identify the GNU Lesser General Public License.'
}

$Kinds = [ordered]@{
    PROTOCOL = 'protocols'
    DEMUXER = 'demuxers'
    DECODER = 'decoders'
    PARSER = 'parsers'
    ENCODER = 'encoders'
    MUXER = 'muxers'
    FILTER = 'filters'
    INDEV = 'indevs'
}
$Inventory = [ordered]@{}
$ConfigLines = Get-Content -LiteralPath $ConfigComponents
foreach ($Entry in $Kinds.GetEnumerator()) {
    $Suffix = $Entry.Key
    $Property = $Entry.Value
    $Actual = @(
        $ConfigLines | ForEach-Object {
            if ($_ -match "^#define CONFIG_(?<name>[A-Z0-9_]+)_${Suffix} 1$") {
                $Matches.name.ToLowerInvariant()
            }
        } | Sort-Object -CaseSensitive -Unique
    )
    $Expected = @($Components.$Property | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive -Unique)
    if (($Actual -join "`n") -cne ($Expected -join "`n")) {
        throw "Enabled FFmpeg $Property differ from the reviewed allowlist. Expected [$($Expected -join ', ')], found [$($Actual -join ', ')]."
    }
    $Inventory[$Property] = $Actual
}

$PeInventory = Get-Content -LiteralPath $PeImportsPath -Raw | ConvertFrom-Json -AsHashtable
foreach ($ExecutableName in @('ffmpeg.exe', 'ffprobe.exe')) {
    $Imports = @($PeInventory[$ExecutableName] | Sort-Object -Unique)
    foreach ($Import in $Imports) {
        if ($Import -notin @($Components.allowed_pe_imports)) {
            throw "Unexpected PE import in ${ExecutableName}: $Import"
        }
    }
}

Set-Content -LiteralPath (Join-Path $OutputDirectory 'FFMPEG-VERSION.txt') -Value $Version -Encoding utf8NoBOM
Set-Content -LiteralPath (Join-Path $OutputDirectory 'FFPROBE-VERSION.txt') -Value $ProbeVersion -Encoding utf8NoBOM
Set-Content -LiteralPath (Join-Path $OutputDirectory 'FFMPEG-BUILDCONF.txt') -Value $BuildConf -Encoding utf8NoBOM
Set-Content -LiteralPath (Join-Path $OutputDirectory 'FFMPEG-LICENSE.txt') -Value $License -Encoding utf8NoBOM
Set-Content -LiteralPath (Join-Path $OutputDirectory 'FFMPEG-PROTOCOLS.txt') -Value $Protocols -Encoding utf8NoBOM
Set-Content -LiteralPath (Join-Path $OutputDirectory 'FFMPEG-FORMATS.txt') -Value $Formats -Encoding utf8NoBOM
Set-Content -LiteralPath (Join-Path $OutputDirectory 'FFMPEG-DECODERS.txt') -Value $Decoders -Encoding utf8NoBOM
Set-Content -LiteralPath (Join-Path $OutputDirectory 'FFMPEG-ENCODERS.txt') -Value $Encoders -Encoding utf8NoBOM
Set-Content -LiteralPath (Join-Path $OutputDirectory 'FFMPEG-FILTERS.txt') -Value $Filters -Encoding utf8NoBOM
Set-Content -LiteralPath (Join-Path $OutputDirectory 'FFMPEG-DEVICES.txt') -Value $Devices -Encoding utf8NoBOM
$Inventory | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'FFMPEG-COMPONENTS.json') -Encoding utf8NoBOM
$PeInventory | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'FFMPEG-PE-IMPORTS.json') -Encoding utf8NoBOM

Write-Host 'FFmpeg license, component, path, and PE dependency audit passed.'
