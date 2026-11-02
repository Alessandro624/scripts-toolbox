#requires -Version 5.1

[CmdletBinding()]

param(
    [ValidateSet("Monthly", "Quarterly", "Full")]
    [string]$Mode = "Monthly",
    [string[]]$ProjectRoots = @(),
    [string]$OutputDirectory = (Join-Path $HOME "Documents\PC-Maintenance"),
    [switch]$ReuseInventory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($env:OS -ne 'Windows_NT') {
    throw 'This audit requires Windows.'
}

# ============================================================
# CONFIGURATION
# ============================================================

$SchemaVersion = 5
$ScriptVersion = "3.3.0"

$BaseDir = $OutputDirectory
$SnapshotDir = Join-Path $BaseDir "snapshots"
$ReportDir = Join-Path $BaseDir "reports"

New-Item -ItemType Directory -Force -Path `
    $BaseDir, $SnapshotDir, $ReportDir | Out-Null

$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss-fffffff"
$StartedAt = Get-Date

$ProjectRoots = @($ProjectRoots | Where-Object {
        Test-Path -LiteralPath $_ -PathType Container
    } | ForEach-Object { (Resolve-Path -LiteralPath $_).Path } | Sort-Object -Unique)

# Heavy artifacts: measure individually.
$IndividualArtifactNames = @(
    ".venv",
    "venv",
    "node_modules"
)

# Small/regenerable caches: aggregate by type.
$AggregatedCacheNames = @(
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache"
)

# Additional build artifacts only in Quarterly / Full.
# These are aggregated by type instead of measured individually.
$QuarterlyAggregatedArtifactNames = @(
    ".tox",
    ".nox",
    ".gradle",
    "target",
    "dist",
    "build"
)

$script:MeasurementWarnings = 0

# ============================================================
# PHYSICAL SIZE API
# ============================================================

if (-not ("DiskUsageNative" -as [type])) {

    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class DiskUsageNative
{
    [DllImport(
        "kernel32.dll",
        CharSet = CharSet.Unicode,
        SetLastError = true
    )]
    static extern uint GetCompressedFileSizeW(
        string lpFileName,
        out uint lpFileSizeHigh
    );

    public static ulong GetAllocatedSize(string path)
    {
        uint high;
        uint low = GetCompressedFileSizeW(path, out high);

        if (low == 0xFFFFFFFF)
        {
            int error = Marshal.GetLastWin32Error();

            if (error != 0)
                throw new System.ComponentModel.Win32Exception(error);
        }

        return ((ulong)high << 32) | low;
    }
}
"@
}

# ============================================================
# HELPERS
# ============================================================

function Convert-ToGB {
    param(
        [UInt64]$Bytes
    )

    [math]::Round($Bytes / 1GB, 3)
}

function Test-CommandAvailable {
    param(
        [string]$Name
    )

    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-CapturedCommand {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Command
    )

    try {
        $global:LASTEXITCODE = 0
        $output = (
            & $Command 2>&1 |
            Out-String
        ).Trim()
        if ($LASTEXITCODE -ne 0) {
            return "ERROR: Native command exited with code ${LASTEXITCODE}: $output"
        }
        $output
    }
    catch {
        "ERROR: $($_.Exception.Message)"
    }
}

function Get-PhysicalFileSize {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File
    )

    try {
        [UInt64][DiskUsageNative]::GetAllocatedSize(
            $File.FullName
        )
    }
    catch {
        $script:MeasurementWarnings++
        Write-Warning "Cannot measure allocated size: $($File.FullName)"
        [UInt64]0
    }
}

function Measure-AuditPhase {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $result = & $ScriptBlock
    }
    finally {
        $sw.Stop()
    }

    [PSCustomObject]@{
        Name    = $Name
        Seconds = [math]::Round(
            $sw.Elapsed.TotalSeconds,
            2
        )
        Result  = $result
    }
}

function Add-PhaseTiming {
    param(
        [Parameter(Mandatory)]
        [object]$Phase,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$List
    )

    $List.Add(
        [PSCustomObject]@{
            Phase   = $Phase.Name
            Seconds = $Phase.Seconds
        }
    )
}

# ============================================================
# DIRECTORY SIZE
# ============================================================

function Get-AuditFiles {
    param([Parameter(Mandatory)][string]$Path)

    # Explicit traversal avoids junctions, symlinks and cloud placeholders.
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        try {
            $root = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($root.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)
        }
        catch {
            $script:MeasurementWarnings++
            Write-Warning "Cannot enumerate directory: $current"
            continue
        }
        foreach ($child in $children) {
            if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($child.PSIsContainer) { $stack.Push($child.FullName) }
            else { $child }
        }
    }
}

function Get-DirectorySize {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (
            Test-Path -LiteralPath $Path -PathType Container
        )) {
        return $null
    }

    [UInt64]$physical = 0
    [UInt64]$logical = 0
    [UInt64]$files = 0

    Get-AuditFiles -Path $Path |
    ForEach-Object {

        $files++
        $logical += [UInt64]$_.Length

        $physical += Get-PhysicalFileSize -File $_
    }

    [PSCustomObject]@{
        Path       = $Path
        PhysicalGB = Convert-ToGB $physical
        LogicalGB  = Convert-ToGB $logical
        Files      = $files
    }
}

# ============================================================
# FAST PROJECT DISCOVERY
#
# Important difference from v3:
# - no Get-ChildItem call for every visited directory
# - .NET directory enumeration
# - pruning before descending into environments/caches
# ============================================================

function Find-ProjectArtifactsFast {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Roots,

        [Parameter(Mandatory)]
        [string[]]$IndividualNames,

        [Parameter(Mandatory)]
        [string[]]$AggregateNames,

        [string[]]$AdditionalAggregateNames = @()
    )

    $individual = [System.Collections.Generic.List[object]]::new()
    $aggregate = [System.Collections.Generic.List[object]]::new()
    $quarterlyAggregate = [System.Collections.Generic.List[object]]::new()

    $individualSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $aggregateSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $additionalAggregateSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($name in $IndividualNames) {
        [void]$individualSet.Add($name)
    }
    foreach ($name in $AggregateNames) {
        [void]$aggregateSet.Add($name)
    }
    foreach ($name in $AdditionalAggregateNames) {
        [void]$additionalAggregateSet.Add($name)
    }

    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push((Resolve-Path -LiteralPath $root).Path)

        while ($stack.Count -gt 0) {
            $current = $stack.Pop()

            try {
                # Eager enumeration: access errors are raised inside this try.
                $children = [System.IO.Directory]::GetDirectories($current)
            }
            catch {
                continue
            }

            foreach ($childPath in $children) {
                try {
                    $attributes = [System.IO.File]::GetAttributes($childPath)
                    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        continue
                    }

                    $name = [System.IO.Path]::GetFileName($childPath)
                    if ([string]::IsNullOrWhiteSpace($name)) {
                        continue
                    }
                    if ($name -eq '.git') { continue }

                    if ($individualSet.Contains($name)) {
                        $individual.Add([PSCustomObject]@{
                                Name = $name
                                Path = $childPath
                            })
                        continue
                    }

                    if ($aggregateSet.Contains($name)) {
                        $aggregate.Add([PSCustomObject]@{
                                Name = $name
                                Path = $childPath
                            })
                        continue
                    }

                    if ($additionalAggregateSet.Contains($name)) {
                        $quarterlyAggregate.Add([PSCustomObject]@{
                                Name = $name
                                Path = $childPath
                            })
                        continue
                    }

                    $stack.Push($childPath)
                }
                catch {
                    continue
                }
            }
        }
    }

    [PSCustomObject]@{
        Individual         = @($individual | Sort-Object Path -Unique)
        Aggregate          = @($aggregate | Sort-Object Path -Unique)
        QuarterlyAggregate = @($quarterlyAggregate | Sort-Object Path -Unique)
    }
}

function Get-ProjectArtifactsFromPreviousSnapshot {
    param(
        [Parameter(Mandatory)]
        [object]$PreviousSnapshot
    )

    $inventoryProperty = $PreviousSnapshot.PSObject.Properties["ProjectInventory"]
    if ($null -eq $inventoryProperty) {
        return $null
    }

    $inventory = $PreviousSnapshot.ProjectInventory
    $individual = [System.Collections.Generic.List[object]]::new()
    $aggregate = [System.Collections.Generic.List[object]]::new()
    $quarterlyAggregate = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @($inventory.Individual)) {
        if ([string]::IsNullOrWhiteSpace([string]$item.Path)) { continue }
        if (Test-Path -LiteralPath $item.Path -PathType Container) {
            $individual.Add([PSCustomObject]@{
                    Name = [string]$item.Name
                    Path = [string]$item.Path
                })
        }
    }

    foreach ($item in @($inventory.Aggregate)) {
        if ([string]::IsNullOrWhiteSpace([string]$item.Path)) { continue }
        if (Test-Path -LiteralPath $item.Path -PathType Container) {
            $aggregate.Add([PSCustomObject]@{
                    Name = [string]$item.Name
                    Path = [string]$item.Path
                })
        }
    }

    $quarterlyProperty = $inventory.PSObject.Properties["QuarterlyAggregate"]
    if ($null -ne $quarterlyProperty) {
        foreach ($item in @($inventory.QuarterlyAggregate)) {
            if ([string]::IsNullOrWhiteSpace([string]$item.Path)) { continue }
            if (Test-Path -LiteralPath $item.Path -PathType Container) {
                $quarterlyAggregate.Add([PSCustomObject]@{
                        Name = [string]$item.Name
                        Path = [string]$item.Path
                    })
            }
        }
    }

    [PSCustomObject]@{
        Individual         = @($individual | Sort-Object Path -Unique)
        Aggregate          = @($aggregate | Sort-Object Path -Unique)
        QuarterlyAggregate = @($quarterlyAggregate | Sort-Object Path -Unique)
    }
}

# ============================================================
# INDIVIDUAL ARTIFACTS
# ============================================================

function Measure-IndividualArtifacts {
    param(
        [object[]]$Artifacts
    )

    $results =
    [System.Collections.Generic.List[object]]::new()

    foreach ($artifact in $Artifacts) {

        $sw =
        [System.Diagnostics.Stopwatch]::StartNew()

        $size =
        Get-DirectorySize -Path $artifact.Path

        $sw.Stop()

        if ($null -eq $size) {
            continue
        }

        $results.Add(
            [PSCustomObject]@{
                Name        = $artifact.Name
                Path        = $artifact.Path
                PhysicalGB  = $size.PhysicalGB
                LogicalGB   = $size.LogicalGB
                Files       = $size.Files
                ScanSeconds = [math]::Round(
                    $sw.Elapsed.TotalSeconds,
                    2
                )
            }
        )
    }

    @(
        $results |
        Sort-Object PhysicalGB -Descending
    )
}

# ============================================================
# AGGREGATED REGENERABLE CACHES
# ============================================================

function Measure-AggregatedDirectories {
    param(
        [object[]]$Directories,
        [string[]]$Names
    )

    $stats = @{}
    foreach ($name in $Names) {
        $stats[$name] = [PSCustomObject]@{
            Count         = [UInt64]0
            Files         = [UInt64]0
            PhysicalBytes = [UInt64]0
            LogicalBytes  = [UInt64]0
        }
    }

    foreach ($directory in $Directories) {
        if (-not $stats.ContainsKey($directory.Name)) { continue }
        $entry = $stats[$directory.Name]
        $entry.Count++

        Get-AuditFiles -Path $directory.Path |
        ForEach-Object {
            $entry.Files++
            $entry.LogicalBytes += [UInt64]$_.Length
            $entry.PhysicalBytes += Get-PhysicalFileSize -File $_
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $Names) {
        $entry = $stats[$name]
        $results.Add([PSCustomObject]@{
                Name        = $name
                Directories = $entry.Count
                Files       = $entry.Files
                PhysicalGB  = Convert-ToGB $entry.PhysicalBytes
                LogicalGB   = Convert-ToGB $entry.LogicalBytes
            })
    }

    @($results | Sort-Object PhysicalGB -Descending)
}

function Measure-AggregatedCaches {
    param([object[]]$CacheDirectories)

    Measure-AggregatedDirectories `
        -Directories $CacheDirectories `
        -Names $AggregatedCacheNames
}

# ============================================================
# PACKAGE MANAGER CACHE PATHS
# ============================================================

function Get-PackageManagerCacheDefinitions {

    $definitions = @()

    if (Test-CommandAvailable "npm") {

        $definitions += @{
            Manager = "npm"
            Command = {
                npm config get cache
            }
        }
    }

    if (Test-CommandAvailable "pnpm") {

        $definitions += @{
            Manager = "pnpm"
            Command = {
                pnpm store path
            }
        }
    }

    if (Test-CommandAvailable "uv") {

        $definitions += @{
            Manager = "uv"
            Command = {
                uv cache dir
            }
        }
    }

    if (Test-CommandAvailable "python") {

        $definitions += @{
            Manager = "pip"
            Command = {
                python -m pip cache dir
            }
        }
    }

    $definitions
}

# ============================================================
# PACKAGE MANAGER CACHES
#
# Monthly:
#   resolve path only
#
# Quarterly / Full:
#   resolve + physical/logical size
# ============================================================

function Get-PackageManagerCaches {
    param(
        [switch]$MeasureSize
    )

    $results =
    [System.Collections.Generic.List[object]]::new()

    $definitions =
    Get-PackageManagerCacheDefinitions

    foreach ($definition in $definitions) {

        $path =
        Invoke-CapturedCommand `
            -Command $definition.Command

        if (
            [string]::IsNullOrWhiteSpace($path) -or
            $path.StartsWith("ERROR")
        ) {
            continue
        }

        $exists =
        Test-Path `
            -LiteralPath $path `
            -PathType Container

        if (-not $exists) {

            $results.Add(
                [PSCustomObject]@{
                    Manager    = $definition.Manager
                    Path       = $path
                    Exists     = $false
                    Measured   = $false
                    PhysicalGB = $null
                    LogicalGB  = $null
                }
            )

            continue
        }

        if (-not $MeasureSize) {

            $results.Add(
                [PSCustomObject]@{
                    Manager    = $definition.Manager
                    Path       = $path
                    Exists     = $true
                    Measured   = $false
                    PhysicalGB = $null
                    LogicalGB  = $null
                }
            )

            continue
        }

        $size =
        Get-DirectorySize -Path $path

        if ($null -eq $size) {
            continue
        }

        $results.Add(
            [PSCustomObject]@{
                Manager    = $definition.Manager
                Path       = $path
                Exists     = $true
                Measured   = $true
                PhysicalGB = $size.PhysicalGB
                LogicalGB  = $size.LogicalGB
            }
        )
    }

    @($results)
}

# ============================================================
# KNOWN VHDX
# ============================================================

function Get-KnownVHDX {

    $results =
    [System.Collections.Generic.List[object]]::new()

    # Docker paths are known.
    $dockerCandidates = @(
        (
            Join-Path $HOME `
                "AppData\Local\Docker\wsl\disk\docker_data.vhdx"
        ),
        (
            Join-Path $HOME `
                "AppData\Local\Docker\wsl\main\ext4.vhdx"
        )
    )

    foreach ($path in $dockerCandidates) {

        if (-not (
                Test-Path -LiteralPath $path -PathType Leaf
            )) {
            continue
        }

        try {
            $file =
            Get-Item `
                -LiteralPath $path `
                -Force `
                -ErrorAction Stop

            $physical =
            Get-PhysicalFileSize $file

            $results.Add(
                [PSCustomObject]@{
                    Path       = $file.FullName
                    PhysicalGB =
                    Convert-ToGB $physical
                    LogicalGB  =
                    Convert-ToGB `
                    ([UInt64]$file.Length)
                }
            )
        }
        catch {}
    }

    # WSL distributions live under Packages.
    # Search only package LocalState directories rather than
    # recursively traversing every file in every package.
    $packagesRoot =
    Join-Path $HOME "AppData\Local\Packages"

    if (
        Test-Path `
            -LiteralPath $packagesRoot `
            -PathType Container
    ) {

        try {
            $packages =
            [System.IO.Directory]::EnumerateDirectories(
                $packagesRoot
            )

            foreach ($package in $packages) {

                $localState =
                Join-Path $package "LocalState"

                if (-not (
                        Test-Path `
                            -LiteralPath $localState `
                            -PathType Container
                    )) {
                    continue
                }

                try {
                    $vhdxFiles =
                    [System.IO.Directory]::EnumerateFiles(
                        $localState,
                        "*.vhdx",
                        [System.IO.SearchOption]::TopDirectoryOnly
                    )

                    foreach ($vhdxPath in $vhdxFiles) {

                        try {
                            $file =
                            Get-Item `
                                -LiteralPath $vhdxPath `
                                -Force `
                                -ErrorAction Stop

                            $physical =
                            Get-PhysicalFileSize $file

                            $results.Add(
                                [PSCustomObject]@{
                                    Path       = $file.FullName

                                    PhysicalGB =
                                    Convert-ToGB $physical

                                    LogicalGB  =
                                    Convert-ToGB `
                                    ([UInt64]$file.Length)
                                }
                            )
                        }
                        catch {}
                    }
                }
                catch {}
            }
        }
        catch {}
    }

    @(
        $results |
        Sort-Object PhysicalGB -Descending
    )
}

# ============================================================
# PREVIOUS COMPATIBLE SNAPSHOT
# ============================================================

function Get-PreviousCompatibleSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$Mode
    )

    $files = @(
        Get-ChildItem `
            -LiteralPath $SnapshotDir `
            -Filter "*-$Mode.json" `
            -File `
            -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    )

    foreach ($file in $files) {

        try {
            $candidate =
            Get-Content `
                -LiteralPath $file.FullName `
                -Raw |
            ConvertFrom-Json

            $schemaProperty =
            $candidate.PSObject.Properties["SchemaVersion"]

            if ($null -eq $schemaProperty) {
                continue
            }

            if (
                [int]$candidate.SchemaVersion -eq
                $SchemaVersion -and
                [string]$candidate.Mode -eq $Mode -and
                [string]$candidate.ComputerName -eq $env:COMPUTERNAME -and
                (@($candidate.ProjectRoots | Sort-Object) -join "`n") -eq
                (@($ProjectRoots | Sort-Object) -join "`n")
            ) {
                return [PSCustomObject]@{
                    File     = $file.FullName
                    Snapshot = $candidate
                }
            }
        }
        catch {}
    }

    $null
}

# ============================================================
# STATUS
# ============================================================

function Get-GrowthStatus {
    param(
        [double]$DeltaGB,
        [double]$CurrentGB
    )

    if ($DeltaGB -ge 10) {
        return "WARNING"
    }

    if ($DeltaGB -ge 3) {
        return "CHECK"
    }

    if (
        $CurrentGB -ge 10 -and
        $DeltaGB -ge 1
    ) {
        return "CHECK"
    }

    "OK"
}

function Get-FreeSpaceStatus {
    param(
        [double]$FreePercent
    )

    if ($FreePercent -lt 10) {
        return "WARNING"
    }

    if ($FreePercent -lt 20) {
        return "CHECK"
    }

    "OK"
}

# ============================================================
# START
# ============================================================

Write-Host ""
Write-Host "PC Maintenance Audit v$ScriptVersion" `
    -ForegroundColor Cyan
Write-Host "Mode: $Mode"
Write-Host "Start: $StartedAt"
Write-Host ""

$phaseTimings =
[System.Collections.Generic.List[object]]::new()

$previousInfo =
Get-PreviousCompatibleSnapshot -Mode $Mode

$previous = if ($null -ne $previousInfo) {
    $previousInfo.Snapshot
}
else {
    $null
}

# ============================================================
# DISK
# ============================================================

Write-Host "Disk..." -ForegroundColor Yellow

$phase = Measure-AuditPhase "Disk" {

    $volume =
    Get-Volume -DriveLetter C

    [PSCustomObject]@{
        SizeGB      = [math]::Round(
            $volume.Size / 1GB,
            2
        )

        UsedGB      = [math]::Round(
            (
                $volume.Size -
                $volume.SizeRemaining
            ) / 1GB,
            2
        )

        FreeGB      = [math]::Round(
            $volume.SizeRemaining / 1GB,
            2
        )

        FreePercent = [math]::Round(
            100 *
            $volume.SizeRemaining /
            $volume.Size,
            2
        )

        Health      =
        $volume.HealthStatus.ToString()

        Operational =
        $volume.OperationalStatus.ToString()
    }
}

$disk = $phase.Result
Add-PhaseTiming -Phase $phase -List $phaseTimings

# ============================================================
# PACKAGE MANAGERS
# ============================================================

Write-Host "Package manager caches..." `
    -ForegroundColor Yellow

$measurePackageCaches =
$Mode -in @("Quarterly", "Full")

$phase =
Measure-AuditPhase "Package manager caches" {

    @(
        Get-PackageManagerCaches `
            -MeasureSize:$measurePackageCaches
    )
}

$packageCaches = @($phase.Result)
Add-PhaseTiming -Phase $phase -List $phaseTimings

# ============================================================
# PROJECT INVENTORY / DISCOVERY
#
# Monthly:
#   discover by default; reuse previous inventory only with -ReuseInventory
#
# Quarterly / Full:
#   always perform complete discovery
#
# First Monthly after upgrading:
#   complete discovery to create inventory baseline
# ============================================================

$additionalAggregateNames = @()

if ($Mode -in @("Quarterly", "Full")) {
    $additionalAggregateNames = $QuarterlyAggregatedArtifactNames
}

$discovery = $null
$inventorySource = $null

# ------------------------------------------------------------
# MONTHLY FAST PATH
# ------------------------------------------------------------

if (
    $ReuseInventory -and $Mode -eq "Monthly" -and
    $null -ne $previous
) {

    $previousInventory =
    Get-ProjectArtifactsFromPreviousSnapshot `
        -PreviousSnapshot $previous

    if ($null -ne $previousInventory) {

        Write-Host "Project inventory from previous snapshot..." `
            -ForegroundColor Yellow

        $phase =
        Measure-AuditPhase "Project inventory reuse" {
            $previousInventory
        }

        $discovery = $phase.Result
        $inventorySource = "PreviousSnapshot"

        Add-PhaseTiming `
            -Phase $phase `
            -List $phaseTimings
    }
}

# ------------------------------------------------------------
# COMPLETE DISCOVERY
#
# Used by:
# - Quarterly
# - Full
# - Monthly without reusable inventory
# ------------------------------------------------------------

if ($null -eq $discovery) {

    Write-Host "Project discovery..." `
        -ForegroundColor Yellow

    $phase =
    Measure-AuditPhase "Project discovery" {

        Find-ProjectArtifactsFast `
            -Roots $ProjectRoots `
            -IndividualNames $IndividualArtifactNames `
            -AggregateNames $AggregatedCacheNames `
            -AdditionalAggregateNames $additionalAggregateNames
    }

    $discovery = $phase.Result
    $inventorySource = "FullDiscovery"

    Add-PhaseTiming `
        -Phase $phase `
        -List $phaseTimings
}

Write-Host (
    "Inventory source: {0}" -f
    $inventorySource
)

Write-Host (
    "Individual artifacts: {0}" -f
    $discovery.Individual.Count
)

Write-Host (
    "Regenerable cache directories: {0}" -f
    $discovery.Aggregate.Count
)

if ($Mode -in @("Quarterly", "Full")) {
    Write-Host (
        "Aggregated build artifact directories: {0}" -f
        $discovery.QuarterlyAggregate.Count
    )
}

# ============================================================
# INDIVIDUAL ARTIFACTS
# ============================================================

Write-Host "Measuring individual artifacts..." `
    -ForegroundColor Yellow

$phase =
Measure-AuditPhase "Individual artifacts" {

    @(
        Measure-IndividualArtifacts `
            -Artifacts $discovery.Individual
    )
}

$projectArtifacts = @($phase.Result)
Add-PhaseTiming -Phase $phase -List $phaseTimings

# ============================================================
# AGGREGATED CACHES
# ============================================================

Write-Host "Aggregating regenerable caches..." `
    -ForegroundColor Yellow

$phase =
Measure-AuditPhase "Aggregated caches" {

    @(
        Measure-AggregatedCaches `
            -CacheDirectories $discovery.Aggregate
    )
}

$aggregatedCaches = @($phase.Result)
Add-PhaseTiming -Phase $phase -List $phaseTimings

# ============================================================
# AGGREGATED BUILD ARTIFACTS (Quarterly / Full)
# ============================================================

$quarterlyAggregatedArtifacts = @()

if ($Mode -in @("Quarterly", "Full")) {
    Write-Host "Aggregating build artifacts..." -ForegroundColor Yellow

    $phase = Measure-AuditPhase "Aggregated build artifacts" {
        @(
            Measure-AggregatedDirectories `
                -Directories $discovery.QuarterlyAggregate `
                -Names $QuarterlyAggregatedArtifactNames
        )
    }

    $quarterlyAggregatedArtifacts = @($phase.Result)
    Add-PhaseTiming -Phase $phase -List $phaseTimings
}

# ============================================================
# MAVEN / GRADLE
# ============================================================

$devCaches = @()

if ($Mode -in @("Quarterly", "Full")) {

    Write-Host "Maven / Gradle..." `
        -ForegroundColor Yellow

    $phase =
    Measure-AuditPhase "Maven / Gradle" {

        $results = @()

        foreach ($definition in @(
                @{
                    Name = "Maven"
                    Path = Join-Path $HOME ".m2"
                },
                @{
                    Name = "Gradle"
                    Path = Join-Path $HOME ".gradle"
                }
            )) {

            $size =
            Get-DirectorySize `
                -Path $definition.Path

            if ($null -eq $size) {
                continue
            }

            $results +=
            [PSCustomObject]@{
                Name       = $definition.Name
                Path       = $definition.Path
                PhysicalGB = $size.PhysicalGB
                LogicalGB  = $size.LogicalGB
            }
        }

        @($results)
    }

    $devCaches = @($phase.Result)
    Add-PhaseTiming -Phase $phase -List $phaseTimings
}

# ============================================================
# DOCKER
# ============================================================

$docker = $null

if (Test-CommandAvailable "docker") {

    Write-Host "Docker..." -ForegroundColor Yellow

    $phase =
    Measure-AuditPhase "Docker" {

        $dockerOutput =
        Invoke-CapturedCommand {
            docker system df
        }

        if (
            [string]::IsNullOrWhiteSpace([string]$dockerOutput) -or
            $dockerOutput -match "(?i)failed to connect|cannot find the file specified|docker daemon is not running|is the docker daemon running"
        ) {
            "Status : Not running"
        }
        elseif ($dockerOutput -match "^ERROR:") {
            "Status : Unavailable`n$dockerOutput"
        }
        else {
            $dockerOutput
        }
    }

    $docker = $phase.Result
    Add-PhaseTiming -Phase $phase -List $phaseTimings
}

# ============================================================
# VHDX
# ============================================================

Write-Host "Known VHDX..." `
    -ForegroundColor Yellow

$phase =
Measure-AuditPhase "VHDX" {
    @(Get-KnownVHDX)
}

$vhdx = @($phase.Result)
Add-PhaseTiming -Phase $phase -List $phaseTimings

# ============================================================
# FULL MODE
# ============================================================

$fullDirectories = @()

if ($Mode -eq "Full") {

    Write-Host "Full directory measurements..." `
        -ForegroundColor Yellow

    $phase =
    Measure-AuditPhase "Full directory measurements" {

        $results = @()

        foreach ($path in @(
                $HOME,
                (Join-Path $HOME "AppData"),
                "C:\Program Files",
                "C:\Program Files (x86)",
                "C:\ProgramData"
            )) {

            $size =
            Get-DirectorySize -Path $path

            if ($null -ne $size) {
                $results += $size
            }
        }

        @($results)
    }

    $fullDirectories = @($phase.Result)
    Add-PhaseTiming -Phase $phase -List $phaseTimings
}

# ============================================================
# DIFFS
# ============================================================

$diskDiff = $null
$artifactDiff = @()
$cacheDiff = @()
$aggregateDiff = @()
$quarterlyAggregateDiff = @()
$fullDirectoryDiff = @()
$vhdxDiff = @()

if ($null -ne $previous) {

    # --------------------------------------------------------
    # Disk
    # --------------------------------------------------------

    $delta =
    [math]::Round(
        $disk.UsedGB -
        [double]$previous.Disk.UsedGB,
        2
    )

    $diskDiff =
    [PSCustomObject]@{
        CurrentUsedGB  = $disk.UsedGB
        PreviousUsedGB =
        [double]$previous.Disk.UsedGB
        DeltaUsedGB    = $delta
        FreePercent    = $disk.FreePercent
        Status         =
        Get-FreeSpaceStatus `
            -FreePercent $disk.FreePercent
    }

    # --------------------------------------------------------
    # Project artifacts
    # --------------------------------------------------------

    foreach ($current in $projectArtifacts) {

        $old = @(
            $previous.ProjectArtifacts |
            Where-Object {
                $_.Path -eq $current.Path
            }
        ) |
        Select-Object -First 1

        $oldSize = if ($null -ne $old) {
            [double]$old.PhysicalGB
        }
        else {
            0.0
        }

        $delta =
        [math]::Round(
            $current.PhysicalGB -
            $oldSize,
            3
        )

        $artifactDiff +=
        [PSCustomObject]@{
            Name       = $current.Name
            Path       = $current.Path
            PreviousGB = $oldSize
            CurrentGB  = $current.PhysicalGB
            DeltaGB    = $delta
            Status     =
            Get-GrowthStatus `
                -DeltaGB $delta `
                -CurrentGB $current.PhysicalGB
        }
    }

    # --------------------------------------------------------
    # Package caches
    #
    # Compare sizes only if the current mode measured them.
    # --------------------------------------------------------

    foreach ($current in $packageCaches) {

        if (-not $current.Measured) {
            continue
        }

        $old = @(
            $previous.PackageCaches |
            Where-Object {
                $_.Manager -eq $current.Manager
            }
        ) |
        Select-Object -First 1

        if ($null -eq $old) {
            $oldSize = 0.0
        }
        elseif (
            $null -eq $old.PhysicalGB
        ) {
            $oldSize = 0.0
        }
        else {
            $oldSize = [double]$old.PhysicalGB
        }

        $delta =
        [math]::Round(
            [double]$current.PhysicalGB -
            $oldSize,
            3
        )

        $cacheDiff +=
        [PSCustomObject]@{
            Manager    = $current.Manager
            PreviousGB = $oldSize
            CurrentGB  =
            [double]$current.PhysicalGB
            DeltaGB    = $delta
            Status     =
            Get-GrowthStatus `
                -DeltaGB $delta `
                -CurrentGB `
            ([double]$current.PhysicalGB)
        }
    }

    # --------------------------------------------------------
    # Aggregated caches
    # --------------------------------------------------------

    foreach ($current in $aggregatedCaches) {

        $old = @(
            $previous.AggregatedCaches |
            Where-Object {
                $_.Name -eq $current.Name
            }
        ) |
        Select-Object -First 1

        $oldSize = if ($null -ne $old) {
            [double]$old.PhysicalGB
        }
        else {
            0.0
        }

        $delta =
        [math]::Round(
            $current.PhysicalGB -
            $oldSize,
            3
        )

        $aggregateDiff +=
        [PSCustomObject]@{
            Name        = $current.Name
            Directories = $current.Directories
            PreviousGB  = $oldSize
            CurrentGB   = $current.PhysicalGB
            DeltaGB     = $delta
            Status      =
            Get-GrowthStatus `
                -DeltaGB $delta `
                -CurrentGB $current.PhysicalGB
        }
    }

    # --------------------------------------------------------
    # Quarterly aggregated build artifacts
    # --------------------------------------------------------

    foreach ($current in $quarterlyAggregatedArtifacts) {
        $old = @(
            $previous.QuarterlyAggregatedArtifacts |
            Where-Object { $_.Name -eq $current.Name }
        ) | Select-Object -First 1

        $oldSize = if ($null -ne $old) { [double]$old.PhysicalGB } else { 0.0 }
        $delta = [math]::Round($current.PhysicalGB - $oldSize, 3)

        $quarterlyAggregateDiff += [PSCustomObject]@{
            Name        = $current.Name
            Directories = $current.Directories
            PreviousGB  = $oldSize
            CurrentGB   = $current.PhysicalGB
            DeltaGB     = $delta
            Status      = Get-GrowthStatus -DeltaGB $delta -CurrentGB $current.PhysicalGB
        }
    }

    # --------------------------------------------------------
    # Full directory measurements
    # --------------------------------------------------------

    if ($Mode -eq "Full") {

        foreach ($current in $fullDirectories) {

            $old = @(
                $previous.FullDirectories |
                Where-Object {
                    $_.Path -eq $current.Path
                }
            ) | Select-Object -First 1

            $oldSize = if ($null -ne $old) {
                [double]$old.PhysicalGB
            }
            else {
                0.0
            }

            $delta =
            [math]::Round(
                [double]$current.PhysicalGB - $oldSize,
                3
            )

            $fullDirectoryDiff +=
            [PSCustomObject]@{
                Path       = $current.Path
                PreviousGB = $oldSize
                CurrentGB  = [double]$current.PhysicalGB
                DeltaGB    = $delta
                Status     =
                Get-GrowthStatus `
                    -DeltaGB $delta `
                    -CurrentGB ([double]$current.PhysicalGB)
            }
        }
    }

    # --------------------------------------------------------
    # VHDX
    # --------------------------------------------------------

    foreach ($current in $vhdx) {

        $old = @(
            $previous.VHDX |
            Where-Object {
                $_.Path -eq $current.Path
            }
        ) |
        Select-Object -First 1

        $oldSize = if ($null -ne $old) {
            [double]$old.PhysicalGB
        }
        else {
            0.0
        }

        $delta =
        [math]::Round(
            $current.PhysicalGB -
            $oldSize,
            3
        )

        $vhdxDiff +=
        [PSCustomObject]@{
            Path       = $current.Path
            PreviousGB = $oldSize
            CurrentGB  = $current.PhysicalGB
            DeltaGB    = $delta
            Status     =
            Get-GrowthStatus `
                -DeltaGB $delta `
                -CurrentGB $current.PhysicalGB
        }
    }
}

# ============================================================
# SNAPSHOT
# ============================================================

$FinishedAt = Get-Date

$DurationSeconds =
[math]::Round(
    ($FinishedAt - $StartedAt).TotalSeconds,
    1
)

$snapshot =
[PSCustomObject]@{
    SchemaVersion                = $SchemaVersion
    ScriptVersion                = $ScriptVersion
    Timestamp                    = $FinishedAt.ToString("o")
    Mode                         = $Mode
    DurationSeconds              = $DurationSeconds
    ComputerName                 = $env:COMPUTERNAME
    InventorySource              = $inventorySource
    MeasurementWarnings          = $script:MeasurementWarnings

    Disk                         = $disk

    ProjectRoots                 = @(
        $ProjectRoots
    )

    PackageCaches                = @(
        $packageCaches
    )

    ProjectArtifacts             = @(
        $projectArtifacts
    )

    ProjectInventory             = [PSCustomObject]@{
        Individual         = @(
            $discovery.Individual
        )

        Aggregate          = @(
            $discovery.Aggregate
        )

        QuarterlyAggregate = @(
            $discovery.QuarterlyAggregate
        )
    }

    AggregatedCaches             = @(
        $aggregatedCaches
    )

    QuarterlyAggregatedArtifacts = @(
        $quarterlyAggregatedArtifacts
    )

    DevCaches                    = @(
        $devCaches
    )

    Docker                       = $docker

    VHDX                         = @(
        $vhdx
    )

    FullDirectories              = @(
        $fullDirectories
    )

    Performance                  = @(
        $phaseTimings
    )

    Diff                         = [PSCustomObject]@{
        Disk                         = $diskDiff

        ProjectArtifacts             = @(
            $artifactDiff
        )

        PackageCaches                = @(
            $cacheDiff
        )

        AggregatedCaches             = @(
            $aggregateDiff
        )

        QuarterlyAggregatedArtifacts = @(
            $quarterlyAggregateDiff
        )

        FullDirectories              = @(
            $fullDirectoryDiff
        )

        VHDX                         = @(
            $vhdxDiff
        )
    }
}

$snapshotPath =
Join-Path `
    $SnapshotDir `
    "$Timestamp-$Mode.json"

$snapshot |
ConvertTo-Json -Depth 12 |
Set-Content `
    -LiteralPath $snapshotPath `
    -Encoding UTF8

# ============================================================
# REPORT
# ============================================================

$reportPath =
Join-Path `
    $ReportDir `
    "$Timestamp-$Mode.txt"

$report =
[System.Collections.Generic.List[string]]::new()

$report.Add("PC MAINTENANCE AUDIT v$ScriptVersion")
$report.Add("==========================")
$report.Add("")
$report.Add("Timestamp : $($snapshot.Timestamp)")
$report.Add("Mode      : $Mode")
$report.Add("Duration  : $DurationSeconds seconds")
$report.Add("Measurement warnings: $script:MeasurementWarnings (sizes may be incomplete)")
$report.Add("Reparse points are excluded; directory totals can overlap. GB fields use GiB (1024^3 bytes).")
$report.Add("")

# Disk

$report.Add("DISK C:")
$report.Add("-------")
$report.Add("Used        : $($disk.UsedGB) GB")
$report.Add("Free        : $($disk.FreeGB) GB")
$report.Add("Free        : $($disk.FreePercent)%")
$report.Add("Health      : $($disk.Health)")
$report.Add("Operational : $($disk.Operational)")
$report.Add("")

if ($null -ne $diskDiff) {

    $report.Add("DISK DIFF")
    $report.Add("---------")
    $report.Add(
        "Previous used : $($diskDiff.PreviousUsedGB) GB"
    )
    $report.Add(
        "Current used  : $($diskDiff.CurrentUsedGB) GB"
    )
    $report.Add(
        "Delta         : $($diskDiff.DeltaUsedGB) GB"
    )
    $report.Add(
        "Status        : $($diskDiff.Status)"
    )
    $report.Add("")
}

# Package caches

$report.Add("PACKAGE MANAGER CACHES")
$report.Add("----------------------")

foreach ($item in $packageCaches) {

    if ($item.Measured) {

        $line =
        "{0,-6} {1,8:N3} GB  {2}" -f @(
            $item.Manager,
            $item.PhysicalGB,
            $item.Path
        )
    }
    else {

        $state = if ($item.Exists) {
            "present; size deferred"
        }
        else {
            "not found"
        }

        $line =
        "{0,-6} {1,-22} {2}" -f @(
            $item.Manager,
            $state,
            $item.Path
        )
    }

    $report.Add($line)
}

$report.Add("")

# Project artifacts

$report.Add("PROJECT ARTIFACTS")
$report.Add("-----------------")

foreach (
    $item in
    ($projectArtifacts |
    Sort-Object PhysicalGB -Descending)
) {

    $line =
    "{0,8:N3} GB  {1,-14} files={2,-8} scan={3,7:N2}s  {4}" -f @(
        $item.PhysicalGB,
        $item.Name,
        $item.Files,
        $item.ScanSeconds,
        $item.Path
    )

    $report.Add($line)
}

$report.Add("")

# Aggregated caches

$report.Add("REGENERABLE PROJECT CACHES")
$report.Add("--------------------------")

foreach ($item in $aggregatedCaches) {

    $line =
    "{0,-16} dirs={1,-6} files={2,-8} physical={3:N3} GB logical={4:N3} GB" -f @(
        $item.Name,
        $item.Directories,
        $item.Files,
        $item.PhysicalGB,
        $item.LogicalGB
    )

    $report.Add($line)
}


$report.Add("")

if ($Mode -in @("Quarterly", "Full")) {
    $report.Add("AGGREGATED BUILD ARTIFACTS")
    $report.Add("--------------------------")

    foreach ($item in ($quarterlyAggregatedArtifacts | Sort-Object PhysicalGB -Descending)) {
        $line =
        "{0,-12} dirs={1,-6} files={2,-8} physical={3:N3} GB logical={4:N3} GB" -f @(
            $item.Name,
            $item.Directories,
            $item.Files,
            $item.PhysicalGB,
            $item.LogicalGB
        )
        $report.Add($line)
    }
}

# Maven / Gradle

if ($devCaches.Count -gt 0) {

    $report.Add("")
    $report.Add("MAVEN / GRADLE")
    $report.Add("--------------")

    foreach ($item in $devCaches) {

        $line =
        "{0,-10} {1:N3} GB  {2}" -f @(
            $item.Name,
            $item.PhysicalGB,
            $item.Path
        )

        $report.Add($line)
    }
}

# VHDX

$report.Add("")
$report.Add("VHDX")
$report.Add("----")

foreach ($item in $vhdx) {

    $line =
    "{0,8:N3} GB physical  {1,8:N3} GB logical  {2}" -f @(
        $item.PhysicalGB,
        $item.LogicalGB,
        $item.Path
    )

    $report.Add($line)
}

# Docker

if (-not [string]::IsNullOrWhiteSpace(
        [string]$docker
    )) {

    $report.Add("")
    $report.Add("DOCKER")
    $report.Add("------")
    $report.Add([string]$docker)
}

# Performance

$report.Add("")
$report.Add("PERFORMANCE")
$report.Add("-----------")

foreach (
    $item in
    ($phaseTimings |
    Sort-Object Seconds -Descending)
) {

    $line =
    "{0,-32} {1,8:N2} s" -f @(
        $item.Phase,
        $item.Seconds
    )

    $report.Add($line)
}

$report.Add("")
$report.Add("INDIVIDUAL ARTIFACT SCAN TIMES")
$report.Add("------------------------------")

foreach (
    $item in
    ($projectArtifacts |
    Sort-Object ScanSeconds -Descending)
) {

    $line =
    "{0,8:N2} s  files={1,-8} size={2,8:N3} GB  {3}" -f @(
        $item.ScanSeconds,
        $item.Files,
        $item.PhysicalGB,
        $item.Path
    )

    $report.Add($line)
}

# Full directory changes

if (
    $Mode -eq "Full" -and
    $null -ne $previous -and
    $fullDirectoryDiff.Count -gt 0
) {
    $report.Add("")
    $report.Add("FULL DIRECTORY CHANGES")
    $report.Add("----------------------")

    foreach ($item in $fullDirectoryDiff) {
        $line =
        "{0,8:N3} -> {1,8:N3} GB  delta={2,8:+0.000;-0.000;0.000} GB  {3,-7}  {4}" -f @(
            $item.PreviousGB,
            $item.CurrentGB,
            $item.DeltaGB,
            $item.Status,
            $item.Path
        )

        $report.Add($line)
    }
}

# Signals

if ($null -ne $previous) {

    $report.Add("")
    $report.Add("CHANGES / SIGNALS")
    $report.Add("-----------------")

    $signals = @()

    $signals += @(
        $artifactDiff |
        Where-Object {
            $_.Status -ne "OK"
        }
    )

    $signals += @(
        $cacheDiff |
        Where-Object {
            $_.Status -ne "OK"
        }
    )

    $signals += @(
        $aggregateDiff |
        Where-Object {
            $_.Status -ne "OK"
        }
    )

    $signals += @(
        $quarterlyAggregateDiff |
        Where-Object {
            $_.Status -ne "OK"
        }
    )

    $signals += @(
        $fullDirectoryDiff |
        Where-Object {
            $_.Status -ne "OK"
        }
    )

    $signals += @(
        $vhdxDiff |
        Where-Object {
            $_.Status -ne "OK"
        }
    )

    if ($signals.Count -eq 0) {
        $report.Add("No CHECK/WARNING signals.")
    }
    else {

        foreach ($signal in $signals) {

            $signalJson =
            $signal |
            ConvertTo-Json -Compress -Depth 5

            $report.Add($signalJson)
        }
    }
}

# Full measurements

if ($fullDirectories.Count -gt 0) {

    $report.Add("")
    $report.Add("FULL DIRECTORY MEASUREMENTS")
    $report.Add("---------------------------")

    foreach ($item in $fullDirectories) {

        $line =
        "{0,8:N3} GB physical  {1,8:N3} GB logical  {2}" -f @(
            $item.PhysicalGB,
            $item.LogicalGB,
            $item.Path
        )

        $report.Add($line)
    }
}

$report |
Set-Content `
    -LiteralPath $reportPath `
    -Encoding UTF8

# ============================================================
# CONSOLE
# ============================================================

Write-Host ""
Write-Host "Audit completed." `
    -ForegroundColor Green

Write-Host (
    "Duration: {0} seconds" -f
    $DurationSeconds
)

Write-Host ""

Write-Host "Disk:" -ForegroundColor Cyan

@(
    [PSCustomObject]@{
        UsedGB      = $disk.UsedGB
        FreeGB      = $disk.FreeGB
        FreePercent = $disk.FreePercent
        Health      = $disk.Health
        Status      =
        Get-FreeSpaceStatus `
            -FreePercent $disk.FreePercent
    }
) |
Format-Table -AutoSize |
Out-Host

Write-Host "Package manager caches:" `
    -ForegroundColor Cyan

@(
    $packageCaches |
    Select-Object `
        Manager,
    Exists,
    Measured,
    PhysicalGB,
    LogicalGB,
    Path
) |
Format-Table -AutoSize |
Out-Host

Write-Host "Project environments/dependencies:" `
    -ForegroundColor Cyan

@(
    $projectArtifacts |
    Sort-Object PhysicalGB -Descending |
    Select-Object -First 20
) |
Format-Table `
    PhysicalGB,
LogicalGB,
Files,
ScanSeconds,
Name,
Path `
    -AutoSize |
Out-Host

Write-Host "Aggregated regenerable caches:" `
    -ForegroundColor Cyan

@($aggregatedCaches) |
Format-Table `
    Name,
Directories,
Files,
PhysicalGB,
LogicalGB `
    -AutoSize |
Out-Host

if ($Mode -in @("Quarterly", "Full")) {
    Write-Host "Aggregated build artifacts:" -ForegroundColor Cyan

    @($quarterlyAggregatedArtifacts) |
    Format-Table `
        Name,
    Directories,
    Files,
    PhysicalGB,
    LogicalGB `
        -AutoSize |
    Out-Host
}

Write-Host "VHDX:" -ForegroundColor Cyan

@($vhdx) |
Format-Table `
    PhysicalGB,
LogicalGB,
Path `
    -AutoSize |
Out-Host

# Diff

if ($null -eq $previous) {

    Write-Host ""

    Write-Host (
        "No previous compatible $Mode schema-v$SchemaVersion snapshot. " +
        "This run is the new baseline."
    ) -ForegroundColor Yellow
}
else {

    Write-Host ""
    Write-Host "Disk change:" `
        -ForegroundColor Cyan

    @($diskDiff) |
    Format-Table -AutoSize |
    Out-Host

    if (
        $Mode -eq "Full" -and
        $fullDirectoryDiff.Count -gt 0
    ) {
        Write-Host "Full directory changes:" `
            -ForegroundColor Cyan

        @($fullDirectoryDiff) |
        Format-Table `
            PreviousGB,
        CurrentGB,
        DeltaGB,
        Status,
        Path `
            -AutoSize |
        Out-Host
    }

    $signals = @()

    $signals += @(
        $artifactDiff |
        Where-Object Status -ne "OK"
    )

    $signals += @(
        $cacheDiff |
        Where-Object Status -ne "OK"
    )

    $signals += @(
        $aggregateDiff |
        Where-Object Status -ne "OK"
    )

    $signals += @(
        $quarterlyAggregateDiff |
        Where-Object Status -ne "OK"
    )

    $signals += @(
        $fullDirectoryDiff |
        Where-Object Status -ne "OK"
    )

    $signals += @(
        $vhdxDiff |
        Where-Object Status -ne "OK"
    )

    Write-Host "CHECK / WARNING:" `
        -ForegroundColor Cyan

    if ($signals.Count -eq 0) {
        Write-Host "None." `
            -ForegroundColor Green
    }
    else {
        $signals |
        Format-List |
        Out-Host
    }
}

# Performance

Write-Host ""
Write-Host "Performance:" `
    -ForegroundColor Cyan

@(
    $phaseTimings |
    Sort-Object Seconds -Descending
) |
Format-Table Phase, Seconds -AutoSize |
Out-Host

Write-Host "Individual artifact scan times:" `
    -ForegroundColor Cyan

@(
    $projectArtifacts |
    Sort-Object ScanSeconds -Descending
) |
Format-Table `
    ScanSeconds,
Files,
PhysicalGB,
Name,
Path `
    -AutoSize |
Out-Host

Write-Host ""
Write-Host "Snapshot:"
Write-Host "  $snapshotPath"

Write-Host "Report:"
Write-Host "  $reportPath"
