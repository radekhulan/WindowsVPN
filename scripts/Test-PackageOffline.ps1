#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path $PSScriptRoot -Parent
$script:Passed = 0
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:Passed++
}
function Assert-Throw {
    param([scriptblock]$Code, [string]$Pattern, [string]$Name)
    $caught = $false
    try { & $Code | Out-Null } catch { $caught = $_.Exception.Message -match $Pattern }
    Assert-True $caught $Name
}
foreach ($file in Get-ChildItem -LiteralPath $packageRoot -Filter '*.ps1' -Recurse) {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert-True (@($errors).Count -eq 0) ('Parse ' + $file.Name)
}
foreach ($file in Get-ChildItem -LiteralPath $packageRoot -Filter '*.json' -Recurse) {
    $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    Assert-True $true ('JSON ' + $file.Name)
}
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-True ((Get-VpnIPv4Network '10.77.0.1/24') -eq '10.77.0.0/24') 'Normalize host-bit NAT prefix'
Assert-True ((Get-VpnIPv4Network '10.77.0.193/26') -eq '10.77.0.192/26') 'Normalize narrow pool'
Assert-Throw { Get-VpnIPv4Network '2001:db8::/64' } 'Invalid' 'Reject IPv6 as IPv4 NAT'

& {
    function Get-NetAdapter { [pscustomobject]@{ ifIndex = 1; Name = 'Ethernet'; InterfaceGuid = [guid]'00000000-0000-0000-0000-000000000001' } }
    function Get-NetAdapterRsc { [pscustomobject]@{ IPv4Enabled = $true; IPv6Enabled = $true } }
    function Get-NetOffloadGlobalSetting { [pscustomobject]@{ ReceiveSegmentCoalescing = 'Enabled' } }
    function Get-NetNat { @() }
    function Get-ScheduledTask { @() }
    function Get-NetFirewallRule { @() }
    function Get-NetIPAddress { [pscustomobject]@{ InterfaceIndex = 2 } }
    function Get-NetIPInterface { [pscustomobject]@{ InterfaceAlias = 'Mock'; Forwarding = 'Disabled' } }
    foreach ($name in @('New-NetNat','New-NetFirewallRule','Set-NetIPInterface','Register-ScheduledTask','Start-ScheduledTask','Install-WindowsFeature','Set-NetOffloadGlobalSetting','Disable-NetAdapterRsc','Enable-NetAdapterRsc','Restart-NetAdapter','Set-Service','Copy-Item','New-Item','Export-Clixml','Set-Acl')) {
        Set-Item -Path ('Function:' + $name) -Value { throw 'Unexpected mutation from a safe-default script.' }
    }
    & (Join-Path $PSScriptRoot 'New-WireGuardConfiguration.ps1') -DnsServer 192.0.2.53 | Out-Null
    Assert-True $true 'WireGuard default performs no writes/key generation'
    & (Join-Path $PSScriptRoot 'Install-Ikev2Roles.ps1') -WanAlias Ethernet | Out-Null
    Assert-True $true 'IKEv2 role default performs no mutations'
    & (Join-Path $PSScriptRoot 'Invoke-RscTrial.ps1') -WanAlias Ethernet | Out-Null
    Assert-True $true 'RSC default never changes offload/restarts/registers task'
    & (Join-Path $PSScriptRoot 'Initialize-VpnRouting.ps1') -ConfigPath (Join-Path $packageRoot 'config\network.example.json') | Out-Null
    Assert-True $true 'Routing default never enables forwarding'
    & (Join-Path $PSScriptRoot 'Set-VpnNetworking.ps1') -ConfigPath (Join-Path $packageRoot 'config\network.example.json') | Out-Null
    Assert-True $true 'Networking default never creates NAT/firewall/task'
    function Get-NetNat { [pscustomobject]@{ Name = 'Existing'; InternalIPInterfaceAddressPrefix = '10.77.0.1/24' } }
    & (Join-Path $PSScriptRoot 'Set-VpnNetworking.ps1') -ConfigPath (Join-Path $packageRoot 'config\network.example.json') | Out-Null
    Assert-True $true 'Matching existing NAT is accepted without deletion'
    function Get-NetNat { [pscustomobject]@{ Name = 'Other'; InternalIPInterfaceAddressPrefix = '192.0.2.0/24' } }
    Assert-Throw { & (Join-Path $PSScriptRoot 'Set-VpnNetworking.ps1') -ConfigPath (Join-Path $packageRoot 'config\network.example.json') } 'Another WinNAT' 'Foreign NAT refused'
    function Get-NetNat { @([pscustomobject]@{}, [pscustomobject]@{}) }
    Assert-Throw { & (Join-Path $PSScriptRoot 'Set-VpnNetworking.ps1') -ConfigPath (Join-Path $packageRoot 'config\network.example.json') } 'More than one' 'Multiple NAT objects refused'
}

if (-not ('WindowsVpnNdpCapture' -as [type])) { Add-Type -Path (Join-Path $packageRoot 'advanced\NdpCapture.cs') }
function Set-TestChecksum {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only an in-memory synthetic packet is modified, without external state.')]
    [CmdletBinding()]
    param([byte[]]$Packet)
    $Packet[42] = 0; $Packet[43] = 0
    $sum = [uint32]0
    for ($i = 8; $i -lt 40; $i += 2) { $sum += [uint32](([int]$Packet[$i] -shl 8) + [int]$Packet[$i + 1]) }
    $sum += [uint32]($Packet.Length - 40) + 58
    for ($i = 40; $i -lt $Packet.Length; $i += 2) { $sum += [uint32](([int]$Packet[$i] -shl 8) + [int]$Packet[$i + 1]) }
    while ($sum -gt 65535) { $sum = ($sum -band 65535) + ($sum -shr 16) }
    $checksum = 65535 -bxor $sum
    $Packet[42] = [byte]($checksum -shr 8); $Packet[43] = [byte]($checksum -band 255)
}
$packet = New-Object byte[] 64
$packet[0] = 0x60; $packet[5] = 24; $packet[6] = 58; $packet[7] = 255; $packet[40] = 135
$target = '2001:db8:100:0:100::2'; $router = 'fe80::1'
[Array]::Copy([Net.IPAddress]::Parse($router).GetAddressBytes(), 0, $packet, 8, 16)
[Array]::Copy([Net.IPAddress]::Parse('ff02::1:ff00:2').GetAddressBytes(), 0, $packet, 24, 16)
[Array]::Copy([Net.IPAddress]::Parse($target).GetAddressBytes(), 0, $packet, 48, 16)
Set-TestChecksum $packet
Assert-True ($null -ne [WindowsVpnNdpCapture]::Validate($packet, 64, @($target), @($router))) 'Valid whitelisted multicast NS accepted offline'
$bad = [byte[]]$packet.Clone(); $bad[7] = 254
Assert-True ($null -eq [WindowsVpnNdpCapture]::Validate($bad, 64, @($target), @($router))) 'Wrong hop limit refused'
$bad = [byte[]]$packet.Clone(); $bad[43] = $bad[43] -bxor 1
Assert-True ($null -eq [WindowsVpnNdpCapture]::Validate($bad, 64, @($target), @($router))) 'Invalid checksum refused'
Assert-True ($null -eq [WindowsVpnNdpCapture]::Validate($packet, 64, @($target), @('fe80::2'))) 'Untrusted router refused'
Assert-True ($null -eq [WindowsVpnNdpCapture]::Validate($packet, 64, @('2001:db8:100:0:100::3'), @($router))) 'Non-whitelisted target refused'
Assert-True ($null -eq [WindowsVpnNdpCapture]::Validate($packet, 63, @($target), @($router))) 'Truncated NS refused'
$bad = [byte[]]$packet.Clone(); $bad[6] = 0
Assert-True ($null -eq [WindowsVpnNdpCapture]::Validate($bad, 64, @($target), @($router))) 'IPv6 extension-header path refused'
$bad = [byte[]]$packet.Clone()
[Array]::Copy([Net.IPAddress]::Parse('ff02::1').GetAddressBytes(), 0, $bad, 24, 16)
Set-TestChecksum $bad
Assert-True ($null -eq [WindowsVpnNdpCapture]::Validate($bad, 64, @($target), @($router))) 'Wrong NS destination refused'
$bad = New-Object byte[] 72; [Array]::Copy($packet, $bad, 64); $bad[5] = 32; $bad[64] = 1; $bad[65] = 0
Set-TestChecksum $bad
Assert-True ($null -eq [WindowsVpnNdpCapture]::Validate($bad, 72, @($target), @($router))) 'Zero-length NS option refused'
$unicast = [byte[]]$packet.Clone()
[Array]::Copy([Net.IPAddress]::Parse($target).GetAddressBytes(), 0, $unicast, 24, 16)
Set-TestChecksum $unicast
Assert-True ($null -ne [WindowsVpnNdpCapture]::Validate($unicast, 64, @($target), @($router))) 'Valid unicast NS accepted offline'
Write-Output "PASS: $script:Passed offline checks. No native capture/driver, network changes, tasks or certificate-store writes were executed."
