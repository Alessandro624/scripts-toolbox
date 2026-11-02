#requires -Version 5.1

[CmdletBinding()]

param(
    [switch]$DryRun,
    [string]$OutputDirectory = (Join-Path $HOME "Documents\PC-Maintenance"),
    [string[]]$ProjectRoots
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AuditScript = Join-Path $PSScriptRoot "PC-Maintenance-Audit.ps1"
$LogDirectory = Join-Path $OutputDirectory "logs"

if (-not (Test-Path -LiteralPath $AuditScript -PathType Leaf)) {
    throw "Audit script not found: $AuditScript"
}

$now = Get-Date

if (-not $DryRun -and $now.Day -ne 1) {
    exit 0
}

$mode = switch ($now.Month) {
    3 { "Quarterly" }
    6 { "Full" }
    9 { "Quarterly" }
    12 { "Full" }
    default { "Monthly" }
}

$timestamp = $now.ToString("yyyy-MM-dd_HH-mm-ss-fffffff")

$logPath = Join-Path `
    $LogDirectory `
    "$timestamp-$mode.log"

if ($DryRun) {
    Write-Host "PC Maintenance Dispatcher"
    Write-Host "Date       : $($now.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host "Month      : $($now.Month)"
    Write-Host "Selected   : $mode"
    Write-Host "Audit      : $AuditScript"
    Write-Host "Log        : $logPath"
    Write-Host "Dry run    : Yes"
    exit 0
}

try {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    @(
        "PC MAINTENANCE DISPATCHER"
        "========================="
        ""
        "Start : $($now.ToString('yyyy-MM-dd HH:mm:ss'))"
        "Mode  : $mode"
        ""
    ) |
    Set-Content `
        -LiteralPath $logPath `
        -Encoding UTF8

    $auditParameters = @{ Mode = $mode; OutputDirectory = $OutputDirectory }
    if ($PSBoundParameters.ContainsKey('ProjectRoots')) {
        $auditParameters.ProjectRoots = $ProjectRoots
    }
    & $AuditScript @auditParameters *>&1 |
    Tee-Object `
        -FilePath $logPath `
        -Append |
    Out-Host

    $end = Get-Date

    @(
        ""
        "Dispatcher completed successfully."
        "End : $($end.ToString('yyyy-MM-dd HH:mm:ss'))"
    ) |
    Add-Content `
        -LiteralPath $logPath `
        -Encoding UTF8

    exit 0
}
catch {
    $failure = $_
    Write-Warning "Dispatcher failed: $($failure.Exception.Message)"
    $end = Get-Date

    @(
        ""
        "DISPATCHER FAILURE"
        "------------------"
        "End   : $($end.ToString('yyyy-MM-dd HH:mm:ss'))"
        "Error : $($failure.Exception.Message)"
        ""
        $failure.ScriptStackTrace
    ) |
    Add-Content `
        -LiteralPath $logPath `
        -Encoding UTF8 -ErrorAction SilentlyContinue

    exit 1
}
