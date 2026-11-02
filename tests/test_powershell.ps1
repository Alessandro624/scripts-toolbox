# Run with Windows PowerShell 5.1 or PowerShell 7 on Windows.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
$tokens = $null
$parseErrors = $null

foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.ps1') {
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors.Count) { throw ($parseErrors.Message -join "`n") }
}

$auditText = Get-Content (Join-Path $root 'PC-Maintenance-Audit.ps1') -Raw
$ast = [System.Management.Automation.Language.Parser]::ParseInput($auditText, [ref]$tokens, [ref]$parseErrors)

# Load helpers without executing machine-wide scans or writing real snapshots.
foreach ($function in $ast.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ('script-tests-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $workspace | Out-Null

try {
    $script:MeasurementWarnings = 0

    $project = Join-Path $workspace 'project'

    New-Item -ItemType Directory -Path (Join-Path $project 'node_modules\nested\.venv') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $project '.pytest_cache') -Force | Out-Null

    $inventory = Find-ProjectArtifactsFast -Roots @($project) -IndividualNames @('node_modules', '.venv') -AggregateNames @('.pytest_cache')

    Assert-True ($inventory.Individual.Count -eq 1) 'Discovery must prune nested dependencies.'
    Assert-True ($inventory.Aggregate.Count -eq 1) 'Cache discovery failed.'

    $empty = Find-ProjectArtifactsFast -Roots @() -IndividualNames @('node_modules') -AggregateNames @('.pytest_cache')

    Assert-True ($empty.Individual.Count -eq 0) 'Empty roots must work.'

    $result = Invoke-CapturedCommand { cmd.exe /d /c exit 7 }

    Assert-True ($result -like 'ERROR:*7*') 'Native exit codes must be reported.'

    # Exercise the report/snapshot pipeline with deterministic collectors.
    $marker = 'Write-Host "PC Maintenance Audit v$ScriptVersion"'
    $mocks = @'
function Get-Volume { param($DriveLetter)
    [pscustomobject]@{Size=100GB;SizeRemaining=50GB;HealthStatus='Healthy';OperationalStatus='OK'}
}
function Get-PackageManagerCacheDefinitions { @() }
function Get-KnownVHDX { @() }
function Test-CommandAvailable { param($Name) $false }
'@

    $isolated = [scriptblock]::Create($auditText.Replace($marker, $mocks + "`n" + $marker))
    $out = Join-Path $workspace 'audit-output'
    & $isolated -ProjectRoots @() -OutputDirectory $out *> $null
    $snapshots = @(Get-ChildItem (Join-Path $out 'snapshots') -Filter '*.json')

    Assert-True ($snapshots.Count -eq 1) 'Audit must write a snapshot.'

    $snapshot = Get-Content $snapshots[0].FullName -Raw | ConvertFrom-Json

    Assert-True ($snapshot.InventorySource -eq 'FullDiscovery') 'Discovery must be the default.'

    & $isolated -ProjectRoots @() -OutputDirectory $out -ReuseInventory *> $null

    $latest = Get-ChildItem (Join-Path $out 'snapshots') | Sort-Object Name | Select-Object -Last 1
    $snapshot = Get-Content $latest.FullName -Raw | ConvertFrom-Json

    Assert-True ($snapshot.InventorySource -eq 'PreviousSnapshot') 'Explicit inventory reuse failed.'

    & $isolated -ProjectRoots @($project) -OutputDirectory $out *> $null

    $latest = Get-ChildItem (Join-Path $out 'snapshots') | Sort-Object Name | Select-Object -Last 1
    $snapshot = Get-Content $latest.FullName -Raw | ConvertFrom-Json

    Assert-True ($null -eq $snapshot.Diff.Disk) 'Changed project roots must start a new baseline.'

    $dispatcher = Join-Path $root 'PC-Maintenance-Dispatcher.ps1'
    $dryOutput = Join-Path $workspace 'dry-output'

    $hostExe = (Get-Process -Id $PID).Path

    & $hostExe -NoProfile -ExecutionPolicy Bypass -File $dispatcher -DryRun -OutputDirectory $dryOutput

    Assert-True ($LASTEXITCODE -eq 0) 'Dispatcher dry run failed.'
    Assert-True (-not (Test-Path $dryOutput)) 'Dry run must not create directories.'

    # Use a disposable dispatcher with a fixed first-of-month date and failing audit.
    $dispatcherCopy = Join-Path $workspace 'PC-Maintenance-Dispatcher.ps1'
    $dispatchText = (Get-Content $dispatcher -Raw).Replace('$now = Get-Date', '$now = [datetime]"2026-11-01"')

    Set-Content $dispatcherCopy $dispatchText
    Set-Content (Join-Path $workspace 'PC-Maintenance-Audit.ps1') 'throw "Expected test failure"'

    & $hostExe -NoProfile -ExecutionPolicy Bypass -File $dispatcherCopy -OutputDirectory (Join-Path $workspace 'failure-output')

    Assert-True ($LASTEXITCODE -eq 1) 'Dispatcher must propagate audit failure.'
    $global:LASTEXITCODE = 0
    Write-Host 'PowerShell regression tests passed.'
}
finally {
    # The target is the unique temporary directory created above.
    $resolved = [System.IO.Path]::GetFullPath($workspace)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'

    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
