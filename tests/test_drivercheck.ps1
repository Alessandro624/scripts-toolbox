# Load only function definitions, never the inventory entry point.

$ErrorActionPreference = 'Stop'

Set-StrictMode -Version Latest

$tokens = $null; $errors = $null

$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'DriverCheck.ps1'

$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)

if ($errors.Count) { throw ($errors.Message -join "`n") }

$names = @('Normalize-HardwareId', 'Normalize-Text', 'Get-SafeDate', 'Test-SyntheticDriverDate', 'Get-DriverAgeState', 'Get-VersionFromUpdateTitle', 'Convert-DriverVersionParts', 'Compare-DriverVersion', 'Get-DriverUpdateStatus')

foreach ($name in $names) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $false)

    if (-not $definition) { throw "Missing helper: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Assert-Equal($Actual, $Expected, $Message) { if ($Actual -cne $Expected) { throw "$Message : expected '$Expected', got '$Actual'" } }

Assert-Equal (Compare-DriverVersion '1.1.142.8' '1.1.142.16') 1 'Numeric version order'
Assert-Equal (Compare-DriverVersion '1.2.3' '1.2.3.0') 0 'Trailing zero'
Assert-Equal (Compare-DriverVersion '31.0.101.5000' '31.0.101.4000') -1 'Older package'
Assert-Equal (Compare-DriverVersion 'invalid' '1.2') $null 'Invalid version'
Assert-Equal (Normalize-HardwareId ' acpi\gdix51c0 ') 'ACPI\GDIX51C0' 'Hardware ID'
Assert-Equal (Get-VersionFromUpdateTitle 'Goodix FP - Biometric - 1.1.142.16') '1.1.142.16' 'Title version'
Assert-Equal (Get-DriverAgeState ([datetime]'2006-06-21') 'Microsoft') 'System' 'Inbox date'
Assert-Equal (Get-DriverUpdateStatus '1.0' $null $false 'NotRun') 'Not checked' 'Unscanned'
Assert-Equal (Get-DriverUpdateStatus '1.0' $null $false 'Failed') 'Scan failed' 'Failed scan'
Assert-Equal (Get-DriverUpdateStatus '1.0' $null $false 'Succeeded') 'No update' 'Successful scan'

Write-Output 'DriverCheck: parser and 10 helper checks passed; no system scan performed.'
