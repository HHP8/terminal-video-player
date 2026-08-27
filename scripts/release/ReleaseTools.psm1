Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

function Assert-SafeRelativePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        [IO.Path]::IsPathRooted($Path) -or
        $Path.Contains('\') -or
        $Path.Contains(':') -or
        $Path.Contains([char]0) -or
        $Path.StartsWith('/', [StringComparison]::Ordinal)) {
        throw "Unsafe archive path: $Path"
    }
    $Segments = $Path.Split('/')
    if (@($Segments | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0) {
        throw "Unsafe archive path segment: $Path"
    }
}

function Get-TreeManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Root,
        [string[]]$Exclude = @()
    )

    $ResolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $ResolvedRoot -PathType Container)) {
        throw "Manifest root is missing: $ResolvedRoot"
    }
    $Excluded = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($Value in $Exclude) { [void]$Excluded.Add($Value) }

    $Entries = foreach ($File in Get-ChildItem -LiteralPath $ResolvedRoot -Recurse -File) {
        if (($File.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Manifest input contains a reparse point: $($File.FullName)"
        }
        $Relative = [IO.Path]::GetRelativePath($ResolvedRoot, $File.FullName).Replace('\', '/')
        Assert-SafeRelativePath $Relative
        if ($Excluded.Contains($Relative)) { continue }
        [ordered]@{
            path = $Relative
            size = [int64]$File.Length
            sha256 = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return @($Entries | Sort-Object { $_.path })
}

function Set-ZipUnixOrigin {
    param([Parameter(Mandatory)] [string]$ArchivePath)

    $Bytes = [IO.File]::ReadAllBytes($ArchivePath)
    $EndOffset = -1
    for ($Index = $Bytes.Length - 22; $Index -ge [Math]::Max(0, $Bytes.Length - 65557); $Index--) {
        if ([BitConverter]::ToUInt32($Bytes, $Index) -eq 0x06054b50) {
            $EndOffset = $Index
            break
        }
    }
    if ($EndOffset -lt 0) { throw 'Deterministic ZIP has no end-of-central-directory record.' }
    $EntryCount = [BitConverter]::ToUInt16($Bytes, $EndOffset + 10)
    $CentralSize = [BitConverter]::ToUInt32($Bytes, $EndOffset + 12)
    $CentralOffset = [BitConverter]::ToUInt32($Bytes, $EndOffset + 16)
    $Cursor = [int64]$CentralOffset
    for ($EntryIndex = 0; $EntryIndex -lt $EntryCount; $EntryIndex++) {
        if ($Cursor + 46 -gt $Bytes.Length -or
            [BitConverter]::ToUInt32($Bytes, [int]$Cursor) -ne 0x02014b50) {
            throw 'Deterministic ZIP central directory is malformed.'
        }
        $Bytes[[int]$Cursor + 5] = 3
        $NameLength = [BitConverter]::ToUInt16($Bytes, [int]$Cursor + 28)
        $ExtraLength = [BitConverter]::ToUInt16($Bytes, [int]$Cursor + 30)
        $CommentLength = [BitConverter]::ToUInt16($Bytes, [int]$Cursor + 32)
        $Cursor += 46 + $NameLength + $ExtraLength + $CommentLength
    }
    if ($Cursor -ne [int64]$CentralOffset + $CentralSize) {
        throw 'Deterministic ZIP central-directory size is inconsistent.'
    }
    [IO.File]::WriteAllBytes($ArchivePath, $Bytes)
}

function New-DeterministicZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceDirectory,
        [Parameter(Mandatory)] [string]$DestinationPath,
        [string[]]$ExecutablePaths = @()
    )

    $SourceDirectory = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\', '/')
    $DestinationPath = [IO.Path]::GetFullPath($DestinationPath)
    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
        throw "ZIP source directory is missing: $SourceDirectory"
    }
    if ($DestinationPath.StartsWith($SourceDirectory + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ZIP destination must not be inside its source directory.'
    }
    $DestinationParent = Split-Path -Parent $DestinationPath
    New-Item -ItemType Directory -Path $DestinationParent -Force | Out-Null
    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force
    }
    $ExecutableSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($ExecutablePath in $ExecutablePaths) {
        Assert-SafeRelativePath $ExecutablePath
        if (-not $ExecutableSet.Add($ExecutablePath)) {
            throw "Duplicate executable ZIP path: $ExecutablePath"
        }
    }

    $Files = @(Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File | Sort-Object {
        [IO.Path]::GetRelativePath($SourceDirectory, $_.FullName).Replace('\', '/')
    })
    $Stream = [IO.File]::Open($DestinationPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $Archive = [IO.Compression.ZipArchive]::new($Stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($File in $Files) {
                if (($File.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "ZIP source contains a reparse point: $($File.FullName)"
                }
                $Relative = [IO.Path]::GetRelativePath($SourceDirectory, $File.FullName).Replace('\', '/')
                Assert-SafeRelativePath $Relative
                $Entry = $Archive.CreateEntry($Relative, [IO.Compression.CompressionLevel]::Optimal)
                $Entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $UnixPermissions = if ($ExecutableSet.Contains($Relative)) { 493 } else { 420 }
                $UnixMode = [uint32](0x8000 -bor $UnixPermissions)
                $ModeBits = [uint32]($UnixMode -shl 16)
                $Entry.ExternalAttributes = [BitConverter]::ToInt32([BitConverter]::GetBytes($ModeBits), 0)
                $Input = [IO.File]::OpenRead($File.FullName)
                $Output = $Entry.Open()
                try { $Input.CopyTo($Output) } finally { $Output.Dispose(); $Input.Dispose() }
            }
            foreach ($ExecutablePath in $ExecutableSet) {
                if ($ExecutablePath -notin @($Files | ForEach-Object {
                    [IO.Path]::GetRelativePath($SourceDirectory, $_.FullName).Replace('\', '/')
                })) {
                    throw "Executable ZIP path is not a payload file: $ExecutablePath"
                }
            }
        } finally {
            $Archive.Dispose()
        }
    } finally {
        $Stream.Dispose()
    }
    Set-ZipUnixOrigin -ArchivePath $DestinationPath
}

function Expand-SafeZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ArchivePath,
        [Parameter(Mandatory)] [string]$DestinationDirectory,
        [ValidateRange(1, 4096)] [int]$MaxEntries = 2048,
        [ValidateRange(1, [long]::MaxValue)] [long]$MaxEntryBytes = 536870912,
        [ValidateRange(1, [long]::MaxValue)] [long]$MaxTotalBytes = 805306368,
        [ValidateRange(1, 10000)] [double]$MaxCompressionRatio = 1000
    )

    $ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
    $DestinationDirectory = [IO.Path]::GetFullPath($DestinationDirectory)
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "ZIP archive is missing: $ArchivePath"
    }
    if (Test-Path -LiteralPath $DestinationDirectory) {
        throw "ZIP destination already exists: $DestinationDirectory"
    }
    New-Item -ItemType Directory -Path $DestinationDirectory | Out-Null
    $DestinationPrefix = $DestinationDirectory.TrimEnd('\') + '\'
    $Names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        $Archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
        try {
            if ($Archive.Entries.Count -gt $MaxEntries) {
                throw "ZIP exceeds the $MaxEntries-entry entry-count limit."
            }
            [long]$TotalBytes = 0
            foreach ($Entry in $Archive.Entries) {
                $Name = $Entry.FullName
                if ($Name.EndsWith('/', [StringComparison]::Ordinal)) { continue }
                if ($Entry.Length -gt $MaxEntryBytes) {
                    throw "ZIP entry exceeds the $MaxEntryBytes-byte uncompressed size limit: $Name"
                }
                if ($TotalBytes -gt $MaxTotalBytes - $Entry.Length) {
                    throw "ZIP exceeds the $MaxTotalBytes-byte aggregate uncompressed size limit."
                }
                $TotalBytes += $Entry.Length
                if ($Entry.Length -gt 0) {
                    if ($Entry.CompressedLength -eq 0 -or
                        ($Entry.Length / [double]$Entry.CompressedLength) -gt $MaxCompressionRatio) {
                        throw "ZIP entry exceeds the $MaxCompressionRatio compression-ratio limit: $Name"
                    }
                }
                Assert-SafeRelativePath $Name
                if (-not $Names.Add($Name)) { throw "ZIP contains a duplicate path: $Name" }
                $UnixMode = ($Entry.ExternalAttributes -shr 16) -band 0xF000
                if ($UnixMode -eq 0xA000) { throw "ZIP contains a symbolic link: $Name" }
                $Destination = [IO.Path]::GetFullPath((Join-Path $DestinationDirectory $Name.Replace('/', '\')))
                if (-not $Destination.StartsWith($DestinationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "ZIP entry escapes the destination: $Name"
                }
            }
            foreach ($Entry in $Archive.Entries) {
                if ($Entry.FullName.EndsWith('/', [StringComparison]::Ordinal)) { continue }
                $Destination = [IO.Path]::GetFullPath((Join-Path $DestinationDirectory $Entry.FullName.Replace('/', '\')))
                New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
                $Input = $Entry.Open()
                $Output = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $Input.CopyTo($Output) } finally { $Output.Dispose(); $Input.Dispose() }
            }
        } finally {
            $Archive.Dispose()
        }
    } catch {
        if (Test-Path -LiteralPath $DestinationDirectory) {
            Remove-Item -LiteralPath $DestinationDirectory -Recurse -Force
        }
        throw
    }
}

Export-ModuleMember -Function Assert-SafeRelativePath, Get-TreeManifest, New-DeterministicZip, Expand-SafeZip
