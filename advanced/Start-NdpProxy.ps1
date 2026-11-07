#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [ValidateRange(0, 1440)][int]$RunMinutes = 30,
    [switch]$AllowDriverInstallation,
    [switch]$Apply
)
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Common.ps1')
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$prefix = ([string]$config.AllocatedOnLinkPrefix).Split('/')
if ($prefix.Count -ne 2 -or $prefix[1] -ne '64') { throw 'Explicit allocated on-link /64 required.' }
$prefixBytes = [Net.IPAddress]::Parse($prefix[0]).GetAddressBytes()
if ($prefixBytes.Length -ne 16 -or ($prefixBytes[0] -band 0xe0) -ne 0x20) { throw 'Expected a global unicast allocated /64.' }
if (@($config.Addresses).Count -lt 1 -or @($config.Addresses).Count -gt 256) { throw 'Whitelist must contain 1..256 explicit IPv6 addresses.' }
$targets = @()
foreach ($value in $config.Addresses) {
    $ip = [Net.IPAddress]::Parse($value)
    $bytes = $ip.GetAddressBytes()
    if ($bytes.Length -ne 16 -or ($bytes[0..7] -join ',') -ne ($prefixBytes[0..7] -join ',')) { throw 'Whitelisted target outside allocated /64.' }
    if (Get-NetIPAddress -IPAddress $ip.ToString() -ErrorAction SilentlyContinue | Where-Object InterfaceAlias -eq $config.InterfaceAlias) { throw 'Never proxy an address assigned directly to the WAN.' }
    $targets += $ip.ToString()
}
$targets = @($targets | Select-Object -Unique)
$trusted = @()
foreach ($value in $config.TrustedRouters) {
    $ip = [Net.IPAddress]::Parse($value)
    if (-not $ip.IsIPv6LinkLocal -or $ip.ScopeId -ne 0) { throw 'Trusted router must be an explicit unscoped IPv6 link-local address from this WAN.' }
    $trusted += $ip.ToString()
}
if ($trusted.Count -eq 0) { throw 'Trusted router whitelist is empty.' }
foreach ($entry in @(@{ File = 'WinDivert.dll'; Hash = $config.DllSha256 }, @{ File = 'WinDivert64.sys'; Hash = $config.DriverSha256 })) {
    if ($entry.Hash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Replace pinned binary SHA256 values after independent verification.' }
    $path = Join-Path $config.WinDivertDirectory $entry.File
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.Hash) { throw 'WinDivert binary hash mismatch.' }
}
if ((Get-AuthenticodeSignature -LiteralPath (Join-Path $config.WinDivertDirectory 'WinDivert64.sys')).Status -ne 'Valid') { throw 'Signed official driver is required; never disable driver signature enforcement.' }
$interface = Get-NetAdapter -Name $config.InterfaceAlias
$link = @(Get-NetIPAddress -InterfaceIndex $interface.ifIndex -AddressFamily IPv6 | Where-Object { $_.IPAddress -like 'fe80:*' -and [string]$_.AddressState -eq 'Preferred' })
if ($link.Count -ne 1) { throw 'Expected one preferred WAN link-local address.' }
$source = [Net.IPAddress]::Parse(($link[0].IPAddress -replace '%\d+$', '') + '%' + $interface.ifIndex)
$mac = [byte[]]@($interface.MacAddress -split '[-:]' | ForEach-Object { [Convert]::ToByte($_, 16) })
if ($mac.Length -ne 6) { throw 'Expected Ethernet MAC address.' }
if (-not $Apply) { Write-Output 'Plan: reactive NS-only proxy for explicit targets. No periodic unsolicited advertisements. Driver installation only with AllowDriverInstallation.'; return }
Assert-Administrator
if (-not $PSCmdlet.ShouldProcess($config.InterfaceAlias, 'Run narrow reactive NDP proxy; optional WinDivert driver installation')) { return }
Assert-VpnFileTrusted $ConfigPath
Assert-VpnFileTrusted (Join-Path $PSScriptRoot 'NdpCapture.cs')
Assert-VpnFileTrusted (Join-Path $config.WinDivertDirectory 'WinDivert.dll')
Assert-VpnFileTrusted (Join-Path $config.WinDivertDirectory 'WinDivert64.sys')
if ($targets[0] -like '2001:db8:*') { throw 'Documentation prefix must be replaced by genuinely allocated addresses before Apply.' }
Add-Type -Path (Join-Path $PSScriptRoot 'NdpCapture.cs')
$ndpSocket = $null; $membershipSocket = $null; $captureStarted = $false
$lastSend = @{}; $window = [DateTime]::UtcNow; $sentInWindow = 0
$end = if ($RunMinutes -eq 0) { [DateTime]::MaxValue } else { [DateTime]::UtcNow.AddMinutes($RunMinutes) }
$stopFile = Join-Path $PSScriptRoot 'stop.flag'
if (Test-Path -LiteralPath $stopFile) { throw 'stop.flag is present. Review why it was set before removing it.' }
function Get-NeighborChecksum {
    param([byte[]]$Payload, [Net.IPAddress]$Destination)
    $pseudo = New-Object byte[] (40 + $Payload.Length)
    [Array]::Copy($source.GetAddressBytes(), 0, $pseudo, 0, 16)
    [Array]::Copy($Destination.GetAddressBytes(), 0, $pseudo, 16, 16)
    $pseudo[35] = [byte]$Payload.Length; $pseudo[39] = 58
    [Array]::Copy($Payload, 0, $pseudo, 40, $Payload.Length)
    $sum = [uint32]0
    for ($i = 0; $i -lt $pseudo.Length; $i += 2) { $sum += [uint32](([int]$pseudo[$i] -shl 8) + [int]$pseudo[$i + 1]) }
    while ($sum -gt 65535) { $sum = ($sum -band 65535) + ($sum -shr 16) }
    return [int](([uint32]65535 -bxor $sum) -band 65535)
}
try {
    $membershipSocket = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetworkV6, [Net.Sockets.SocketType]::Raw, [Net.Sockets.ProtocolType]::IcmpV6)
    $membershipSocket.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::IPv6Any, 0)))
    $groups = @{}
    foreach ($target in $targets) {
        $bytes = [Net.IPAddress]::Parse($target).GetAddressBytes()
        $group = 'ff02::1:ff' + ('{0:x2}' -f $bytes[13]) + ':' + ('{0:x2}{1:x2}' -f $bytes[14], $bytes[15])
        if (-not $groups.ContainsKey($group)) {
            $option = New-Object Net.Sockets.IPv6MulticastOption([Net.IPAddress]::Parse($group), [long]$interface.ifIndex)
            $membershipSocket.SetSocketOption([Net.Sockets.SocketOptionLevel]::IPv6, [Net.Sockets.SocketOptionName]::AddMembership, $option)
            $groups[$group] = $true
        }
    }
    $ndpSocket = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetworkV6, [Net.Sockets.SocketType]::Raw, [Net.Sockets.ProtocolType]::IcmpV6)
    $ndpSocket.Bind((New-Object Net.IPEndPoint($source, 0)))
    $ndpSocket.SetSocketOption([Net.Sockets.SocketOptionLevel]::IPv6, [Net.Sockets.SocketOptionName]31, [int]$interface.ifIndex)
    $ndpSocket.Ttl = 255
    [WindowsVpnNdpCapture]::Start([string]$config.WinDivertDirectory, [int]$interface.ifIndex, [string[]]$targets, [string[]]$trusted, [bool]$AllowDriverInstallation)
    $captureStarted = $true
    while ([DateTime]::UtcNow -lt $end -and -not (Test-Path -LiteralPath $stopFile)) {
        if ([WindowsVpnNdpCapture]::Error) { throw [WindowsVpnNdpCapture]::Error }
        $request = [WindowsVpnNdpCapture]::Next()
        if ($null -eq $request) { Start-Sleep -Milliseconds 50; continue }
        $now = [DateTime]::UtcNow
        if (($now - $window).TotalSeconds -ge 1) { $window = $now; $sentInWindow = 0 }
        $key = $request.Target + '|' + $request.Source
        if ($sentInWindow -ge 20 -or ($lastSend.ContainsKey($key) -and ($now - $lastSend[$key]).TotalMilliseconds -lt 500)) { continue }
        $destination = [Net.IPAddress]::Parse($request.Source + '%' + $interface.ifIndex)
        $payload = New-Object byte[] 32
        $payload[0] = 136; $payload[4] = 0x60
        [Array]::Copy([Net.IPAddress]::Parse($request.Target).GetAddressBytes(), 0, $payload, 8, 16)
        $payload[24] = 2; $payload[25] = 1; [Array]::Copy($mac, 0, $payload, 26, 6)
        $checksum = Get-NeighborChecksum $payload $destination
        $payload[2] = [byte]($checksum -shr 8); $payload[3] = [byte]($checksum -band 255)
        if ($ndpSocket.SendTo($payload, (New-Object Net.IPEndPoint($destination, 0))) -ne 32) { throw 'Incomplete NA send.' }
        $lastSend[$key] = $now; $sentInWindow++
    }
} finally {
    if ($captureStarted) { [WindowsVpnNdpCapture]::Stop() }
    if ($ndpSocket) { $ndpSocket.Dispose() }
    if ($membershipSocket) { $membershipSocket.Dispose() }
}
