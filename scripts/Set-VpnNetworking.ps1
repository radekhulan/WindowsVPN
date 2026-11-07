#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [ValidateSet('WireGuard', 'OpenVPNUdp', 'OpenVPNTcp')][string[]]$Enable = @('WireGuard', 'OpenVPNUdp', 'OpenVPNTcp'),
    [switch]$Apply
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$null = Get-NetAdapter -Name $config.WanAlias -ErrorAction Stop
$prefix = Get-VpnIPv4Network $config.NatPrefix
if ($prefix -ne '10.77.0.0/24') { throw 'This example enforces documented 10.77.0.0/24. Review code before another plan.' }
$nats = @(Get-NetNat)
if ($nats.Count -gt 1) { throw 'More than one WinNAT object exists; nothing deleted.' }
if ($nats.Count -eq 1 -and (Get-VpnIPv4Network $nats[0].InternalIPInterfaceAddressPrefix) -ne $prefix) { throw 'Another WinNAT prefix exists. Never replace it or add a second NAT.' }
$taskName = 'WindowsVPN-Routing'
$destination = Join-Path $env:ProgramData 'WindowsVPN\Routing'
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Write-Output 'Routing task exists; no overwrite. Inspect protected configuration before maintenance updates.'; return }
foreach ($item in $Enable) {
    if (Get-NetFirewallRule -Name ('WindowsVPN-' + $item) -ErrorAction SilentlyContinue) { throw "Firewall rule already exists: $item. Inspect ownership." }
    $port = switch ($item) { 'WireGuard' { $config.WireGuardPort } 'OpenVPNUdp' { $config.OpenVpnUdpPort } 'OpenVPNTcp' { $config.OpenVpnTcpPort } }
    if ([int]$port -lt 1 -or [int]$port -gt 65535) { throw 'Invalid endpoint port.' }
}
if (-not $Apply) { Write-Output "Plan: reuse/create one WinNAT $prefix; endpoint firewall rules; persistent forwarding task. Existing NAT sessions remain untouched."; return }
Assert-Administrator
if (-not $PSCmdlet.ShouldProcess('VPN IPv4 networking', 'Back up state, configure NAT/firewall and register forwarding task')) { return }
$backup = New-VpnBackup 'Networking'
Get-NetIPInterface | Export-Clixml -LiteralPath (Join-Path $backup 'interfaces.xml')
$nats | Export-Clixml -LiteralPath (Join-Path $backup 'nat.xml')
Get-NetRoute | Export-Clixml -LiteralPath (Join-Path $backup 'routes.xml')
Protect-VpnDirectory $destination
Assert-VpnFileTrusted (Join-Path $destination 'network.json')
Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $destination 'network.json')
Protect-VpnFile (Join-Path $destination 'network.json')
foreach ($name in @('Common.ps1', 'Initialize-VpnRouting.ps1')) {
    Assert-VpnFileTrusted (Join-Path $destination $name)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $destination $name)
    Protect-VpnFile (Join-Path $destination $name)
}
if ($nats.Count -eq 0) { $null = New-NetNat -Name $config.NatName -InternalIPInterfaceAddressPrefix $prefix }
foreach ($item in $Enable) {
    $port = switch ($item) { 'WireGuard' { $config.WireGuardPort } 'OpenVPNUdp' { $config.OpenVpnUdpPort } 'OpenVPNTcp' { $config.OpenVpnTcpPort } }
    $protocol = if ($item -eq 'OpenVPNTcp') { 'TCP' } else { 'UDP' }
    $null = New-NetFirewallRule -Name ('WindowsVPN-' + $item) -DisplayName ('WindowsVPN ' + $item) -Direction Inbound -Action Allow -Protocol $protocol -LocalPort $port -InterfaceAlias $config.WanAlias -Profile Any
}
$powerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoProfile -NonInteractive -File "' + (Join-Path $destination 'Initialize-VpnRouting.ps1') + '" -ConfigPath "' + (Join-Path $destination 'network.json') + '" -Apply'
$action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments
$triggers = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)))
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
$null = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $settings -User 'SYSTEM' -RunLevel Highest
Start-ScheduledTask -TaskName $taskName
Write-Output "Networking configured. Backup: $backup. Test forwarding and NAT with a connected client."
