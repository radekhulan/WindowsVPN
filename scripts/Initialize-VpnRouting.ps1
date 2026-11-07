#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param([Parameter(Mandatory = $true)][string]$ConfigPath, [switch]$Apply)
. (Join-Path $PSScriptRoot 'Common.ps1')
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$wan = Get-NetAdapter -Name $config.WanAlias -ErrorAction Stop
$interfaces = @([int]$wan.ifIndex)
$missing = @()
foreach ($ip in $config.TunnelIPv4Addresses) {
    $found = @(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ip -ErrorAction SilentlyContinue)
    if ($found.Count -eq 1) { $interfaces += [int]$found[0].InterfaceIndex } else { $missing += $ip }
}
if ($missing.Count -gt 0) { Write-Warning ('Tunnel addresses not ready: ' + ($missing -join ', ') + '. Scheduled task retries later.') }
if ($Apply) { Assert-Administrator }
foreach ($index in @($interfaces | Select-Object -Unique)) {
    $families = @('IPv4')
    if ($config.EnableIPv6Forwarding) { $families += 'IPv6' }
    foreach ($family in $families) {
        foreach ($entry in @(Get-NetIPInterface -InterfaceIndex $index -AddressFamily $family -ErrorAction SilentlyContinue)) {
            if ([string]$entry.Forwarding -eq 'Enabled') { continue }
            if ($Apply -and $PSCmdlet.ShouldProcess("$($entry.InterfaceAlias) $family", 'Enable forwarding in ActiveStore')) {
                Set-NetIPInterface -InterfaceIndex $index -AddressFamily $family -Forwarding Enabled -PolicyStore ActiveStore
            } else { Write-Output "Plan: forwarding $family on $($entry.InterfaceAlias)." }
        }
    }
}
