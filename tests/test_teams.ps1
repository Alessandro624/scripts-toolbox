# All Teams commands are mocked; no authentication or remote changes occur.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'remove-me-from-this-team.ps1'
$tokens = $null
$parseErrors = $null

[void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

if ($parseErrors.Count) { throw ($parseErrors.Message -join "`n") }

$global:TeamsScriptTestState = @{}

function Get-Module { param($Name, [switch]$ListAvailable) 'MockTeamsModule' }

function Import-Module { [CmdletBinding()]param($Name) }

function Connect-MicrosoftTeams {
    [CmdletBinding(SupportsShouldProcess)]param()
    [pscustomobject]@{Account = $global:TeamsScriptTestState.account }
}

function Get-Team { [CmdletBinding()]param($User) $global:TeamsScriptTestState.teams }

function Get-TeamUser { [CmdletBinding()]param($GroupId) $global:TeamsScriptTestState.members }

function Remove-TeamUser {
    [CmdletBinding()]param($GroupId, $User)
    $global:TeamsScriptTestState.removed += [pscustomobject]@{GroupId = $GroupId; User = $User }
    if ($global:TeamsScriptTestState.failRemoval) { throw 'Simulated API failure' }
}

function Disconnect-MicrosoftTeams { [CmdletBinding()]param() $global:TeamsScriptTestState.disconnects++ }

function Assert-True($Condition, $Message) { if (-not $Condition) { throw $Message } }

function Reset-Fixture {
    $global:TeamsScriptTestState.account = 'person@example.com'
    $global:TeamsScriptTestState.teams = @([pscustomobject]@{
            DisplayName = 'Example'; GroupId = '11111111-1111-1111-1111-111111111111'
        })
    $global:TeamsScriptTestState.members = @([pscustomobject]@{User = $global:TeamsScriptTestState.account; Role = 'Member' })
    $global:TeamsScriptTestState.removed = @()
    $global:TeamsScriptTestState.disconnects = 0
    $global:TeamsScriptTestState.failRemoval = $false
}

function Assert-Rejected([scriptblock]$Action, [string]$Expected) {
    $message = ''
    try { & $Action } catch { $message = $_.Exception.Message }

    Assert-True ($message -like $Expected) "Expected rejection '$Expected', got '$message'."
    Assert-True ($global:TeamsScriptTestState.removed.Count -eq 0) 'Rejected requests must not remove membership.'
    Assert-True ($global:TeamsScriptTestState.disconnects -eq 1) 'Session must be disconnected after rejection.'
}

try {
    Reset-Fixture

    & $scriptPath -TeamName Example -WhatIf

    Assert-True ($global:TeamsScriptTestState.removed.Count -eq 0) 'WhatIf must not remove membership.'
    Assert-True ($global:TeamsScriptTestState.disconnects -eq 1) 'WhatIf must clean up its session.'

    Reset-Fixture

    & $scriptPath -TeamName Example -Confirm:$false

    Assert-True ($global:TeamsScriptTestState.removed.Count -eq 1) 'Expected exactly one removal.'
    Assert-True ($global:TeamsScriptTestState.removed[0].User -eq $global:TeamsScriptTestState.account) 'Only the signed-in account may be removed.'

    Reset-Fixture

    $global:TeamsScriptTestState.teams += [pscustomobject]@{DisplayName = 'Example'; GroupId = '22222222-2222-2222-2222-222222222222' }

    Assert-Rejected { & $scriptPath -TeamName Example -Confirm:$false } 'Multiple teams*'

    & $scriptPath -GroupId '22222222-2222-2222-2222-222222222222' -Confirm:$false

    Assert-True ($global:TeamsScriptTestState.removed[0].GroupId -eq '22222222-2222-2222-2222-222222222222') 'GroupId must select the exact team.'

    Reset-Fixture

    Assert-Rejected { & $scriptPath -TeamName Exam -Confirm:$false } 'No matching*'

    Reset-Fixture

    $global:TeamsScriptTestState.members[0].Role = 'Owner'

    Assert-Rejected { & $scriptPath -TeamName Example -Confirm:$false } 'You are the last owner*'

    Reset-Fixture

    $global:TeamsScriptTestState.account = ''

    Assert-Rejected { & $scriptPath -TeamName Example -Confirm:$false } 'Interactive user authentication*'

    Reset-Fixture

    $global:TeamsScriptTestState.members = @()

    Assert-Rejected { & $scriptPath -TeamName Example -Confirm:$false } 'Cannot verify*'

    Reset-Fixture

    $global:TeamsScriptTestState.failRemoval = $true

    $caught = $false

    try { & $scriptPath -TeamName Example -Confirm:$false } catch { $caught = $true }

    Assert-True $caught 'API errors must propagate.'
    Assert-True ($global:TeamsScriptTestState.disconnects -eq 1) 'API errors must not prevent disconnect.'

    Write-Host 'Teams regression tests passed.'
}
finally { Remove-Variable -Name TeamsScriptTestState -Scope Global -ErrorAction SilentlyContinue }

