#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$WanAlias,
    [string]$RrasInternalName = 'Internal',
    [ValidatePattern('^[a-zA-Z0-9.-]+$')][string]$ServerName = 'vpn.example.com',
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-fA-F0-9]{40}$')][string]$CertificateThumbprint,
    [ValidateRange(1, 128)][int]$Ikev2Ports = 64,
    [switch]$Apply
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$null = Get-NetAdapter -Name $WanAlias
if ($WanAlias -eq $RrasInternalName) { throw 'WAN and RRAS Internal must differ.' }
foreach ($feature in @(Get-WindowsFeature DirectAccess-VPN, Routing, NPAS)) { if (-not $feature.Installed) { throw 'Install required roles first.' } }
$certificate = Get-Item -LiteralPath ('Cert:\LocalMachine\My\' + $CertificateThumbprint)
$dnsNames = @($certificate.DnsNameList | ForEach-Object { $_.Unicode })
$eku = @($certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' } | ForEach-Object { $_.EnhancedKeyUsages } | ForEach-Object { $_.Value })
if (-not $certificate.HasPrivateKey -or $ServerName -notin $dnsNames -or '1.3.6.1.5.5.7.3.1' -notin $eku -or $certificate.NotAfter -lt (Get-Date) -or $certificate.NotBefore -gt (Get-Date)) { throw 'Server certificate must have private key, exact DNS SAN, ServerAuth EKU and valid dates.' }
if (@(Get-RemoteAccessConnectionStatistics).Count -gt 0) { throw 'Active RRAS clients exist. Schedule an outage instead.' }
$netsh = Join-Path $env:WINDIR 'System32\netsh.exe'
$ipDump = (& $netsh ras ip dump | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Initialize RRAS VPN access in MMC before this script.' }
$natDump = (& $netsh routing ip nat dump | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Initialize RRAS IPv4 NAT in MMC first. No undocumented runtime registration is attempted.' }
$ranges = @([regex]::Matches($ipDump, '(?im)^\s*add\s+range\b[^\r\n]*'))
if ($ranges.Count -gt 0 -and ($ranges.Count -ne 1 -or $ranges[0].Value -notmatch '\bfrom\s*=\s*"?10\.78\.0\.10\b' -or $ranges[0].Value -notmatch '\bto\s*=\s*"?10\.78\.0\.200\b')) { throw 'A different RRAS pool exists; no ranges removed or replaced.' }
$natInterfaces = @([regex]::Matches($natDump, '(?im)^\s*add\s+interface\b[^\r\n]*'))
$wanPresent = $false; $internalPresent = $false
foreach ($entry in $natInterfaces) {
    $line = $entry.Value
    $wanPattern = '\bname\s*=\s*"?' + [regex]::Escape($WanAlias) + '"?\s+mode\s*=\s*FULL\b'
    $internalPattern = '\bname\s*=\s*"?' + [regex]::Escape($RrasInternalName) + '"?\s+mode\s*=\s*PRIVATE\b'
    if ($line -match $wanPattern -and -not $wanPresent) { $wanPresent = $true }
    elseif ($line -match $internalPattern -and -not $internalPresent) { $internalPresent = $true }
    else { throw 'RRAS NAT contains another interface or mode. Review ownership manually; no interfaces removed.' }
}
if (-not $Apply) { Write-Output 'Plan: verify leaf metadata; back up RRAS/NPS, use dedicated 10.78.0.10..200 pool, IKEv2-only ports and RRAS WAN/Internal NAT. Does not import/bind cert, configure NPS or restart service.'; return }
Assert-Administrator
if (-not $PSCmdlet.ShouldProcess('Initialized dedicated RRAS server', 'Back up and configure IKEv2-only IPv4 pool, ports and RRAS NAT')) { return }
$backup = New-VpnBackup 'IKEv2-Server'
Write-VpnUtf8 (Join-Path $backup 'ras-ip-dump.txt') $ipDump
Write-VpnUtf8 (Join-Path $backup 'ras-nat-dump.txt') $natDump
$dump = (& $netsh ras dump | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'RRAS backup failed.' }
Write-VpnUtf8 (Join-Path $backup 'ras-dump.txt') $dump
Export-NpsConfiguration -Path (Join-Path $backup 'nps.xml')
if (-not (Test-Path -LiteralPath (Join-Path $backup 'nps.xml') -PathType Leaf)) { throw 'NPS export file is missing.' }
$npsDocument = New-Object Xml.XmlDocument
$npsDocument.Load((Join-Path $backup 'nps.xml'))
if (-not $npsDocument.DocumentElement) { throw 'NPS export is empty.' }
Write-Warning 'Protected NPS backup contains unencrypted RADIUS shared secrets. Never publish or transfer it unencrypted.'
Get-VpnServerConfiguration | Export-Clixml -LiteralPath (Join-Path $backup 'ipsec-policy.xml')
$certificate | Select-Object Subject, DnsNameList, NotAfter, EnhancedKeyUsageList | Export-Clixml -LiteralPath (Join-Path $backup 'certificate-metadata.xml')
if ($ranges.Count -eq 0) { Invoke-VpnNative $netsh @('ras', 'ip', 'add', 'range', 'from=10.78.0.10', 'to=10.78.0.200') }
Invoke-VpnNative $netsh @('ras', 'ip', 'set', 'addrassign', 'method=POOL')
Invoke-VpnNative $netsh @('ras', 'ip', 'set', 'addrreq', 'mode=DENY')
foreach ($protocol in @('PPTP', 'L2TP', 'SSTP')) {
    Invoke-VpnNative $netsh @('ras', 'set', 'wanports', ('device=WAN Miniport (' + $protocol + ')'), 'rasinonly=disabled', 'ddinout=disabled', 'ddoutonly=disabled')
}
Invoke-VpnNative $netsh @('ras', 'set', 'wanports', 'device=WAN Miniport (IKEv2)', 'rasinonly=enabled', 'ddinout=disabled', 'ddoutonly=disabled', ('maxports=' + $Ikev2Ports))
if (-not $wanPresent) { Invoke-VpnNative $netsh @('routing', 'ip', 'nat', 'add', 'interface', ('name=' + $WanAlias), 'mode=FULL') }
if (-not $internalPresent) { Invoke-VpnNative $netsh @('routing', 'ip', 'nat', 'add', 'interface', ('name=' + $RrasInternalName), 'mode=PRIVATE') }
Set-Service -Name RemoteAccess -StartupType Automatic
Write-Output "Server IPv4 settings staged. Backup: $backup. Validate NPS/PEAP cert selection, then explicitly restart RRAS in the maintenance window and test a client. WinNAT was not changed."
