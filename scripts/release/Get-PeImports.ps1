[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ExecutablePath,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [string[]]$AllowedImports
)

$ErrorActionPreference = 'Stop'

function Read-UInt16 {
    param([byte[]]$Bytes, [int]$Offset)
    if ($Offset -lt 0 -or $Offset + 2 -gt $Bytes.Length) { throw 'Invalid PE offset.' }
    return [BitConverter]::ToUInt16($Bytes, $Offset)
}

function Read-UInt32 {
    param([byte[]]$Bytes, [int]$Offset)
    if ($Offset -lt 0 -or $Offset + 4 -gt $Bytes.Length) { throw 'Invalid PE offset.' }
    return [BitConverter]::ToUInt32($Bytes, $Offset)
}

function Convert-RvaToOffset {
    param(
        [uint32]$Rva,
        [object[]]$Sections,
        [int]$FileLength
    )
    foreach ($Section in $Sections) {
        $Span = [Math]::Max([uint64]$Section.VirtualSize, [uint64]$Section.RawSize)
        if ([uint64]$Rva -ge [uint64]$Section.VirtualAddress -and
            [uint64]$Rva -lt ([uint64]$Section.VirtualAddress + $Span)) {
            $Offset = [uint64]$Section.RawPointer + ([uint64]$Rva - [uint64]$Section.VirtualAddress)
            if ($Offset -ge [uint64]$FileLength) { throw 'PE RVA resolves outside the file.' }
            return [int]$Offset
        }
    }
    if ($Rva -lt $FileLength) { return [int]$Rva }
    throw ('PE RVA 0x{0:X8} does not map to a section.' -f $Rva)
}

function Read-AsciiZ {
    param([byte[]]$Bytes, [int]$Offset)
    $End = $Offset
    while ($End -lt $Bytes.Length -and $Bytes[$End] -ne 0) { $End++ }
    if ($End -ge $Bytes.Length) { throw 'Unterminated PE import name.' }
    return [Text.Encoding]::ASCII.GetString($Bytes, $Offset, $End - $Offset)
}

$ResolvedExecutable = (Resolve-Path -LiteralPath $ExecutablePath).Path
$Bytes = [IO.File]::ReadAllBytes($ResolvedExecutable)
if ($Bytes.Length -lt 0x40 -or $Bytes[0] -ne 0x4d -or $Bytes[1] -ne 0x5a) {
    throw "Not a valid PE executable: $ResolvedExecutable"
}

$PeOffset = [int](Read-UInt32 $Bytes 0x3c)
if ($PeOffset + 24 -gt $Bytes.Length -or
    $Bytes[$PeOffset] -ne 0x50 -or $Bytes[$PeOffset + 1] -ne 0x45 -or
    $Bytes[$PeOffset + 2] -ne 0 -or $Bytes[$PeOffset + 3] -ne 0) {
    throw "Invalid PE signature: $ResolvedExecutable"
}

$SectionCount = [int](Read-UInt16 $Bytes ($PeOffset + 6))
$OptionalSize = [int](Read-UInt16 $Bytes ($PeOffset + 20))
$OptionalOffset = $PeOffset + 24
$Magic = Read-UInt16 $Bytes $OptionalOffset
$DirectoryOffset = switch ($Magic) {
    0x10b { $OptionalOffset + 96 }
    0x20b { $OptionalOffset + 112 }
    default { throw ('Unsupported PE optional-header magic: 0x{0:X4}' -f $Magic) }
}
if ($DirectoryOffset + 16 -gt $OptionalOffset + $OptionalSize) {
    throw 'PE optional header does not contain an import directory.'
}

$Sections = @()
$SectionOffset = $OptionalOffset + $OptionalSize
for ($Index = 0; $Index -lt $SectionCount; $Index++) {
    $Current = $SectionOffset + ($Index * 40)
    if ($Current + 40 -gt $Bytes.Length) { throw 'Truncated PE section table.' }
    $Sections += [pscustomobject]@{
        VirtualSize = Read-UInt32 $Bytes ($Current + 8)
        VirtualAddress = Read-UInt32 $Bytes ($Current + 12)
        RawSize = Read-UInt32 $Bytes ($Current + 16)
        RawPointer = Read-UInt32 $Bytes ($Current + 20)
    }
}

$ImportRva = Read-UInt32 $Bytes ($DirectoryOffset + 8)
$Imports = @()
if ($ImportRva -ne 0) {
    $DescriptorOffset = Convert-RvaToOffset $ImportRva $Sections $Bytes.Length
    while ($true) {
        if ($DescriptorOffset + 20 -gt $Bytes.Length) { throw 'Truncated PE import descriptor.' }
        $OriginalThunk = Read-UInt32 $Bytes $DescriptorOffset
        $TimeStamp = Read-UInt32 $Bytes ($DescriptorOffset + 4)
        $ForwarderChain = Read-UInt32 $Bytes ($DescriptorOffset + 8)
        $NameRva = Read-UInt32 $Bytes ($DescriptorOffset + 12)
        $FirstThunk = Read-UInt32 $Bytes ($DescriptorOffset + 16)
        if (($OriginalThunk -bor $TimeStamp -bor $ForwarderChain -bor $NameRva -bor $FirstThunk) -eq 0) { break }
        if ($NameRva -eq 0) { throw 'PE import descriptor has no DLL name.' }
        $NameOffset = Convert-RvaToOffset $NameRva $Sections $Bytes.Length
        $Name = Read-AsciiZ $Bytes $NameOffset
        if ($Name -notmatch '^[A-Za-z0-9._+-]+\.dll$') { throw "Unexpected PE import name: $Name" }
        $Imports += $Name
        $DescriptorOffset += 20
    }
}

$Imports = @($Imports | Sort-Object -Unique)
if ($AllowedImports) {
    $Unexpected = @($Imports | Where-Object { $_ -notin $AllowedImports })
    if ($Unexpected.Count -ne 0) {
        throw "Unexpected PE imports in $ResolvedExecutable`: $($Unexpected -join ', ')"
    }
}

$OutputDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
($Imports | ConvertTo-Json -Depth 2) + "`n" | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Host "Recorded $($Imports.Count) PE imports from $ResolvedExecutable."
