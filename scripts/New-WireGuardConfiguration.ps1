#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$OutputDirectory = (Join-Path $env:ProgramData 'WindowsVPN\WireGuard'),
    [ValidatePattern('^[a-zA-Z0-9.-]+$')][string]$Endpoint = 'vpn.example.com',
    [ValidateRange(1, 65535)][int]$Port = 51820,
    [ValidateRange(1280, 1420)][int]$Mtu = 1280,
    [Parameter(Mandatory = $true)][System.Net.IPAddress]$DnsServer,
    [string]$WgPath = (Join-Path $env:ProgramFiles 'WireGuard\wg.exe'),
    [switch]$Apply
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$serverPath = Join-Path $OutputDirectory 'wg-server.conf'
if (Test-Path -LiteralPath $serverPath) { Write-Output 'Configuration exists; no keys regenerated or files overwritten.'; return }
if (-not $Apply) { Write-Output 'Plan: generate three local key pairs and protected IPv4 files. No service changes.'; return }
Assert-Administrator
if (-not (Test-Path -LiteralPath $WgPath -PathType Leaf)) { throw 'Install WireGuard first.' }
if (-not $PSCmdlet.ShouldProcess($OutputDirectory, 'Generate secret keys and configurations')) { return }
Protect-VpnDirectory $OutputDirectory
if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw 'Output must be empty; partial generation requires manual recovery.' }
function Get-LocalKeyPair {
    $privateKey = ((& $WgPath genkey) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $privateKey -notmatch '^[A-Za-z0-9+/]{43}=$') { throw 'wg genkey failed.' }
    $publicKey = (($privateKey | & $WgPath pubkey) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $publicKey -notmatch '^[A-Za-z0-9+/]{43}=$') { throw 'wg pubkey failed.' }
    return @{ Private = $privateKey; Public = $publicKey }
}
$server = Get-LocalKeyPair
$desktop = Get-LocalKeyPair
$mobile = Get-LocalKeyPair
$serverText = @"
[Interface]
PrivateKey = $($server.Private)
Address = 10.77.0.1/25
ListenPort = $Port
MTU = $Mtu

[Peer]
PublicKey = $($desktop.Public)
AllowedIPs = 10.77.0.2/32

[Peer]
PublicKey = $($mobile.Public)
AllowedIPs = 10.77.0.3/32
"@
Write-VpnUtf8 $serverPath $serverText
foreach ($client in @(@{ Name = 'desktop'; Key = $desktop; Address = '10.77.0.2' }, @{ Name = 'mobile'; Key = $mobile; Address = '10.77.0.3' })) {
    $text = @"
[Interface]
PrivateKey = $($client.Key.Private)
Address = $($client.Address)/32
DNS = $DnsServer
MTU = $Mtu

[Peer]
PublicKey = $($server.Public)
Endpoint = ${Endpoint}:$Port
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
"@
    Write-VpnUtf8 (Join-Path $OutputDirectory ($client.Name + '.conf')) $text
}
$server = $null; $desktop = $null; $mobile = $null; $serverText = $null; $text = $null
Write-Output 'Generated protected files. Transfer client profiles securely and remove server-side client copies afterwards.'
