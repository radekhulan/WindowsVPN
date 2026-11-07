# Diagnostics, recovery and verification after a restart

A VPN is ready for use when its services, addresses and routing recover after a restart and you have tested how to recover from a fault. Use this procedure when handing over the server and when investigating later problems. Check the state first, then change only the part identified by the test results.

## 1. Identify which part of the path fails

| Step | What success proves | What it does not yet prove |
| --- | --- | --- |
| Endpoint port / handshake | transport reachability and part of authentication | routing/NAT, DNS or internet access |
| Client -> server tunnel IP | traffic enters the tunnel and receives a reply | internet access |
| Server -> client and client -> permitted LAN | both directions and return routes | public IPv6 delivery |
| Client -> external IPv4 TCP | the IPv4 routing/NAT/data path | IPv6, DNS or larger transfers |
| Client -> external IPv6 TCP | IPv6 payload and return delivery | correct PMTU for every path |
| A/AAAA DNS, large transfers and reboot | broader functionality and persistence | the capacity of every internet connection |

First check the server without the VPN. Test IP connectivity and DNS separately. Record the outer IPv4/IPv6 transport, inner IPv4/IPv6 payload, direction, destination port and expected path.

```powershell
.\scripts\Test-VpnState.ps1
Get-NetNat
Get-NetNatSession | Select-Object -First 10
Get-NetIPAddress -IPAddress 10.77.0.1,10.77.0.129,10.77.0.193
Get-ScheduledTask -TaskName 'WindowsVPN-*' | Select-Object TaskName,State
```

WinNAT session output applies to WG/OVPN. Check RRAS NAT through RRAS. If IKEv2 provides working direct TCP access to the server but external TCP fails, investigate user authentication separately from NAT and the return route. Do not recreate certificates blindly when traffic inside the tunnel already works.

## 2. Test a connection from a specific source address

The supplied probe creates one time-limited TCP connection from a selected **locally assigned** address. It does not add a listener or firewall rule, set a route, send an application payload or change the VPN profile. Use only a destination you are allowed to test. A probe running on the server checks the server's path; it does not automatically test client forwarding.

```powershell
.\scripts\Test-SourceBoundTcp.ps1 -SourceAddress 10.77.0.2 -DestinationAddress 192.0.2.80 -Port 443
.\scripts\Test-SourceBoundTcp.ps1 -SourceAddress 2001:db8:200:1::2 -DestinationAddress 2001:db8:ffff::80 -Port 443
```

These documentation destinations will not work on the internet. Replace them with an approved real destination and a local source address. Running the probe on the client from its tunnel address helps distinguish tunnel traffic from internet egress. For server -> client tests, use an existing approved client service or a temporary authenticated test endpoint. Restrict any new listener by source and port, then remove it and its firewall rule after the test.

## 3. Capture both failing and known working traffic

`pktmon` is a system diagnostics tool. Captures can contain personal data and network details, so store them outside the public package in a protected ProgramData directory. The commands below **change capture state**; this is not a read-only script. Check `pktmon status`, existing filters and any other diagnostics in progress. Do not stop an existing session or delete its filters without agreement.

```powershell
pktmon status
pktmon filter list
pktmon comp list
$capture = Join-Path $env:ProgramData 'WindowsVPN\Capture'
. .\scripts\Common.ps1
Protect-VpnDirectory $capture
pktmon start --capture --comp all --pkt-size 160 --file-name (Join-Path $capture 'vpn.etl') --file-size 128
if ($LASTEXITCODE -ne 0) { throw 'Capture start failed' }
```

First make a short, known transfer that the capture must see, then run the failing transfer alongside it. Record the exact times and addresses. The `all` scope can capture several copies of the same packet at different components. Copy counts are not counts of network transmissions. After the test:

```powershell
pktmon counters
pktmon stop
if ($LASTEXITCODE -ne 0) { throw 'Capture stop failed' }
pktmon etl2txt (Join-Path $capture 'vpn.etl') --out (Join-Path $capture 'vpn.txt')
if ($LASTEXITCODE -ne 0) { throw 'Capture conversion failed' }
Select-String -LiteralPath (Join-Path $capture 'vpn.txt') -Pattern 'DropReason','RSC','DROP'
```

Check the syntax for your version with `pktmon help` and `pktmon start help`. Metadata or a limited payload may not be enough to diagnose every fault. Without a positive control, an absent packet does not establish where it was lost. [Microsoft: pktmon syntax](https://learn.microsoft.com/en-us/windows-server/networking/technologies/pktmon/pktmon-syntax).

## 4. Plan a restart and repeat functional tests

Verify automatic startup for `OpenVPNService`, the specific `WireGuardTunnel$...` service, RRAS `RemoteAccess` and the IPsec/NPS services required by your deployment. A Running state does not prove that tunnel initialization has finished. Check the logs and addresses.

`WindowsVPN-Routing` runs at startup and then every five minutes. It uses `StartWhenAvailable` and prevents overlapping instances. If an adapter appears late, the first run warns about the missing address and a later run finds it. To retry immediately, use `Start-ScheduledTask`. Do not rely on registering a one-time trigger for two seconds later. Waiting briefly for the specific IP address and then running a deliberate test is safer.

```powershell
Start-ScheduledTask -TaskName 'WindowsVPN-Routing'
Get-ScheduledTaskInfo -TaskName 'WindowsVPN-Routing'
Get-NetIPInterface | Where-Object Forwarding -eq Enabled | Select-Object InterfaceAlias,AddressFamily,Forwarding
```

DCO and WireGuard can recreate an adapter with a different GUID. The WG/OVPN initializer therefore uses the currently assigned tunnel IPv4 addresses, rather than an old GUID. RRAS Internal is not part of this WG/OVPN initializer. Manage its IPv4 NAT and optional IPv6 separately. For NDP, check the runtime after reboot, NS/NA after cache expiry and the actual whitelist.

After the restart, expect all services in use and their addresses to be available. From the client, repeat the handshake, an allowed tunnel service, IPv4 internet access, any configured IPv6 access, and DNS. Also verify that prohibited access is denied. A scheduled task starting successfully does not prove the entire data path works.

## 5. Back up before changing anything and prepare a specific rollback

| Area | Safe rollback |
| --- | --- |
| MSI / roles | a VM/system backup and a supported installer; removing a role can destroy its configuration and is not a universal undo |
| WireGuard | the protected previous `.conf`, a controlled restart of the specific service, followed by handshake and routing tests |
| OpenVPN | protected PKI/profiles, restoring the original configuration in a maintenance window, and restarting only the affected service |
| WinNAT | keep the existing shared object; during a migration, restore addresses/profiles/routes first, then verify sessions |
| RRAS/NPS | configuration exports made in advance, certificate/key availability and ownership of NAT interfaces; import only after reviewing the impact |
| New CA on the client | remove only the specific newly added CA after checking dependent applications/profiles, never by CN alone |
| NDP helper | stop your own process/task and restore the previous routes/addresses; do not delete WinDivert if another application uses it |
| RSC | the independent `Restore-RscTrial.ps1`, original GUID and saved per-protocol/global values |

Before changing RRAS/NPS, you can save the configuration to a protected backup directory. These commands read server settings, but they also create files and protect them:

```powershell
. .\scripts\Common.ps1
$backup = New-VpnBackup 'RRAS-NPS-Manual'
$rasDump = (netsh ras dump | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'RRAS dump failed' }
Write-VpnUtf8 (Join-Path $backup 'rras-dump.txt') $rasDump
$routingDump = (netsh routing dump | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Routing dump failed' }
Write-VpnUtf8 (Join-Path $backup 'routing-dump.txt') $routingDump
Export-NpsConfiguration -Path (Join-Path $backup 'nps.xml')
```

The dump is saved as UTF-8 without a BOM, preserving the ASCII command and interface names used here. It is not an automatic restore script. Before using `netsh -f`, check the specific commands, interface identifiers and accepted encoding on the target system. For non-ASCII aliases, test the complete export/import on a test machine and compare the actual state after restoration. Saving text alone, especially as UTF-16, does not guarantee that it can be restored.

**An NPS export contains unencrypted RADIUS shared secrets** if they are configured. Keep it only in a protected backup and use approved encryption for transfer. It is not a public diagnostic file. It does not contain server private keys or the complete SQL logging configuration, so it is not a complete standalone backup. Back up keys separately through an approved process. The commands above do not perform an import. An NPS import would overwrite the existing configuration. [Microsoft: NPS export](https://learn.microsoft.com/en-us/windows-server/networking/technologies/nps/nps-manage-export).

Before handing over the server, record where protected backups are stored, who can restore the certificates, and when the certificates and CRL expire. Also keep a record of the versions used and the approved installers. Separately complete the [package verification and integration checks](09-Validation.md). An export without a tested restore procedure is not a finished rollback plan.
