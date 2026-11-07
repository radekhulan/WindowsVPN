#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param([Parameter(Mandatory = $true)][string]$TrialDirectory, [switch]$Apply)
. (Join-Path $PSScriptRoot 'Common.ps1')
$state = Get-Content -LiteralPath (Join-Path $TrialDirectory 'state.json') -Raw | ConvertFrom-Json
if (Test-Path -LiteralPath (Join-Path $TrialDirectory 'restored.ok')) { throw 'Trial was rolled back; cannot commit.' }
if (Test-Path -LiteralPath (Join-Path $TrialDirectory 'commit.ok')) { Write-Output 'Already committed.'; return }
if ((Get-Date).ToUniversalTime() -ge ([DateTime]::Parse($state.DeadlineUtc).ToUniversalTime().AddSeconds(-60))) { throw 'Too close to rollback deadline. Allow rollback and start a fresh trial.' }
$task = Get-ScheduledTask -TaskName $state.TaskName -ErrorAction Stop
if ([string]$task.State -eq 'Running') { throw 'Rollback is running. Do not commit.' }
if (-not $Apply) { Write-Output 'Plan: commit tested RSC settings and cancel the armed rollback task.'; return }
Assert-Administrator
if ($PSCmdlet.ShouldProcess($state.TaskName, 'Accept tested settings and disarm rollback')) {
    Disable-ScheduledTask -TaskName $state.TaskName | Out-Null
    if ([string](Get-ScheduledTask -TaskName $state.TaskName).State -eq 'Running') { throw 'Rollback started concurrently; commit refused.' }
    Write-VpnUtf8 (Join-Path $TrialDirectory 'commit.ok') ([DateTime]::UtcNow.ToString('o'))
    Unregister-ScheduledTask -TaskName $state.TaskName -Confirm:$false
    Write-Output 'Trial committed. Recheck global and adapter RSC after a planned reboot.'
}
