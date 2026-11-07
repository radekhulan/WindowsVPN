#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param([string]$TrialDirectory = $PSScriptRoot, [switch]$Apply)
$ErrorActionPreference = 'Stop'
$state = Get-Content -LiteralPath (Join-Path $TrialDirectory 'state.json') -Raw | ConvertFrom-Json
if (Test-Path -LiteralPath (Join-Path $TrialDirectory 'commit.ok')) { Write-Output 'Trial committed; no rollback.'; return }
if (Test-Path -LiteralPath (Join-Path $TrialDirectory 'restored.ok')) { Write-Output 'Already restored.'; return }
if (-not (Test-Path -LiteralPath (Join-Path $TrialDirectory 'armed.ok'))) {
    if ($Apply -and $PSCmdlet.ShouldProcess($TrialDirectory, 'Write harmless SYSTEM execution preflight marker only')) {
        $probe = @{ Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; Utc = [DateTime]::UtcNow.ToString('o') }
        [IO.File]::WriteAllText((Join-Path $TrialDirectory 'preflight.json'), ($probe | ConvertTo-Json))
    } else { Write-Output 'Unarmed preflight only; no RSC/NIC changes.' }
    return
}
$adapter = @(Get-NetAdapter | Where-Object { $_.InterfaceGuid.ToString() -eq $state.InterfaceGuid })
if ($adapter.Count -ne 1) { throw 'Original adapter GUID not found. Refuse a different NIC.' }
if (-not $Apply) { Write-Output 'Plan: restore saved global and per-NIC RSC, restart original NIC, unregister rollback task.'; return }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator required.' }
if ($PSCmdlet.ShouldProcess($adapter[0].Name, 'Restore saved RSC settings and restart NIC')) {
    Set-NetOffloadGlobalSetting -ReceiveSegmentCoalescing $state.GlobalRsc
    foreach ($family in @('IPv4', 'IPv6')) {
        $parameters = @{ Name = $adapter[0].Name; NoRestart = $true }
        $parameters[$family] = $true
        $enabled = if ($family -eq 'IPv4') { [bool]$state.IPv4Enabled } else { [bool]$state.IPv6Enabled }
        if ($enabled) { Enable-NetAdapterRsc @parameters } else { Disable-NetAdapterRsc @parameters }
    }
    Restart-NetAdapter -Name $adapter[0].Name -Confirm:$false
    [IO.File]::WriteAllText((Join-Path $TrialDirectory 'restored.ok'), [DateTime]::UtcNow.ToString('o'))
    Unregister-ScheduledTask -TaskName $state.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Output 'Original RSC settings restored.'
}
