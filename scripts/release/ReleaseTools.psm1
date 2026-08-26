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

function New-DeterministicZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceDirectory,
        [Parameter(Mandatory)] [string]$DestinationPath
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
                $Entry.ExternalAttributes = 0
                $Input = [IO.File]::OpenRead($File.FullName)
                $Output = $Entry.Open()
                try { $Input.CopyTo($Output) } finally { $Output.Dispose(); $Input.Dispose() }
            }
        } finally {
            $Archive.Dispose()
        }
    } finally {
        $Stream.Dispose()
    }
}

function Expand-SafeZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ArchivePath,
        [Parameter(Mandatory)] [string]$DestinationDirectory
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
            foreach ($Entry in $Archive.Entries) {
                $Name = $Entry.FullName
                if ($Name.EndsWith('/', [StringComparison]::Ordinal)) { continue }
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
