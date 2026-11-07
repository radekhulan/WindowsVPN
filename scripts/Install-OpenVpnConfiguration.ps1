#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$PkiSourceDirectory,
    [Parameter(Mandatory = $true)][string]$WorkerAccount,
    [Parameter(Mandatory = $true)][Net.IPAddress]$DnsServer,
    [string]$OpenVpnDirectory = (Join-Path $env:ProgramFiles 'OpenVPN'),
    [switch]$Apply
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$source = Get-Item -LiteralPath $PkiSourceDirectory
$account = New-Object Security.Principal.NTAccount($WorkerAccount)
$sid = $account.Translate([Security.Principal.SecurityIdentifier])
$virtualService = (New-Object Security.Principal.NTAccount('NT SERVICE\OpenVPNService')).Translate([Security.Principal.SecurityIdentifier])
$serviceAccounts = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20', $virtualService.Value)
if ($sid.Value -notin $serviceAccounts) {
    $resolved = @(Get-CimInstance Win32_Account -Filter ("SID='" + $sid.Value + "'"))
    if ($resolved.Count -ne 1 -or [int]$resolved[0].SIDType -ne 1) { throw 'Worker must be a verifiable individual service user or the exact OpenVPN service identity. All groups, including BUILTIN/IIS_IUSRS, are refused.' }
}
$required = @('ca.crt', 'server.crt', 'server.key', 'crl.pem', 'tls-crypt.key')
foreach ($name in $required) { if (-not (Test-Path -LiteralPath (Join-Path $source.FullName $name) -PathType Leaf)) { throw "Missing $name" } }
$service = Get-Service -Name OpenVPNService
if ($service.Status -ne 'Stopped') { throw 'Stop OpenVPNService in a maintenance window before staging profiles.' }
$configAuto = Join-Path $OpenVpnDirectory 'config-auto'
$base = Join-Path $env:ProgramData 'WindowsVPN\OpenVPN'
$pki = Join-Path $base 'PKI'
$logs = Join-Path $base 'Log'
$tap = Get-NetAdapter -Name 'VPN-TCP' -ErrorAction SilentlyContinue
if ($tap -and $tap.InterfaceDescription -notmatch 'TAP-Windows') { throw 'VPN-TCP name belongs to a different adapter.' }
$tapctl = Join-Path $OpenVpnDirectory 'bin\tapctl.exe'
if (-not $tap -and -not (Test-Path -LiteralPath $tapctl -PathType Leaf)) { throw 'Install TAP-Windows6 and tapctl.exe before staging any profiles/PKI.' }
foreach ($file in @('windowsvpn-udp.ovpn', 'windowsvpn-tcp.ovpn')) {
    if (Test-Path -LiteralPath (Join-Path $configAuto $file)) { throw 'Profiles already staged; refuse overwrite. Back up and review an explicit update.' }
}
if (Test-Path -LiteralPath $base) { throw 'Staging directory already exists; inspect partial/previous installation.' }
if (-not $Apply) { Write-Output 'Plan: stage two profiles and server-only PKI, grant worker read to PKI and modify to logs, create TAP if missing. Service stays stopped.'; return }
Assert-Administrator
if (-not $PSCmdlet.ShouldProcess('OpenVPN server', 'Stage protected PKI, profiles and TAP adapter')) { return }
$backup = New-VpnBackup 'OpenVPN'
Get-CimInstance Win32_Service -Filter "Name='OpenVPNService'" | Select-Object Name, StartName, StartMode, PathName | Export-Clixml -LiteralPath (Join-Path $backup 'service.xml')
Protect-VpnDirectory $base
Protect-VpnDirectory $pki
Protect-VpnDirectory $logs
foreach ($name in $required) { Copy-Item -LiteralPath (Join-Path $source.FullName $name) -Destination (Join-Path $pki $name) }
foreach ($entry in @(@{ Path = $base; Rights = 'ReadAndExecute'; Inherit = 'None' }, @{ Path = $pki; Rights = 'ReadAndExecute'; Inherit = 'ContainerInherit,ObjectInherit' }, @{ Path = $logs; Rights = 'Modify'; Inherit = 'ContainerInherit,ObjectInherit' })) {
    $acl = Get-Acl -LiteralPath $entry.Path
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, $entry.Rights, $entry.Inherit, 'None', 'Allow')))
    Set-Acl -LiteralPath $entry.Path -AclObject $acl
}
$null = New-Item -ItemType Directory -Path $configAuto -Force
foreach ($transport in @('udp', 'tcp')) {
    $template = Join-Path (Split-Path $PSScriptRoot -Parent) ('config\openvpn-server-' + $transport + '.ovpn.example')
    $text = [IO.File]::ReadAllText($template).Replace('@PKI@', $pki.Replace('\', '/')).Replace('@LOG@', $logs.Replace('\', '/')).Replace('@DNS@', $DnsServer.ToString())
    $path = Join-Path $configAuto ('windowsvpn-' + $transport + '.ovpn')
    Write-VpnUtf8 $path $text
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($id in @('S-1-5-18', 'S-1-5-32-544')) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($id)), 'FullControl', 'Allow'))) }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'ReadAndExecute', 'Allow')))
    Set-Acl -LiteralPath $path -AclObject $acl
}
if (-not $tap) { Invoke-VpnNative $tapctl @('create', '--hwid', 'root\tap0901', '--name', 'VPN-TCP') }
Set-Service -Name OpenVPNService -StartupType Automatic
Write-Output "Staged. Verify PKI and worker ACL, then start OpenVPNService explicitly. Backup: $backup"
