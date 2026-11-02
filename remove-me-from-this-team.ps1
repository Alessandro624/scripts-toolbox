#requires -Version 5.1

<#
.SYNOPSIS
Leave one Microsoft Team as the interactively signed-in user.
.EXAMPLE
.\remove-me-from-this-team.ps1 -TeamName 'Example team' -WhatIf
.EXAMPLE
.\remove-me-from-this-team.ps1 -GroupId '11111111-1111-1111-1111-111111111111'
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Name')]

param(
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'Name')]
    [ValidateNotNullOrEmpty()]
    [string]$TeamName,

    [Parameter(Mandatory, ParameterSetName = 'Id')]
    [guid]$GroupId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable -Name MicrosoftTeams)) {
    throw 'Install the dependency first: Install-Module MicrosoftTeams -Scope CurrentUser'
}
Import-Module MicrosoftTeams -ErrorAction Stop

$connected = $false

try {
    # WhatIf still authenticates and reads membership to identify the exact target.
    $sessions = @(Connect-MicrosoftTeams -WhatIf:$false -Confirm:$false -ErrorAction Stop)
    $connected = $true

    if ($sessions.Count -ne 1 -or $null -eq $sessions[0].PSObject.Properties['Account']) {
        throw 'Unable to identify a single signed-in user. No membership was changed.'
    }

    $account = [string]$sessions[0].Account
    if ([string]::IsNullOrWhiteSpace($account) -or $account -notmatch '@') {
        throw 'Interactive user authentication is required. No membership was changed.'
    }

    $teams = @(Get-Team -User $account -ErrorAction Stop)
    if ($PSCmdlet.ParameterSetName -eq 'Id') {
        $matches = @($teams | Where-Object { [string]$_.GroupId -eq $GroupId.ToString() })
    }
    else {
        $matches = @($teams | Where-Object { $_.DisplayName -eq $TeamName })
    }

    if ($matches.Count -eq 0) {
        throw 'No matching team membership found for the signed-in user.'
    }

    if ($matches.Count -gt 1) {
        $ids = ($matches | ForEach-Object { [string]$_.GroupId }) -join ', '
        throw "Multiple teams have that name. Select one using -GroupId. Matching IDs: $ids"
    }

    $team = $matches[0]
    $members = @(Get-TeamUser -GroupId $team.GroupId -ErrorAction Stop)
    $self = @($members | Where-Object { $_.User -eq $account })

    if ($self.Count -ne 1) {
        throw 'Cannot verify the signed-in user in this team. No membership was changed.'
    }

    $owners = @($members | Where-Object { $_.Role -eq 'Owner' })

    if ($self[0].Role -eq 'Owner' -and $owners.Count -le 1) {
        throw 'You are the last owner. Assign another owner before leaving the team.'
    }

    $target = "'$($team.DisplayName)' ($($team.GroupId)), account $account"

    if ($PSCmdlet.ShouldProcess($target, 'Remove your membership from the team and its Microsoft 365 group')) {
        Remove-TeamUser -GroupId $team.GroupId -User $account -ErrorAction Stop
        Write-Output "Removal requested for $target. Teams may take time to reflect the change."
    }
}
finally {
    if ($connected) {
        try {
            & {
                $WhatIfPreference = $false
                Disconnect-MicrosoftTeams -ErrorAction Stop | Out-Null
            }
        }
        catch {
            Write-Warning "Could not disconnect the Teams session: $($_.Exception.Message)"
        }
    }
}
