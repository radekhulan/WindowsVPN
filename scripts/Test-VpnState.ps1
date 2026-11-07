#Requires -Version 5.1
[CmdletBinding()]
param([string]$WanAlias = 'Ethernet')
$ErrorActionPreference = 'Stop'
function Read-State {
    param([scriptblock]$Read, [object[]]$Arguments = @())
    try { & $Read @Arguments } catch { [pscustomobject]@{ Unavailable = $_.Exception.Message } }
}
$result = [ordered]@{
    TimestampUtc = [DateTime]::UtcNow.ToString('o')
    OS = Read-State { Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, LastBootUpTime }
    Services = Read-State { Get-Service | Where-Object { $_.Name -match '^(OpenVPN|WireGuardTunnel\$|RemoteAccess$|IKEEXT$|PolicyAgent$|IAS$)' } | Select-Object Name, Status, StartType }
    Adapters = Read-State { Get-NetAdapter | Select-Object Name, InterfaceDescription, ifIndex, InterfaceGuid, Status, LinkSpeed }
    IP = Read-State { Get-NetIPAddress | Select-Object InterfaceAlias, InterfaceIndex, AddressFamily, IPAddress, PrefixLength, AddressState }
    Interfaces = Read-State { Get-NetIPInterface | Select-Object InterfaceAlias, InterfaceIndex, AddressFamily, Forwarding, NlMtu, ConnectionState }
    Routes = Read-State { Get-NetRoute | Select-Object InterfaceAlias, DestinationPrefix, NextHop, RouteMetric, PolicyStore }
    NAT = Read-State { Get-NetNat | Select-Object Name, InternalIPInterfaceAddressPrefix, Active }
    NatSessionCount = Read-State { @(Get-NetNatSession).Count }
    GlobalOffload = Read-State { Get-NetOffloadGlobalSetting | Select-Object ReceiveSegmentCoalescing, ReceiveSideScaling, TaskOffload }
    RSC = Read-State -Read { param($NicName) Get-NetAdapterRsc -Name $NicName | Select-Object Name, IPv4Enabled, IPv6Enabled, IPv4OperationalState, IPv6OperationalState, IPv4FailureReason, IPv6FailureReason } -Arguments @($WanAlias)
    Tasks = Read-State { Get-ScheduledTask -TaskName 'WindowsVPN-*' -ErrorAction SilentlyContinue | Select-Object TaskName, State }
    VpnProfiles = Read-State { Get-VpnConnection -ErrorAction Stop | Select-Object Name, ServerAddress, TunnelType, AuthenticationMethod, ConnectionStatus, SplitTunneling }
    NameValidation = Read-State { Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\RasMan\Parameters' -Name DisableIKENameEkuCheck -ErrorAction SilentlyContinue | Select-Object DisableIKENameEkuCheck }
    CertificateMetadata = Read-State { Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, DnsNameList, NotBefore, NotAfter, HasPrivateKey, EnhancedKeyUsageList }
}
$result | ConvertTo-Json -Depth 6
