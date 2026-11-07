#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param([Parameter(Mandatory = $true)][string]$WanAlias, [switch]$Apply)
. (Join-Path $PSScriptRoot 'Common.ps1')
$null = Get-NetAdapter -Name $WanAlias
if (-not $Apply) { Write-Output 'Plan: install DirectAccess-VPN, Routing and NPAS roles; UDP 500/4500 inbound on selected WAN. Does not initialize RRAS/NPS/NAT or restart server.'; return }
Assert-Administrator
if ($PSCmdlet.ShouldProcess('IKEv2 prerequisites', 'Install roles and firewall rules')) {
    $backup = New-VpnBackup 'IKEv2-Roles'
    Get-WindowsFeature RemoteAccess, DirectAccess-VPN, Routing, NPAS | Export-Clixml -LiteralPath (Join-Path $backup 'features.xml')
    $result = Install-WindowsFeature DirectAccess-VPN, Routing, NPAS -IncludeManagementTools
    if (-not $result.Success) { throw 'Role installation failed.' }
    foreach ($port in @(500, 4500)) {
        $name = 'WindowsVPN-IKEv2-' + $port
        if (-not (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue)) {
            $null = New-NetFirewallRule -Name $name -DisplayName $name -Direction Inbound -Action Allow -Protocol UDP -LocalPort $port -InterfaceAlias $WanAlias -Profile Any
        } else { Write-Warning "Rule $name exists; inspect its filters manually." }
    }
    $result | Select-Object Success, RestartNeeded, ExitCode
    Write-Output 'Continue with docs/04-IKEv2.md. Server is not yet configured as a secure VPN endpoint.'
}
