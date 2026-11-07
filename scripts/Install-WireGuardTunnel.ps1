#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = (Join-Path $env:ProgramData 'WindowsVPN\WireGuard\wg-server.conf'),
    [string]$WireGuardPath = (Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'),
    [switch]$Apply
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$file = Get-Item -LiteralPath $ConfigPath
$name = $file.BaseName
if ($file.Extension -ne '.conf' -or $name -notmatch '^[A-Za-z0-9_-]{1,32}$') { throw 'Use a simple .conf filename.' }
$text = [IO.File]::ReadAllText($file.FullName)
if ($text -match 'REPLACE_|<[^>]+>' -or $text -notmatch '(?m)^PrivateKey\s*=\s*[A-Za-z0-9+/]{43}=\s*$') { throw 'Unprepared WireGuard configuration.' }
$serviceName = 'WireGuardTunnel$' + $name
if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) { Write-Output 'Tunnel service exists; no reinstall or restart performed.'; return }
if (-not $Apply) { Write-Output "Plan: install native tunnel service $serviceName from protected configuration."; return }
Assert-Administrator
if ($PSCmdlet.ShouldProcess($serviceName, 'Install native tunnel service and start it')) {
    Protect-VpnDirectory $file.DirectoryName
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse configuration file refused.' }
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($id in @('S-1-5-18', 'S-1-5-32-544')) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($id)), 'FullControl', 'Allow'))) }
    Set-Acl -LiteralPath $file.FullName -AclObject $acl
    Invoke-VpnNative $WireGuardPath @('/installtunnelservice', $file.FullName)
    Set-Service -Name $serviceName -StartupType Automatic
    Start-Service -Name $serviceName
    Get-Service -Name $serviceName | Select-Object Name, Status, StartType
}
