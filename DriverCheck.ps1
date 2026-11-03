<#
.SYNOPSIS
    DriverCheck 4.2.0
    Read-only Windows driver inventory and Windows Update driver scanner.

.DESCRIPTION
    DriverCheck inventories signed Plug and Play drivers installed on Windows and,
    optionally, queries the Windows Update Agent (WUA) for applicable driver packages.

    The script is deliberately read-only.

    It DOES NOT:
      - install drivers
      - download drivers
      - remove drivers
      - modify the Driver Store
      - accept EULAs
      - modify Windows Update configuration
      - modify devices

    DriverCheck consolidates equivalent driver instances, handles known synthetic
    driver dates, collects Hardware IDs in bulk, and uses Hardware IDs as the primary
    signal when matching Windows Update packages to installed devices.

    IMPORTANT:
    "No update" means that a successful Windows Update Agent scan did not find a
    confidently matched applicable package for that driver.

    It does NOT mean that the hardware vendor does not publish a newer driver.

.PARAMETER CheckUpdates
    Query the configured Windows Update Agent source for applicable driver packages.

.PARAMETER UpdatesOnly
    Display only installed drivers matched to Windows Update packages.
    Implies -CheckUpdates.

.PARAMETER VerboseUpdates
    Display detailed metadata for Windows Update driver packages.
    Implies -CheckUpdates.

.PARAMETER ThirdPartyOnly
    Hide Microsoft-provided drivers from the displayed inventory.

.PARAMETER OldOnly
    Display only Aging and Old drivers.

.PARAMETER Filter
    Filter displayed inventory by device name, provider, manufacturer, version,
    class, INF name, Device ID, or Hardware ID.

.PARAMETER WarningAgeYears
    Driver age at which a real driver date is classified as Aging.
    Default: 2.

.PARAMETER CriticalAgeYears
    Driver age at which a real driver date is classified as Old.
    Default: 4.

.PARAMETER SortBy
    Sort displayed inventory by:
      Name
      Provider
      Version
      Date
      Status
      UpdateStatus

.PARAMETER Descending
    Reverse the selected sort.

.PARAMETER CsvPath
    Export displayed inventory to CSV.

.PARAMETER JsonPath
    Export a structured JSON report.

.PARAMETER Diagnostics
    Display environment, inventory, matching, and Windows Update diagnostics.

.PARAMETER NoColor
    Disable colored console output.

.PARAMETER NoProgress
    Disable Write-Progress.

.PARAMETER NoExit
    Do not call exit when execution completes.
    Useful when dot-sourcing or testing.

.EXAMPLE
    .\DriverCheck.ps1

.EXAMPLE
    .\DriverCheck.ps1 -CheckUpdates

.EXAMPLE
    .\DriverCheck.ps1 -CheckUpdates -VerboseUpdates -Diagnostics

.EXAMPLE
    .\DriverCheck.ps1 -ThirdPartyOnly -CheckUpdates

.EXAMPLE
    .\DriverCheck.ps1 -CheckUpdates -CsvPath .\drivers.csv -JsonPath .\drivers.json

.EXITCODES
    0 = Completed successfully; no newer matched driver updates found.
    1 = Fatal error or requested export failed.
    2 = One or more newer matched driver updates were found.
    3 = Windows Update scan was requested but failed.

.NOTES
    Name:       DriverCheck
    Version:    4.2.0
    License:    MIT

    Designed for:
      - Windows PowerShell 5.1
      - PowerShell 7+ on Windows
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 20)]
    [int]$WarningAgeYears = 2,

    [ValidateRange(1, 30)]
    [int]$CriticalAgeYears = 4,

    [string]$Filter,

    [switch]$OldOnly,
    [switch]$ThirdPartyOnly,
    [switch]$CheckUpdates,
    [switch]$UpdatesOnly,
    [switch]$VerboseUpdates,

    [ValidateSet(
        'Name',
        'Provider',
        'Version',
        'Date',
        'Status',
        'UpdateStatus'
    )]
    [string]$SortBy = 'Name',

    [switch]$Descending,

    [string]$CsvPath,
    [string]$JsonPath,

    [switch]$Diagnostics,
    [switch]$NoColor,
    [switch]$NoProgress,
    [switch]$NoExit
)


# ============================================================================
# Configuration
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptName = 'DriverCheck'
$ScriptVersion = '4.2.0'

if ($CriticalAgeYears -le $WarningAgeYears) {
    throw 'CriticalAgeYears must be greater than WarningAgeYears.'
}

if ($UpdatesOnly -or $VerboseUpdates) {
    $CheckUpdates = $true
}

$script:Warnings = [System.Collections.Generic.List[string]]::new()

$script:Scan = [ordered]@{
    Started               = Get-Date
    Completed             = $null

    InventoryCompleted    = $false
    InventoryRawInstances = 0
    InventoryUnique       = 0

    HardwareIdMethod      = 'Not attempted'
    HardwareIdEntities    = 0
    HardwareIdEntries     = 0

    UpdateScanRequested   = [bool]$CheckUpdates
    UpdateScanCompleted   = $false
    UpdateScanError       = $null
    UpdateSearchSeconds   = $null

    UpdatesReturned       = 0
    MatchedUpdates        = 0
    UnmatchedUpdates      = 0
    NewerUpdates          = 0

    InventorySeconds      = $null
    MatchingSeconds       = $null
}

$script:ExportFailure = $false

$C = @{
    Title   = 'Cyan'
    Header  = 'Cyan'
    Normal  = 'Gray'
    Accent  = 'White'
    Muted   = 'DarkGray'
    Good    = 'Green'
    Warning = 'Yellow'
    Error   = 'Red'
    System  = 'DarkCyan'
    Older   = 'Magenta'
}


# ============================================================================
# Console helpers
# ============================================================================

function Write-C {
    param(
        [AllowEmptyString()]
        [string]$Text = '',

        [ConsoleColor]$Color = 'Gray',

        [switch]$NoNewline
    )

    if ($NoColor) {
        Write-Host $Text -NoNewline:$NoNewline
    }
    else {
        Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline
    }
}


function Add-DriverCheckWarning {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $script:Warnings.Contains($Message)) {
        $script:Warnings.Add($Message)
    }
}


function Show-DriverCheckProgress {
    param(
        [ValidateRange(0, 100)]
        [int]$Percent,

        [string]$Activity,

        [string]$Status
    )

    if (-not $NoProgress) {
        Write-Progress `
            -Id 1 `
            -Activity "$ScriptName $ScriptVersion - $Activity" `
            -Status $Status `
            -PercentComplete $Percent
    }
}


function Complete-DriverCheckProgress {
    if (-not $NoProgress) {
        Write-Progress `
            -Id 1 `
            -Activity $ScriptName `
            -Completed
    }
}


function Get-DisplayValue {
    param(
        [AllowNull()]
        [object]$Value,

        [string]$Fallback = 'Not provided'
    )

    if (
        $null -eq $Value -or
        [string]::IsNullOrWhiteSpace([string]$Value)
    ) {
        return $Fallback
    }

    return [string]$Value
}


function Format-Cell {
    param(
        [AllowNull()]
        [object]$Value,

        [ValidateRange(1, 500)]
        [int]$Width,

        [switch]$Right
    )

    $text = if ($null -eq $Value) {
        ''
    }
    else {
        [string]$Value
    }

    if ($text.Length -gt $Width) {

        if ($Width -le 3) {
            $text = $text.Substring(0, $Width)
        }
        else {
            $text = $text.Substring(0, $Width - 3) + '...'
        }
    }

    if ($Right) {
        return $text.PadLeft($Width)
    }

    return $text.PadRight($Width)
}


function Get-ConsoleWidth {

    try {
        $width = [Console]::WindowWidth

        if ($width -ge 80) {
            return $width
        }
    }
    catch {
    }

    return 120
}


# ============================================================================
# Generic helpers
# ============================================================================

function Normalize-HardwareId {
    param(
        [AllowNull()]
        [string]$Id
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        return $null
    }

    return $Id.Trim().ToUpperInvariant()
}


function Normalize-Text {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    return $Text.Trim()
}


function Get-SafeDate {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    try {
        return [datetime]$Value
    }
    catch {
        return $null
    }
}


# ============================================================================
# Driver date classification
# ============================================================================

function Test-SyntheticDriverDate {
    param(
        [AllowNull()]
        [datetime]$Date,

        [AllowNull()]
        [string]$Provider
    )

    if ($null -eq $Date) {
        return $false
    }

    $providerText = Normalize-Text $Provider

    # Microsoft commonly uses historical dates for inbox/system drivers.
    if (
        $providerText -match '^Microsoft(?: Corporation)?$' -and
        $Date.Year -lt 2010
    ) {
        return $true
    }

    # Intel chipset INF packages frequently use historical dates such as 1968.
    if (
        $providerText -match '^Intel' -and
        $Date.Year -lt 1990
    ) {
        return $true
    }

    # Dates this old are not useful as driver freshness indicators.
    if ($Date.Year -lt 1990) {
        return $true
    }

    return $false
}


function Get-DriverAgeState {
    param(
        [AllowNull()]
        [datetime]$Date,

        [AllowNull()]
        [string]$Provider
    )

    if (
        $null -eq $Date -or
        $Date -eq [datetime]::MinValue
    ) {
        return 'Unknown'
    }

    if (Test-SyntheticDriverDate $Date $Provider) {
        return 'System'
    }

    $ageDays = ((Get-Date) - $Date).TotalDays

    if ($ageDays -ge ($CriticalAgeYears * 365.25)) {
        return 'Old'
    }

    if ($ageDays -ge ($WarningAgeYears * 365.25)) {
        return 'Aging'
    }

    return 'Recent'
}


function Get-AgeColor {
    param(
        [string]$State
    )

    switch ($State) {
        'Recent' { return $C.Good }
        'Aging' { return $C.Warning }
        'Old' { return $C.Error }
        'System' { return $C.System }
        default { return $C.Muted }
    }
}


# ============================================================================
# Version handling
# ============================================================================

function Get-VersionFromUpdateTitle {
    param(
        [AllowNull()]
        [string]$Title
    )

    if (
        $Title -and
        $Title -match '(?<Version>\d+(?:\.\d+){1,7})\s*$'
    ) {
        return $Matches.Version
    }

    return $null
}


function Convert-DriverVersionParts {
    param(
        [AllowNull()]
        [string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return $null
    }

    $v = $Version.Trim()

    if ($v -notmatch '^\d+(?:\.\d+)+$') {
        return $null
    }

    try {
        $parts = [System.Collections.Generic.List[uint64]]::new()

        foreach ($part in $v.Split('.')) {
            $parts.Add([uint64]$part)
        }

        return $parts.ToArray()
    }
    catch {
        return $null
    }
}


function Compare-DriverVersion {
    param(
        [AllowNull()]
        [string]$Installed,

        [AllowNull()]
        [string]$Available
    )

    $installedParts = Convert-DriverVersionParts $Installed
    $availableParts = Convert-DriverVersionParts $Available

    if (
        $null -eq $installedParts -or
        $null -eq $availableParts
    ) {
        return $null
    }

    $count = [Math]::Max(
        $installedParts.Count,
        $availableParts.Count
    )

    for ($i = 0; $i -lt $count; $i++) {

        $installedPart = if ($i -lt $installedParts.Count) {
            $installedParts[$i]
        }
        else {
            [uint64]0
        }

        $availablePart = if ($i -lt $availableParts.Count) {
            $availableParts[$i]
        }
        else {
            [uint64]0
        }

        if ($availablePart -gt $installedPart) {
            return 1
        }

        if ($availablePart -lt $installedPart) {
            return -1
        }
    }

    return 0
}


function Get-DriverUpdateStatus {
    param(
        [string]$Installed,

        [AllowNull()]
        [string]$Available,

        [bool]$Matched,

        [ValidateSet(
            'NotRun',
            'Succeeded',
            'Failed'
        )]
        [string]$ScanState
    )

    if ($ScanState -eq 'NotRun') {
        return 'Not checked'
    }

    if ($ScanState -eq 'Failed') {
        return 'Scan failed'
    }

    if (-not $Matched) {
        return 'No update'
    }

    if ([string]::IsNullOrWhiteSpace($Available)) {
        return 'Version unknown'
    }

    $comparison = Compare-DriverVersion `
        $Installed `
        $Available

    if ($null -eq $comparison) {
        return 'Version unknown'
    }

    if ($comparison -gt 0) {
        return 'Update'
    }

    if ($comparison -eq 0) {
        return 'Same'
    }

    return 'Older offered'
}


function Get-UpdateStatusColor {
    param(
        [string]$Status
    )

    switch ($Status) {
        'Update' { return $C.Warning }
        'Same' { return $C.Good }
        'No update' { return $C.Good }
        'Older offered' { return $C.Older }
        'Version unknown' { return $C.Warning }
        'Scan failed' { return $C.Error }
        default { return $C.Muted }
    }
}


# ============================================================================
# Environment information
# ============================================================================

function Get-EnvironmentInfo {

    $os = $null
    $computer = $null

    try {
        $os = Get-CimInstance `
            -ClassName Win32_OperatingSystem `
            -ErrorAction Stop
    }
    catch {
    }

    try {
        $computer = Get-CimInstance `
            -ClassName Win32_ComputerSystem `
            -ErrorAction Stop
    }
    catch {
    }

    $isAdministrator = $false

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

        $principal = [Security.Principal.WindowsPrincipal]::new(
            $identity
        )

        $isAdministrator = $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
    }
    catch {
    }

    $useWuServer = $null
    $wuServer = $null

    try {
        $policy = Get-ItemProperty `
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' `
            -ErrorAction Stop

        if ($null -ne $policy.UseWUServer) {
            $useWuServer = [bool]$policy.UseWUServer
        }
    }
    catch {
    }

    try {
        $policy = Get-ItemProperty `
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' `
            -ErrorAction Stop

        if ($policy.WUServer) {
            $wuServer = [string]$policy.WUServer
        }
    }
    catch {
    }

    $updateSource = if ($useWuServer -eq $true) {
        'Managed update service / WSUS policy'
    }
    elseif ($useWuServer -eq $false) {
        'Windows Update service'
    }
    else {
        'WUA default/configured service'
    }

    [pscustomobject]@{
        ComputerName    = $env:COMPUTERNAME

        Manufacturer    = if ($computer) {
            $computer.Manufacturer
        }
        else {
            $null
        }

        Model           = if ($computer) {
            $computer.Model
        }
        else {
            $null
        }

        OS              = if ($os) {
            $os.Caption
        }
        else {
            [Environment]::OSVersion.VersionString
        }

        OSVersion       = if ($os) {
            $os.Version
        }
        else {
            [Environment]::OSVersion.Version.ToString()
        }

        OSBuild         = if ($os) {
            $os.BuildNumber
        }
        else {
            $null
        }

        PowerShell      = $PSVersionTable.PSVersion.ToString()

        PSEdition       = if ($PSVersionTable.PSEdition) {
            $PSVersionTable.PSEdition
        }
        else {
            'Desktop'
        }

        IsAdministrator = $isAdministrator

        UpdateSource    = $updateSource
        UseWUServer     = $useWuServer
        WUServer        = $wuServer
    }
}


# ============================================================================
# Bulk Hardware ID collection
# ============================================================================

function Get-HardwareIdLookup {

    Show-DriverCheckProgress `
        8 `
        'Inventory' `
        'Collecting Plug and Play Hardware IDs...'

    $lookup = @{}

    try {

        # Win32_PnPEntity exposes HardwareID[] directly and allows us to retrieve
        # the information in ONE CIM query instead of issuing one PnP property
        # query per installed device.
        $entities = @(
            Get-CimInstance `
                -ClassName Win32_PnPEntity `
                -ErrorAction Stop
        )

        $script:Scan.HardwareIdMethod =
        'Win32_PnPEntity bulk lookup'

        $script:Scan.HardwareIdEntities =
        $entities.Count

        $idCount = 0

        foreach ($entity in $entities) {

            if ([string]::IsNullOrWhiteSpace([string]$entity.PNPDeviceID)) {
                continue
            }

            $instanceId = $entity.PNPDeviceID.Trim().ToUpperInvariant()

            $ids = [System.Collections.Generic.List[string]]::new()

            foreach ($rawId in @($entity.HardwareID)) {

                $id = Normalize-HardwareId ([string]$rawId)

                if (
                    $id -and
                    -not $ids.Contains($id)
                ) {
                    $ids.Add($id)
                    $idCount++
                }
            }

            $lookup[$instanceId] = $ids.ToArray()
        }

        $script:Scan.HardwareIdEntries = $idCount
    }
    catch {

        $script:Scan.HardwareIdMethod =
        'Win32_PnPEntity unavailable; signed-driver fallback'

        Add-DriverCheckWarning (
            'Bulk Hardware ID collection failed: {0}' -f
            $_.Exception.Message
        )
    }

    return $lookup
}


# ============================================================================
# Inventory
# ============================================================================

function Get-DriverInventory {

    $timer = [Diagnostics.Stopwatch]::StartNew()

    Show-DriverCheckProgress `
        3 `
        'Inventory' `
        'Querying signed PnP drivers...'

    $signedDrivers = @(
        Get-CimInstance `
            -ClassName Win32_PnPSignedDriver `
            -ErrorAction Stop |
        Where-Object {
            $_.DeviceName -and
            $_.DriverVersion
        }
    )

    $script:Scan.InventoryRawInstances =
    $signedDrivers.Count

    $hardwareLookup = Get-HardwareIdLookup

    Show-DriverCheckProgress `
        15 `
        'Inventory' `
        'Building driver inventory...'

    $rows = [System.Collections.Generic.List[object]]::new()

    $index = 0

    foreach ($driver in $signedDrivers) {

        $index++

        if ($signedDrivers.Count -gt 0) {

            $progress = 15 + [Math]::Floor(
                20 * $index / $signedDrivers.Count
            )

            Show-DriverCheckProgress `
                $progress `
                'Inventory' `
                "Processing $index of $($signedDrivers.Count)..."
        }

        $provider = if ($driver.DriverProviderName) {
            ([string]$driver.DriverProviderName).Trim()
        }
        elseif ($driver.Manufacturer) {
            ([string]$driver.Manufacturer).Trim()
        }
        else {
            'Unknown'
        }

        $date = Get-SafeDate $driver.DriverDate

        $deviceId = Normalize-Text ([string]$driver.DeviceID)

        $hardwareIds =
        [System.Collections.Generic.List[string]]::new()

        if ($deviceId) {

            $lookupKey = $deviceId.ToUpperInvariant()

            if ($hardwareLookup.ContainsKey($lookupKey)) {

                foreach ($id in $hardwareLookup[$lookupKey]) {

                    if (
                        $id -and
                        -not $hardwareIds.Contains($id)
                    ) {
                        $hardwareIds.Add($id)
                    }
                }
            }
        }

        # Fallback to the HardwareID exposed by Win32_PnPSignedDriver.
        if ($hardwareIds.Count -eq 0) {

            try {
                $fallbackId = Normalize-HardwareId (
                    [string]$driver.HardWareID
                )

                if ($fallbackId) {
                    $hardwareIds.Add($fallbackId)
                }
            }
            catch {
            }
        }

        $rows.Add(
            [pscustomobject]@{
                Device              = Normalize-Text ([string]$driver.DeviceName)
                Provider            = $provider
                Manufacturer        = Normalize-Text ([string]$driver.Manufacturer)
                Version             = Normalize-Text ([string]$driver.DriverVersion)
                Date                = $date

                State               = Get-DriverAgeState `
                    $date `
                    $provider

                DeviceClass         = Normalize-Text ([string]$driver.DeviceClass)
                ClassGuid           = Normalize-Text ([string]$driver.ClassGuid)
                DeviceID            = $deviceId
                InfName             = Normalize-Text ([string]$driver.InfName)

                IsSigned            = [bool]$driver.IsSigned

                HardwareIds         = $hardwareIds.ToArray()

                Instances           = 1

                UpdateMatched       = $false
                UpdateTitle         = $null
                UpdateVersion       = $null
                UpdateVersionSource = $null
                UpdateDate          = $null
                UpdateProvider      = $null
                UpdateID            = $null

                UpdateStatus        = if ($CheckUpdates) {
                    'Pending scan'
                }
                else {
                    'Not checked'
                }

                MatchScore          = 0
                MatchReason         = $null
            }
        )
    }

    # IMPORTANT:
    # ToArray() is intentionally used here instead of @($rows).
    #
    # PowerShell 7.6.x can throw:
    # "Argument types do not match"
    # from PSToObjectArrayBinder when @() is used with some generic lists.
    $work = $rows.ToArray()

    Show-DriverCheckProgress `
        38 `
        'Inventory' `
        'Consolidating equivalent driver instances...'

    # User-facing inventory deduplication deliberately does NOT use InfName in
    # the grouping key. Equivalent device/driver rows should appear once.
    #
    # All INF names, Device IDs and Hardware IDs are retained in arrays.
    $groups = @(
        $work |
        Group-Object `
            Device,
        Provider,
        Version,
        Date
    )

    $inventory =
    [System.Collections.Generic.List[object]]::new()

    foreach ($group in $groups) {

        $first = $group.Group[0]

        $deviceIds =
        [System.Collections.Generic.List[string]]::new()

        $hardwareIds =
        [System.Collections.Generic.List[string]]::new()

        $infNames =
        [System.Collections.Generic.List[string]]::new()

        $deviceClasses =
        [System.Collections.Generic.List[string]]::new()

        foreach ($item in $group.Group) {

            if (
                $item.DeviceID -and
                -not $deviceIds.Contains($item.DeviceID)
            ) {
                $deviceIds.Add($item.DeviceID)
            }

            if (
                $item.InfName -and
                -not $infNames.Contains($item.InfName)
            ) {
                $infNames.Add($item.InfName)
            }

            if (
                $item.DeviceClass -and
                -not $deviceClasses.Contains($item.DeviceClass)
            ) {
                $deviceClasses.Add($item.DeviceClass)
            }

            foreach ($hardwareId in $item.HardwareIds) {

                $normalized = Normalize-HardwareId $hardwareId

                if (
                    $normalized -and
                    -not $hardwareIds.Contains($normalized)
                ) {
                    $hardwareIds.Add($normalized)
                }
            }
        }

        $inventory.Add(
            [pscustomobject]@{
                Device              = $first.Device
                Provider            = $first.Provider
                Manufacturer        = $first.Manufacturer
                Version             = $first.Version
                Date                = $first.Date
                State               = $first.State

                DeviceClass         = 
                if ($deviceClasses.Count -gt 0) {
                    $deviceClasses[0]
                }
                else {
                    $first.DeviceClass
                }

                DeviceClasses       = $deviceClasses.ToArray()
                ClassGuid           = $first.ClassGuid

                DeviceIDs           = $deviceIds.ToArray()
                HardwareIds         = $hardwareIds.ToArray()
                InfNames            = $infNames.ToArray()

                IsSigned            = $first.IsSigned
                Instances           = $group.Count

                UpdateMatched       = $false
                UpdateTitle         = $null
                UpdateVersion       = $null
                UpdateVersionSource = $null
                UpdateDate          = $null
                UpdateProvider      = $null
                UpdateID            = $null

                UpdateStatus        = if ($CheckUpdates) {
                    'Pending scan'
                }
                else {
                    'Not checked'
                }

                MatchScore          = 0
                MatchReason         = $null
            }
        )
    }

    $timer.Stop()

    $script:Scan.InventoryCompleted = $true
    $script:Scan.InventoryUnique = $inventory.Count
    $script:Scan.InventorySeconds = $timer.Elapsed.TotalSeconds

    return $inventory.ToArray()
}


# ============================================================================
# Windows Update Agent
# ============================================================================

function Get-WindowsDriverUpdates {

    $timer = [Diagnostics.Stopwatch]::StartNew()

    $session = $null
    $searcher = $null
    $result = $null

    try {

        Show-DriverCheckProgress `
            48 `
            'Windows Update' `
            'Initializing Windows Update Agent...'

        $session = New-Object `
            -ComObject 'Microsoft.Update.Session'

        $session.ClientApplicationID =
        "$ScriptName $ScriptVersion"

        $searcher = $session.CreateUpdateSearcher()

        $searcher.Online = $true

        try {
            $searcher.IncludePotentiallySupersededUpdates = $false
        }
        catch {
        }

        Show-DriverCheckProgress `
            55 `
            'Windows Update' `
            'Searching for applicable driver packages...'

        $criteria =
        "IsInstalled=0 and IsHidden=0 and Type='Driver'"

        $result = $searcher.Search($criteria)

        $script:Scan.UpdateScanCompleted = $true
        $script:Scan.UpdatesReturned = $result.Updates.Count

        $updates =
        [System.Collections.Generic.List[object]]::new()

        for (
            $i = 0;
            $i -lt $result.Updates.Count;
            $i++
        ) {

            $update = $result.Updates.Item($i)

            Show-DriverCheckProgress `
            (75 + [Math]::Floor(
                    10 * ($i + 1) /
                    [Math]::Max(1, $result.Updates.Count)
                )) `
                'Windows Update' `
                "Reading package $($i + 1) of $($result.Updates.Count)..."

            $driverClass = $null
            $driverModel = $null
            $driverManufacturer = $null
            $driverProvider = $null
            $driverVersion = $null
            $driverDate = $null
            $versionSource = $null

            $hardwareIds =
            [System.Collections.Generic.List[string]]::new()

            $categories =
            [System.Collections.Generic.List[string]]::new()

            $kbArticles =
            [System.Collections.Generic.List[string]]::new()

            try {
                $driverClass = [string]$update.DriverClass
            }
            catch {
            }

            try {
                $driverModel = [string]$update.DriverModel
            }
            catch {
            }

            try {
                $driverManufacturer =
                [string]$update.DriverManufacturer
            }
            catch {
            }

            try {
                $driverProvider =
                [string]$update.DriverProvider
            }
            catch {
            }

            try {
                if ($update.DriverVerDate) {
                    $driverDate =
                    [datetime]$update.DriverVerDate
                }
            }
            catch {
            }

            try {
                $driverVersion =
                [string]$update.DriverVerVersion
            }
            catch {
            }

            if (
                -not [string]::IsNullOrWhiteSpace(
                    $driverVersion
                )
            ) {
                $versionSource =
                'Windows Update metadata'
            }
            else {

                $driverVersion =
                Get-VersionFromUpdateTitle (
                    [string]$update.Title
                )

                if ($driverVersion) {
                    $versionSource = 'Update title'
                }
            }

            try {

                foreach ($rawId in @($update.DriverHardwareID)) {

                    $id = Normalize-HardwareId ([string]$rawId)

                    if (
                        $id -and
                        -not $hardwareIds.Contains($id)
                    ) {
                        $hardwareIds.Add($id)
                    }
                }
            }
            catch {
            }

            try {

                for (
                    $categoryIndex = 0;
                    $categoryIndex -lt $update.Categories.Count;
                    $categoryIndex++
                ) {

                    $categoryName =
                    [string]$update.Categories.Item(
                        $categoryIndex
                    ).Name

                    if (
                        $categoryName -and
                        -not $categories.Contains($categoryName)
                    ) {
                        $categories.Add($categoryName)
                    }
                }
            }
            catch {
            }

            try {

                foreach ($kb in @($update.KBArticleIDs)) {

                    $kbText = [string]$kb

                    if (
                        $kbText -and
                        -not $kbArticles.Contains($kbText)
                    ) {
                        $kbArticles.Add($kbText)
                    }
                }
            }
            catch {
            }

            $isDownloaded = $false
            $rebootRequired = $false
            $eulaAccepted = $false
            $isMandatory = $false
            $autoSelected = $false

            try {
                $isDownloaded = [bool]$update.IsDownloaded
            }
            catch {
            }

            try {
                $rebootRequired = [bool]$update.RebootRequired
            }
            catch {
            }

            try {
                $eulaAccepted = [bool]$update.EulaAccepted
            }
            catch {
            }

            try {
                $isMandatory = [bool]$update.IsMandatory
            }
            catch {
            }

            try {
                $autoSelected =
                [bool]$update.AutoSelectOnWebSites
            }
            catch {
            }

            $updates.Add(
                [pscustomobject]@{
                    Title               =
                    [string]$update.Title

                    Description         =
                    [string]$update.Description

                    UpdateID            =
                    [string]$update.Identity.UpdateID

                    RevisionNumber      =
                    $update.Identity.RevisionNumber

                    DriverClass         =
                    $driverClass

                    DriverModel         =
                    $driverModel

                    DriverManufacturer  =
                    $driverManufacturer

                    DriverProvider      =
                    $driverProvider

                    DriverDate          =
                    $driverDate

                    DriverVersion       =
                    $driverVersion

                    DriverVersionSource =
                    $versionSource

                    HardwareIds         =
                    $hardwareIds.ToArray()

                    Categories          =
                    $categories.ToArray()

                    KBArticleIDs        =
                    $kbArticles.ToArray()

                    IsDownloaded        =
                    $isDownloaded

                    RebootRequired      =
                    $rebootRequired

                    EulaAccepted        =
                    $eulaAccepted

                    IsMandatory         =
                    $isMandatory

                    AutoSelect          =
                    $autoSelected

                    Matched             =
                    $false

                    MatchedDevice       =
                    $null

                    MatchScore          =
                    0

                    MatchReason         =
                    $null
                }
            )
        }

        return $updates.ToArray()
    }
    catch {

        $script:Scan.UpdateScanCompleted = $false
        $script:Scan.UpdateScanError = $_.Exception.Message

        throw
    }
    finally {

        $timer.Stop()

        $script:Scan.UpdateSearchSeconds =
        $timer.Elapsed.TotalSeconds

        # Release COM references defensively.
        foreach ($comObject in @(
                $result,
                $searcher,
                $session
            )) {

            if ($null -ne $comObject) {

                try {

                    if (
                        [Runtime.InteropServices.Marshal]::IsComObject(
                            $comObject
                        )
                    ) {
                        [void][Runtime.InteropServices.Marshal]::
                        FinalReleaseComObject($comObject)
                    }
                }
                catch {
                }
            }
        }
    }
}


# ============================================================================
# Matching
# ============================================================================

function Test-HardwareIdMatch {
    param(
        [string[]]$Installed,
        [string[]]$Offered
    )

    foreach ($installedRaw in $Installed) {

        $installedId =
        Normalize-HardwareId $installedRaw

        if (-not $installedId) {
            continue
        }

        foreach ($offeredRaw in $Offered) {

            $offeredId =
            Normalize-HardwareId $offeredRaw

            if (-not $offeredId) {
                continue
            }

            if ($installedId -eq $offeredId) {

                return [pscustomobject]@{
                    Type  = 'Exact'
                    Score = 1000
                }
            }

            # Compatible/prefix matching is intentionally much weaker than exact
            # matching, but still stronger than textual model/provider heuristics.
            if (
                $installedId.StartsWith(
                    $offeredId,
                    [StringComparison]::OrdinalIgnoreCase
                ) -or
                $offeredId.StartsWith(
                    $installedId,
                    [StringComparison]::OrdinalIgnoreCase
                )
            ) {

                return [pscustomobject]@{
                    Type  = 'Compatible'
                    Score = 700
                }
            }
        }
    }

    return $null
}


function Get-DriverUpdateMatchScore {
    param(
        $Driver,
        $Update
    )

    $score = 0

    $reasons =
    [System.Collections.Generic.List[string]]::new()

    $hardwareMatch = Test-HardwareIdMatch `
        -Installed $Driver.HardwareIds `
        -Offered $Update.HardwareIds

    if ($hardwareMatch) {

        $score += $hardwareMatch.Score

        $reasons.Add(
            "$($hardwareMatch.Type) Hardware ID"
        )
    }

    $exactModel = $false
    $partialModel = $false
    $providerMatch = $false
    $manufacturerMatch = $false

    if (
        $Update.DriverModel -and
        $Driver.Device
    ) {

        if (
            $Driver.Device.Equals(
                $Update.DriverModel,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $exactModel = $true
            $score += 120
            $reasons.Add('Exact model')
        }
        elseif (
            $Driver.Device.IndexOf(
                $Update.DriverModel,
                [StringComparison]::OrdinalIgnoreCase
            ) -ge 0 -or

            $Update.DriverModel.IndexOf(
                $Driver.Device,
                [StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        ) {
            $partialModel = $true
            $score += 40
            $reasons.Add('Partial model')
        }
    }

    if (
        $Update.DriverProvider -and
        $Driver.Provider -and
        $Driver.Provider.Equals(
            $Update.DriverProvider,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        $providerMatch = $true
        $score += 80
        $reasons.Add('Provider')
    }

    if (
        $Update.DriverManufacturer -and
        $Driver.Manufacturer -and
        $Driver.Manufacturer.Equals(
            $Update.DriverManufacturer,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        $manufacturerMatch = $true
        $score += 50
        $reasons.Add('Manufacturer')
    }

    if (
        $Update.DriverClass -and
        $Driver.DeviceClass -and
        $Driver.DeviceClass.Equals(
            $Update.DriverClass,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        $score += 25
        $reasons.Add('Class')
    }

    # A textual match alone must be strong enough.
    #
    # Partial model by itself is deliberately NOT accepted.
    $confident = $false

    if ($hardwareMatch) {
        $confident = $true
    }
    elseif (
        $exactModel -and
        (
            $providerMatch -or
            $manufacturerMatch
        )
    ) {
        $confident = $true
    }
    elseif (
        $partialModel -and
        $providerMatch -and
        $manufacturerMatch
    ) {
        $confident = $true
    }

    [pscustomobject]@{
        Score     = $score
        Confident = $confident
        Reason    = $reasons -join ', '
        Hardware  = if ($hardwareMatch) {
            $hardwareMatch.Type
        }
        else {
            $null
        }
    }
}


function Compare-UpdateCandidates {
    param(
        $InstalledDriver,
        $CandidateA,
        $CandidateB
    )

    # Return:
    #  1 = A preferred
    # -1 = B preferred
    #  0 = equivalent

    if ($CandidateA.Match.Score -gt $CandidateB.Match.Score) {
        return 1
    }

    if ($CandidateA.Match.Score -lt $CandidateB.Match.Score) {
        return -1
    }

    $comparisonA = Compare-DriverVersion `
        $InstalledDriver.Version `
        $CandidateA.Update.DriverVersion

    $comparisonB = Compare-DriverVersion `
        $InstalledDriver.Version `
        $CandidateB.Update.DriverVersion

    # Prefer a known newer version over same/older/unknown.
    $rankA = if ($null -eq $comparisonA) {
        1
    }
    elseif ($comparisonA -gt 0) {
        4
    }
    elseif ($comparisonA -eq 0) {
        3
    }
    else {
        2
    }

    $rankB = if ($null -eq $comparisonB) {
        1
    }
    elseif ($comparisonB -gt 0) {
        4
    }
    elseif ($comparisonB -eq 0) {
        3
    }
    else {
        2
    }

    if ($rankA -gt $rankB) {
        return 1
    }

    if ($rankA -lt $rankB) {
        return -1
    }

    # If both versions are parseable, prefer the numerically highest one.
    if (
        $CandidateA.Update.DriverVersion -and
        $CandidateB.Update.DriverVersion
    ) {

        $versionChoice = Compare-DriverVersion `
            $CandidateB.Update.DriverVersion `
            $CandidateA.Update.DriverVersion

        if ($null -ne $versionChoice) {

            if ($versionChoice -gt 0) {
                return 1
            }

            if ($versionChoice -lt 0) {
                return -1
            }
        }
    }

    # Final deterministic tie-breaker: newest driver date.
    if (
        $CandidateA.Update.DriverDate -and
        $CandidateB.Update.DriverDate
    ) {

        if (
            $CandidateA.Update.DriverDate -gt
            $CandidateB.Update.DriverDate
        ) {
            return 1
        }

        if (
            $CandidateA.Update.DriverDate -lt
            $CandidateB.Update.DriverDate
        ) {
            return -1
        }
    }

    return 0
}


function Add-WindowsUpdateMatches {
    param(
        [object[]]$Drivers,
        [object[]]$Updates
    )

    $timer = [Diagnostics.Stopwatch]::StartNew()

    Show-DriverCheckProgress `
        88 `
        'Matching' `
        'Matching Windows Update packages to installed drivers...'

    foreach ($driver in $Drivers) {

        $bestCandidate = $null

        foreach ($update in $Updates) {

            $match = Get-DriverUpdateMatchScore `
                -Driver $driver `
                -Update $update

            if (-not $match.Confident) {
                continue
            }

            $candidate = [pscustomobject]@{
                Update = $update
                Match  = $match
            }

            if ($null -eq $bestCandidate) {
                $bestCandidate = $candidate
                continue
            }

            $preferred = Compare-UpdateCandidates `
                -InstalledDriver $driver `
                -CandidateA $candidate `
                -CandidateB $bestCandidate

            if ($preferred -gt 0) {
                $bestCandidate = $candidate
            }
        }

        if ($bestCandidate) {

            $update = $bestCandidate.Update
            $match = $bestCandidate.Match

            $driver.UpdateMatched = $true
            $driver.UpdateTitle = $update.Title
            $driver.UpdateVersion = $update.DriverVersion
            $driver.UpdateVersionSource = $update.DriverVersionSource
            $driver.UpdateDate = $update.DriverDate
            $driver.UpdateProvider = $update.DriverProvider
            $driver.UpdateID = $update.UpdateID
            $driver.MatchScore = $match.Score
            $driver.MatchReason = $match.Reason

            $driver.UpdateStatus =
            Get-DriverUpdateStatus `
                -Installed $driver.Version `
                -Available $update.DriverVersion `
                -Matched $true `
                -ScanState 'Succeeded'

            $update.Matched = $true
            $update.MatchedDevice = $driver.Device
            $update.MatchScore = $match.Score
            $update.MatchReason = $match.Reason
        }
        else {

            $driver.UpdateStatus =
            Get-DriverUpdateStatus `
                -Installed $driver.Version `
                -Available $null `
                -Matched $false `
                -ScanState 'Succeeded'
        }
    }

    $script:Scan.MatchedUpdates = @(
        $Updates |
        Where-Object {
            $_.Matched
        }
    ).Count

    $script:Scan.UnmatchedUpdates = @(
        $Updates |
        Where-Object {
            -not $_.Matched
        }
    ).Count

    $script:Scan.NewerUpdates = @(
        $Drivers |
        Where-Object {
            $_.UpdateStatus -eq 'Update'
        }
    ).Count

    $timer.Stop()

    $script:Scan.MatchingSeconds =
    $timer.Elapsed.TotalSeconds

    return $Drivers
}


# ============================================================================
# Filtering and sorting
# ============================================================================

function Select-DisplayedDrivers {
    param(
        [object[]]$Drivers
    )

    $result = $Drivers

    if ($ThirdPartyOnly) {

        $result = @(
            $result |
            Where-Object {
                $_.Provider -notmatch '^Microsoft(?: Corporation)?$'
            }
        )
    }

    if ($OldOnly) {

        $result = @(
            $result |
            Where-Object {
                $_.State -in @(
                    'Aging',
                    'Old'
                )
            }
        )
    }

    if ($Filter) {

        $escapedFilter =
        [regex]::Escape($Filter)

        $result = @(
            $result |
            Where-Object {

                $_.Device -like "*$Filter*" -or
                $_.Provider -like "*$Filter*" -or
                $_.Manufacturer -like "*$Filter*" -or
                $_.Version -like "*$Filter*" -or
                $_.DeviceClass -like "*$Filter*" -or

                (
                    (@($_.InfNames) -join "`n") -match
                    $escapedFilter
                ) -or

                (
                    (@($_.DeviceIDs) -join "`n") -match
                    $escapedFilter
                ) -or

                (
                    (@($_.HardwareIds) -join "`n") -match
                    $escapedFilter
                )
            }
        )
    }

    if ($UpdatesOnly) {

        $result = @(
            $result |
            Where-Object {
                $_.UpdateMatched
            }
        )
    }

    return $result
}


function Sort-DriverInventory {
    param(
        [object[]]$Drivers
    )

    $property = switch ($SortBy) {

        'Provider' {
            'Provider'
        }

        'Version' {
            'Version'
        }

        'Date' {
            'Date'
        }

        'Status' {
            'State'
        }

        'UpdateStatus' {
            'UpdateStatus'
        }

        default {
            'Device'
        }
    }

    return @(
        $Drivers |
        Sort-Object `
            -Property $property, Device `
            -Descending:$Descending
    )
}


# ============================================================================
# Inventory output
# ============================================================================

function Write-DriverInventory {
    param(
        [object[]]$Drivers
    )

    Write-C
    Write-C "$ScriptName $ScriptVersion" $C.Title
    Write-C

    if ($Drivers.Count -eq 0) {

        Write-C `
            'No matching drivers found.' `
            $C.Warning

        return
    }

    $consoleWidth = Get-ConsoleWidth

    # Base widths.
    $nameWidth = 38
    $providerWidth = 18
    $versionWidth = 16
    $dateWidth = 10
    $countWidth = 5
    $ageWidth = 8
    $updateWidth = 15

    $fixedWidth =
    $providerWidth +
    $versionWidth +
    $dateWidth +
    $countWidth +
    $ageWidth +
    $updateWidth +
    12

    $availableForName =
    $consoleWidth - $fixedWidth

    if ($availableForName -ge 24) {
        $nameWidth = [Math]::Min(
            55,
            $availableForName
        )
    }

    $separator =
    ('-' * $nameWidth) + '  ' +
    ('-' * $providerWidth) + '  ' +
    ('-' * $versionWidth) + '  ' +
    ('-' * $dateWidth) + '  ' +
    ('-' * $countWidth) + '  ' +
    ('-' * $ageWidth) + '  ' +
    ('-' * $updateWidth)

    Write-C $separator $C.Muted

    Write-C `
    (Format-Cell 'Name' $nameWidth) `
        $C.Header `
        -NoNewline

    Write-C '  ' -NoNewline

    Write-C `
    (Format-Cell 'Provider' $providerWidth) `
        $C.Header `
        -NoNewline

    Write-C '  ' -NoNewline

    Write-C `
    (Format-Cell 'Version' $versionWidth) `
        $C.Header `
        -NoNewline

    Write-C '  ' -NoNewline

    Write-C `
    (Format-Cell 'Date' $dateWidth) `
        $C.Header `
        -NoNewline

    Write-C '  ' -NoNewline

    Write-C `
    (Format-Cell 'Count' $countWidth -Right) `
        $C.Header `
        -NoNewline

    Write-C '  ' -NoNewline

    Write-C `
    (Format-Cell 'Age' $ageWidth) `
        $C.Header `
        -NoNewline

    Write-C '  ' -NoNewline

    Write-C `
    (Format-Cell 'Update' $updateWidth) `
        $C.Header

    Write-C $separator $C.Muted

    foreach ($driver in $Drivers) {

        $dateText = if ($driver.Date) {
            $driver.Date.ToString('yyyy-MM-dd')
        }
        else {
            'Unknown'
        }

        $ageColor =
        Get-AgeColor $driver.State

        $updateColor =
        Get-UpdateStatusColor $driver.UpdateStatus

        Write-C `
        (Format-Cell $driver.Device $nameWidth) `
            $C.Accent `
            -NoNewline

        Write-C '  ' -NoNewline

        Write-C `
        (Format-Cell $driver.Provider $providerWidth) `
            $C.Normal `
            -NoNewline

        Write-C '  ' -NoNewline

        Write-C `
        (Format-Cell $driver.Version $versionWidth) `
            $C.Normal `
            -NoNewline

        Write-C '  ' -NoNewline

        Write-C `
        (Format-Cell $dateText $dateWidth) `
            $ageColor `
            -NoNewline

        Write-C '  ' -NoNewline

        $countColor = if ($driver.Instances -gt 1) {
            $C.Warning
        }
        else {
            $C.Muted
        }

        Write-C `
        (Format-Cell $driver.Instances $countWidth -Right) `
            $countColor `
            -NoNewline

        Write-C '  ' -NoNewline

        Write-C `
        (Format-Cell $driver.State $ageWidth) `
            $ageColor `
            -NoNewline

        Write-C '  ' -NoNewline

        Write-C `
        (Format-Cell $driver.UpdateStatus $updateWidth) `
            $updateColor
    }

    $instances = (
        $Drivers |
        Measure-Object `
            -Property Instances `
            -Sum
    ).Sum

    Write-C

    Write-C (
        'Unique drivers: {0}   Device instances: {1}' -f
        $Drivers.Count,
        $instances
    ) $C.Normal

    Write-C (
        'Recent: {0}   Aging: {1}   Old: {2}   System: {3}   Unknown: {4}' -f
        @(
            $Drivers |
            Where-Object State -eq 'Recent'
        ).Count,
        @(
            $Drivers |
            Where-Object State -eq 'Aging'
        ).Count,
        @(
            $Drivers |
            Where-Object State -eq 'Old'
        ).Count,
        @(
            $Drivers |
            Where-Object State -eq 'System'
        ).Count,
        @(
            $Drivers |
            Where-Object State -eq 'Unknown'
        ).Count
    ) $C.Normal
}


# ============================================================================
# Windows Update output
# ============================================================================

function Write-WindowsUpdateTable {
    param(
        [object[]]$Drivers,
        [object[]]$Updates
    )

    Write-C
    Write-C 'Windows Update Driver Scan' $C.Title
    Write-C

    if (-not $script:Scan.UpdateScanCompleted) {

        Write-C `
            'Windows Update scan failed.' `
            $C.Error

        if ($script:Scan.UpdateScanError) {

            Write-C `
                $script:Scan.UpdateScanError `
                $C.Error
        }

        return
    }

    if ($Updates.Count -eq 0) {

        Write-C `
            'No applicable driver packages were reported by the configured Windows Update source.' `
            $C.Good

        return
    }

    $matchedDrivers = @(
        $Drivers |
        Where-Object {
            $_.UpdateMatched
        }
    )

    if ($matchedDrivers.Count -gt 0) {

        $consoleWidth = Get-ConsoleWidth

        $nameWidth = 38
        $installedWidth = 16
        $availableWidth = 16
        $providerWidth = 18
        $statusWidth = 15

        $fixed =
        $installedWidth +
        $availableWidth +
        $providerWidth +
        $statusWidth +
        8

        $possibleName =
        $consoleWidth - $fixed

        if ($possibleName -ge 24) {

            $nameWidth = [Math]::Min(
                55,
                $possibleName
            )
        }

        $separator =
        ('-' * $nameWidth) + '  ' +
        ('-' * $installedWidth) + '  ' +
        ('-' * $availableWidth) + '  ' +
        ('-' * $providerWidth) + '  ' +
        ('-' * $statusWidth)

        Write-C $separator $C.Muted

        Write-C `
        (Format-Cell 'Name' $nameWidth) `
            $C.Header `
            -NoNewline

        Write-C '  ' -NoNewline

        Write-C `
        (Format-Cell 'Installed' $installedWidth) `
            $C.Header `
            -NoNewline

        Write-C '  ' -NoNewline

        Write-C `
        (Format-Cell 'Available' $availableWidth) `
            $C.Header `
            -NoNewline

        Write-C '  ' -NoNewline

        Write-C `
        (Format-Cell 'Provider' $providerWidth) `
            $C.Header `
            -NoNewline

        Write-C '  ' -NoNewline

        Write-C `
        (Format-Cell 'Status' $statusWidth) `
            $C.Header

        Write-C $separator $C.Muted

        foreach ($driver in $matchedDrivers) {

            $availableVersion = if ($driver.UpdateVersion) {
                $driver.UpdateVersion
            }
            else {
                'Unknown'
            }

            Write-C `
            (Format-Cell $driver.Device $nameWidth) `
                $C.Accent `
                -NoNewline

            Write-C '  ' -NoNewline

            Write-C `
            (Format-Cell $driver.Version $installedWidth) `
                $C.Normal `
                -NoNewline

            Write-C '  ' -NoNewline

            Write-C `
            (Format-Cell $availableVersion $availableWidth) `
                $C.Title `
                -NoNewline

            Write-C '  ' -NoNewline

            Write-C `
            (Format-Cell $driver.Provider $providerWidth) `
                $C.Normal `
                -NoNewline

            Write-C '  ' -NoNewline

            Write-C `
            (Format-Cell $driver.UpdateStatus $statusWidth) `
            (Get-UpdateStatusColor $driver.UpdateStatus)
        }

        Write-C

        Write-C (
            'Matched packages: {0}' -f
            $matchedDrivers.Count
        ) $C.Normal

        Write-C (
            'Newer: {0}   Same: {1}   Version unknown: {2}   Older offered: {3}' -f
            @(
                $matchedDrivers |
                Where-Object UpdateStatus -eq 'Update'
            ).Count,
            @(
                $matchedDrivers |
                Where-Object UpdateStatus -eq 'Same'
            ).Count,
            @(
                $matchedDrivers |
                Where-Object UpdateStatus -eq 'Version unknown'
            ).Count,
            @(
                $matchedDrivers |
                Where-Object UpdateStatus -eq 'Older offered'
            ).Count
        ) $C.Normal
    }
    else {

        Write-C (
            '{0} package(s) were returned, but none could be confidently matched to the displayed installed drivers.' -f
            $Updates.Count
        ) $C.Warning
    }

    $unmatchedUpdates = @(
        $Updates |
        Where-Object {
            -not $_.Matched
        }
    )

    if ($unmatchedUpdates.Count -gt 0) {

        Write-C
        Write-C (
            'Unmatched Windows Update packages: {0}' -f
            $unmatchedUpdates.Count
        ) $C.Warning

        foreach ($update in $unmatchedUpdates) {
            Write-C "  * $($update.Title)" $C.Accent
        }
    }
}


function Write-VerboseWindowsUpdateDetails {
    param(
        [object[]]$Updates
    )

    if ($Updates.Count -eq 0) {
        return
    }

    Write-C
    Write-C 'Windows Update Details' $C.Title

    for (
        $i = 0;
        $i -lt $Updates.Count;
        $i++
    ) {

        $update = $Updates[$i]

        Write-C

        Write-C (
            '[{0}/{1}] {2}' -f
            ($i + 1),
            $Updates.Count,
            $update.Title
        ) $C.Accent

        Write-C ('-' * 100) $C.Muted

        $details = [ordered]@{
            Version           =
            Get-DisplayValue $update.DriverVersion

            'Version source'  =
            Get-DisplayValue $update.DriverVersionSource

            'Driver date'     =
            if ($update.DriverDate) {
                $update.DriverDate.ToString('yyyy-MM-dd')
            }
            else {
                'Not provided'
            }

            Provider          =
            Get-DisplayValue $update.DriverProvider

            Manufacturer      =
            Get-DisplayValue $update.DriverManufacturer

            Model             =
            Get-DisplayValue $update.DriverModel

            Class             =
            Get-DisplayValue $update.DriverClass

            'Update ID'       =
            Get-DisplayValue $update.UpdateID

            Revision          =
            $update.RevisionNumber

            Categories        =
            if ($update.Categories.Count -gt 0) {
                $update.Categories -join ', '
            }
            else {
                'Not provided'
            }

            'KB articles'     =
            if ($update.KBArticleIDs.Count -gt 0) {
                $update.KBArticleIDs -join ', '
            }
            else {
                'Not provided'
            }

            Downloaded        =
            if ($update.IsDownloaded) {
                'Yes'
            }
            else {
                'No'
            }

            'Reboot required' =
            if ($update.RebootRequired) {
                'Yes'
            }
            else {
                'No'
            }

            'EULA accepted'   =
            if ($update.EulaAccepted) {
                'Yes'
            }
            else {
                'No'
            }

            Mandatory         =
            if ($update.IsMandatory) {
                'Yes'
            }
            else {
                'No'
            }

            'Auto selected'   =
            if ($update.AutoSelect) {
                'Yes'
            }
            else {
                'No'
            }

            'Hardware IDs'    =
            if ($update.HardwareIds.Count -gt 0) {
                $update.HardwareIds -join ', '
            }
            else {
                'Not provided'
            }

            Matched           =
            if ($update.Matched) {
                'Yes'
            }
            else {
                'No'
            }

            'Matched device'  =
            Get-DisplayValue $update.MatchedDevice

            'Match score'     =
            $update.MatchScore

            'Match reason'    =
            Get-DisplayValue $update.MatchReason
        }

        foreach ($key in $details.Keys) {

            Write-C `
            ($key.PadRight(20)) `
                $C.Muted `
                -NoNewline

            Write-C `
            ([string]$details[$key]) `
                $C.Accent
        }

        if ($update.Description) {

            Write-C
            Write-C 'Description' $C.Muted

            Write-C `
                $update.Description.Trim() `
                $C.Normal
        }
    }
}


# ============================================================================
# Diagnostics
# ============================================================================

function Write-DriverCheckDiagnostics {
    param(
        $Environment,

        [object[]]$Drivers,

        [object[]]$Updates
    )

    Write-C
    Write-C 'Diagnostics' $C.Title
    Write-C ('-' * 80) $C.Muted

    $rows = [System.Collections.Generic.List[object]]::new()

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Computer'
            Value = $Environment.ComputerName
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Manufacturer'
            Value = $Environment.Manufacturer
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Model'
            Value = $Environment.Model
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Operating system'
            Value = $Environment.OS
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'OS version'
            Value = $Environment.OSVersion
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'OS build'
            Value = $Environment.OSBuild
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'PowerShell'
            Value = $Environment.PowerShell
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'PowerShell edition'
            Value = $Environment.PSEdition
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Administrator'
            Value = $Environment.IsAdministrator
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Hardware ID method'
            Value = $script:Scan.HardwareIdMethod
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'PnP entities'
            Value = $script:Scan.HardwareIdEntities
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Hardware IDs'
            Value = $script:Scan.HardwareIdEntries
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Raw driver instances'
            Value = $script:Scan.InventoryRawInstances
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Unique inventory'
            Value = $script:Scan.InventoryUnique
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Inventory time'
            Value = if ($null -ne $script:Scan.InventorySeconds) {
                '{0:N2}s' -f $script:Scan.InventorySeconds
            }
            else {
                $null
            }
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Update source'
            Value = $Environment.UpdateSource
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'WSUS policy'
            Value = $Environment.UseWUServer
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'WSUS server'
            Value = $Environment.WUServer
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Update scan requested'
            Value = $script:Scan.UpdateScanRequested
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Update scan completed'
            Value = $script:Scan.UpdateScanCompleted
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Update search time'
            Value = if ($null -ne $script:Scan.UpdateSearchSeconds) {
                '{0:N2}s' -f $script:Scan.UpdateSearchSeconds
            }
            else {
                $null
            }
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Matching time'
            Value = if ($null -ne $script:Scan.MatchingSeconds) {
                '{0:N2}s' -f $script:Scan.MatchingSeconds
            }
            else {
                $null
            }
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'WU packages returned'
            Value = $Updates.Count
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Matched packages'
            Value = $script:Scan.MatchedUpdates
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Unmatched packages'
            Value = $script:Scan.UnmatchedUpdates
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Newer updates'
            Value = $script:Scan.NewerUpdates
        }
    )

    $rows.Add(
        [pscustomobject]@{
            Name  = 'Displayed drivers'
            Value = $Drivers.Count
        }
    )

    foreach ($row in $rows) {

        Write-C `
        ($row.Name.PadRight(24)) `
            $C.Muted `
            -NoNewline

        Write-C `
        (Get-DisplayValue $row.Value) `
            $C.Accent
    }

    if ($script:Scan.UpdateScanError) {

        Write-C `
        ('Update scan error'.PadRight(24)) `
            $C.Muted `
            -NoNewline

        Write-C `
            $script:Scan.UpdateScanError `
            $C.Error
    }
}


# ============================================================================
# Export
# ============================================================================

function Resolve-ExportPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolved =
    [Environment]::ExpandEnvironmentVariables(
        $Path
    )

    if (-not [IO.Path]::IsPathRooted($resolved)) {

        $resolved = Join-Path `
        (Get-Location) `
            $resolved
    }

    $resolved =
    [IO.Path]::GetFullPath($resolved)

    $parent =
    Split-Path `
        -Parent `
        $resolved

    if (
        $parent -and
        -not (Test-Path -LiteralPath $parent)
    ) {

        New-Item `
            -ItemType Directory `
            -Path $parent `
            -Force |
        Out-Null
    }

    return $resolved
}


function Export-DriverCheckCsv {
    param(
        [object[]]$Drivers,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolved =
    Resolve-ExportPath $Path

    $Drivers |
    Select-Object `
    @{N = 'Name'; E = { $_.Device } },
    Provider,
    Manufacturer,
    Version,
    @{N = 'DriverDate'; E = {
            if ($_.Date) {
                $_.Date.ToString('yyyy-MM-dd')
            }
        }
    },
    @{N = 'AgeStatus'; E = { $_.State } },
    DeviceClass,
    @{N = 'InfNames'; E = {
            $_.InfNames -join ';'
        }
    },
    IsSigned,
    Instances,
    @{N = 'DeviceIDs'; E = {
            $_.DeviceIDs -join ';'
        }
    },
    @{N = 'HardwareIds'; E = {
            $_.HardwareIds -join ';'
        }
    },
    UpdateStatus,
    UpdateVersion,
    UpdateVersionSource,
    UpdateProvider,
    UpdateTitle,
    UpdateID,
    MatchScore,
    MatchReason |
    Export-Csv `
        -LiteralPath $resolved `
        -NoTypeInformation `
        -Encoding UTF8

    return $resolved
}


function Export-DriverCheckJson {
    param(
        [object[]]$Drivers,
        [object[]]$Updates,
        $Environment,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolved =
    Resolve-ExportPath $Path

    $report = [ordered]@{
        Application   = [ordered]@{
            Name    = $ScriptName
            Version = $ScriptVersion
        }

        Scan          = $script:Scan

        Warnings      = $script:Warnings.ToArray()

        Environment   = $Environment

        Drivers       = $Drivers

        WindowsUpdate = [ordered]@{
            Packages          = $Updates

            UnmatchedPackages = @(
                $Updates |
                Where-Object {
                    -not $_.Matched
                }
            )
        }
    }

    $json =
    $report |
    ConvertTo-Json -Depth 10

    Set-Content `
        -LiteralPath $resolved `
        -Value $json `
        -Encoding UTF8

    return $resolved
}


# ============================================================================
# Main
# ============================================================================

$mainTimer =
[Diagnostics.Stopwatch]::StartNew()

$exitCode = 0

try {

    Show-DriverCheckProgress `
        1 `
        'Initialization' `
        'Collecting environment information...'

    $environment =
    Get-EnvironmentInfo

    # Always build and match against the COMPLETE inventory first.
    #
    # Display filters are intentionally applied only after matching so that
    # -Filter, -OldOnly, or -ThirdPartyOnly cannot hide potential matches.
    $allDrivers = @(
        Get-DriverInventory
    )

    $updates = @()

    if ($CheckUpdates) {

        try {

            $updates = @(
                Get-WindowsDriverUpdates
            )

            $allDrivers = @(
                Add-WindowsUpdateMatches `
                    -Drivers $allDrivers `
                    -Updates $updates
            )
        }
        catch {

            $script:Scan.UpdateScanCompleted = $false
            $script:Scan.UpdateScanError =
            $_.Exception.Message

            Add-DriverCheckWarning (
                'Windows Update scan failed: {0}' -f
                $_.Exception.Message
            )

            foreach ($driver in $allDrivers) {

                $driver.UpdateStatus =
                Get-DriverUpdateStatus `
                    -Installed $driver.Version `
                    -Available $null `
                    -Matched $false `
                    -ScanState 'Failed'
            }
        }
    }

    Show-DriverCheckProgress `
        94 `
        'Output' `
        'Applying filters and sorting...'

    $displayedDrivers = @(
        Select-DisplayedDrivers $allDrivers
    )

    $displayedDrivers = @(
        Sort-DriverInventory $displayedDrivers
    )

    if (-not $UpdatesOnly) {

        Write-DriverInventory `
            $displayedDrivers
    }

    if ($CheckUpdates) {

        Write-WindowsUpdateTable `
            -Drivers $allDrivers `
            -Updates $updates
    }

    if ($VerboseUpdates) {

        Write-VerboseWindowsUpdateDetails `
            $updates
    }

    if ($Diagnostics) {

        Write-DriverCheckDiagnostics `
            -Environment $environment `
            -Drivers $displayedDrivers `
            -Updates $updates
    }

    if ($CsvPath) {

        try {

            $exportedCsv =
            Export-DriverCheckCsv `
                -Drivers $displayedDrivers `
                -Path $CsvPath

            Write-C
            Write-C "CSV export: $exportedCsv" $C.Accent
        }
        catch {

            $script:ExportFailure = $true

            Add-DriverCheckWarning (
                'CSV export failed: {0}' -f
                $_.Exception.Message
            )
        }
    }

    if ($JsonPath) {

        try {

            $exportedJson =
            Export-DriverCheckJson `
                -Drivers $displayedDrivers `
                -Updates $updates `
                -Environment $environment `
                -Path $JsonPath

            Write-C
            Write-C "JSON export: $exportedJson" $C.Accent
        }
        catch {

            $script:ExportFailure = $true

            Add-DriverCheckWarning (
                'JSON export failed: {0}' -f
                $_.Exception.Message
            )
        }
    }

    if ($script:Warnings.Count -gt 0) {

        Write-C
        Write-C 'Warnings' $C.Warning

        foreach ($warning in $script:Warnings) {
            Write-C "  - $warning" $C.Warning
        }
    }

    # ------------------------------------------------------------------------
    # Exit-code precedence
    #
    # 1 = fatal/export failure
    # 3 = requested WUA scan failed
    # 2 = newer matched updates found
    # 0 = success
    # ------------------------------------------------------------------------

    if ($script:ExportFailure) {
        $exitCode = 1
    }
    elseif (
        $CheckUpdates -and
        -not $script:Scan.UpdateScanCompleted
    ) {
        $exitCode = 3
    }
    elseif (
        $CheckUpdates -and
        $script:Scan.NewerUpdates -gt 0
    ) {
        $exitCode = 2
    }
    else {
        $exitCode = 0
    }

    $script:Scan.Completed = Get-Date

    Complete-DriverCheckProgress

    $mainTimer.Stop()

    Write-C

    $completionColor = switch ($exitCode) {
        0 { $C.Good }
        2 { $C.Warning }
        default { $C.Error }
    }

    Write-C (
        'Completed in {0:N2}s   Exit code: {1}' -f
        $mainTimer.Elapsed.TotalSeconds,
        $exitCode
    ) $completionColor
}
catch {

    Complete-DriverCheckProgress

    $mainTimer.Stop()

    Write-C
    Write-C "$ScriptName failed." $C.Error
    Write-C $_.Exception.Message $C.Error

    if ($_.ScriptStackTrace) {

        Write-C
        Write-C 'Stack trace' $C.Muted
        Write-C $_.ScriptStackTrace $C.Muted
    }

    $exitCode = 1
}

if (-not $NoExit) {
    exit $exitCode
}