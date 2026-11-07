#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$WanAlias,
    [ValidateRange(5, 60)][int]$RollbackMinutes = 10,
    [switch]$RestartAdapter,
    [switch]$Apply
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$adapter = Get-NetAdapter -Name $WanAlias
$rsc = Get-NetAdapterRsc -Name $WanAlias
$global = Get-NetOffloadGlobalSetting
if (-not $Apply) { Write-Output "Plan: global RSC Disabled, WAN IPv6 RSC Disabled, preserve IPv4 RSC; independent SYSTEM rollback in $RollbackMinutes minutes and on boot. NIC restart requires RestartAdapter."; return }
Assert-Administrator
if (-not $RestartAdapter) { throw 'Trial requires explicit RestartAdapter and out-of-band access. Default installation never restarts a NIC.' }
if (@(Get-ScheduledTask -TaskName 'WindowsVPN-RscRollback-*' -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Another RSC trial is armed. Resolve it first.' }
if (-not $PSCmdlet.ShouldProcess($WanAlias, 'Arm independent SYSTEM rollback, disable global/IPv6 RSC and restart WAN NIC')) { return }
$trial = New-VpnBackup 'RscTrial'
$taskName = 'WindowsVPN-RscRollback-' + [guid]::NewGuid().ToString('N')
$deadline = (Get-Date).AddMinutes($RollbackMinutes)
$state = [ordered]@{
    TaskName = $taskName; DeadlineUtc = $deadline.ToUniversalTime().ToString('o')
    InterfaceGuid = $adapter.InterfaceGuid.ToString(); WanAlias = $WanAlias
    GlobalRsc = [string]$global.ReceiveSegmentCoalescing
    IPv4Enabled = [bool]$rsc.IPv4Enabled; IPv6Enabled = [bool]$rsc.IPv6Enabled
}
Write-VpnUtf8 (Join-Path $trial 'state.json') ($state | ConvertTo-Json)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Restore-RscTrial.ps1') -Destination (Join-Path $trial 'Restore-RscTrial.ps1')
Protect-VpnFile (Join-Path $trial 'Restore-RscTrial.ps1')
$powerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if ((Get-AuthenticodeSignature -LiteralPath $powerShell).Status -ne 'Valid') { throw 'Expected signed Windows PowerShell executable.' }
$arguments = '-NoProfile -NonInteractive -File "' + (Join-Path $trial 'Restore-RscTrial.ps1') + '" -Apply'
$action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments
$triggers = @((New-ScheduledTaskTrigger -Once -At $deadline), (New-ScheduledTaskTrigger -AtStartup))
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$null = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $settings -User 'SYSTEM' -RunLevel Highest
$null = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
Start-ScheduledTask -TaskName $taskName
$probePath = Join-Path $trial 'preflight.json'
$probeOk = $false
for ($attempt = 0; $attempt -lt 40; $attempt++) {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $probePath) {
        $probe = Get-Content -LiteralPath $probePath -Raw | ConvertFrom-Json
        $task = Get-ScheduledTask -TaskName $taskName
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        if ($probe.Sid -eq 'S-1-5-18' -and [string]$task.State -ne 'Running' -and $info.LastTaskResult -eq 0) { $probeOk = $true; break }
    }
}
if (-not $probeOk) { throw 'SYSTEM rollback preflight failed. RSC and NIC were not modified; inspect task execution policy/signature errors and the unarmed task.' }
Write-VpnUtf8 (Join-Path $trial 'armed.ok') ([DateTime]::UtcNow.ToString('o'))
Write-Output "Rollback armed. Trial directory: $trial. Deadline UTC: $($state.DeadlineUtc)"
try {
    Set-NetOffloadGlobalSetting -ReceiveSegmentCoalescing Disabled
    Disable-NetAdapterRsc -Name $WanAlias -IPv6 -NoRestart
    Restart-NetAdapter -Name $WanAlias -Confirm:$false
} catch {
    & (Join-Path $trial 'Restore-RscTrial.ps1') -Apply
    throw
}
Write-Output 'Run the same bidirectional IPv4/IPv6 tests. Keep the independent rollback unless the trial is explicitly committed.'
