# Measure MTU and performance before changing offload settings

A working handshake and a small transfer do not guarantee that large packets will pass or that the connection will reach the expected speed. Measure the specific path first. Change MTU, client routes and offload settings one at a time so you can identify which change helped.

## 1. Calculate an initial MTU budget

MTU defines the largest IP packet an interface can carry. The VPN adds an outer wrapper to the inner packet, and the complete packet must fit along the outer path. PMTUD discovers this limit along the path. It requires the relevant ICMP error messages to reach the sender.

WireGuard data has a basic overhead of 60 B over outer IPv4 and 80 B over outer IPv6. This includes the outer IP, UDP and WG data header/tag. Additional encapsulation or IPv6 extension headers can reduce the available budget. With a link MTU of 1492, the maximum inner MTU for outer IPv6 is 1412 with this basic overhead. Do not assume that 1420 fits this path. For changing mobile paths, 1280 is often a practical, conservative starting point, but still check PMTU and fragmentation of the outer transport.

| Example path | Inner MTU | How to use the value |
| --- | --- | --- |
| WG, outer IPv6, link MTU 1492 | at most 1412 with basic overhead | 1492 minus 80 B; additional encapsulation can lower the limit |
| WG, outer IPv4, link MTU 1500 | for example, 1420 after testing | the basic budget allows more, but the choice also depends on the whole path |
| WG, changing mobile path | start at 1280 | the generator's conservative default still requires testing |
| OpenVPN | default tunnel MTU 1500 | base any adjustment on its transport, PMTUD and manual |

This table is not a universal tuning recipe. Changing MTU on only one side can hide the original problem. An inner IPv6 MTU of 1280 does not guarantee that the complete outer packet will fit every path. For OpenVPN, first check PMTUD, `mssfix` for the actual transport, ICMP errors and logs. Do not copy options from another version or apply the WG budget to OpenVPN. [WireGuard protocol](https://www.wireguard.com/protocol/), [OpenVPN manual](https://openvpn.net/community-docs/community-articles/openvpn-2-7-manual/).

For an initial IPv4 check, use `ping.exe -4 -f -l <payload> <destination>`. The complete IP packet is typically 28 B larger than the payload. Basic ICMPv6 echo overhead is 48 B, but do not assume that echo, TCP and the tunnel use the same path. Ping can be filtered, and a successful small packet does not verify large TCP transfers. Alongside echo tests, inspect Packet Too Big messages and actual TCP segments.

## 2. Test packet sizes and transfers in both directions

Record the OS build, NIC/driver, VPN version, endpoint transport, IPv4/IPv6 payload, direction and number of flows. Measure the server without a VPN, traffic inside the tunnel, and internet access through the VPN separately. Repeat the measurements and use a controlled test endpoint where possible. Do not automatically switch client VPNs or force a connection without the user's deliberate choice.

An external speedtest measures one particular path and application. The remote test endpoint, IPv4/IPv6, single or multiple flows, TLS, CPU and timing can all affect the result. One successful website does not prove the server's capacity for every connection.

Start with a small transfer from client -> server and server -> client. Then repeat with a larger transfer, followed by an internet test. On a healthy path, the transfer should continue steadily without long stalls after the initial connection. If small packets work but large TCP transfers stall, inspect packet sizes, retransmissions and ICMP Packet Too Big. Lowering MTU without checking the cause does not complete the diagnosis.

## 3. Capture evidence before testing an RSC change

RSC combines received segments and can affect the data path for forwarded traffic. If `pktmon` shows **DropReason RSC packet**, especially for large coalesced IPv6 blocks such as those around 8 KB, investigate offload even if `Get-NetAdapterRsc` reports operational disabled because forwarding is enabled. That status alone does not rule out a problem involving the global setting, driver and forwarding.

Do not disable RSC on every server as a precaution. Base the change on a reproducible fault, a captured drop and a control transfer that lets you compare the state before and after the change. [Global offload settings](https://learn.microsoft.com/en-us/powershell/module/nettcpip/set-netoffloadglobalsetting), [Packet Monitor](https://learn.microsoft.com/en-us/windows-server/networking/technologies/pktmon/pktmon-syntax).

```powershell
Get-NetOffloadGlobalSetting | Select-Object ReceiveSegmentCoalescing,ReceiveSideScaling,TaskOffload
Get-NetAdapterRsc -Name Ethernet | Format-List *
```

Capture traffic separately using the [diagnostics chapter](07-Troubleshooting-and-recovery.md). First check for an existing capture session, run a limited test with `--comp all`, and verify that known control traffic is captured. If a NIC-only capture does not show the expected Rx traffic, do not yet conclude that the packet never reached the server.

## 4. Test the change with rollback prepared in advance

Restarting the WAN adapter interrupts remote access. Use an independent console and a planned maintenance window. The trial saves the adapter GUID, original global RSC value and original IPv4/IPv6 settings. **Before making the change**, it registers a SYSTEM task with an absolute deadline, a second trigger at boot, `StartWhenAvailable` and retry on failure. It does not depend on the SSH/WinRM session or parent PowerShell process staying alive.

Before changing anything, it also verifies a valid Authenticode signature on the system `powershell.exe` and runs the actual rollback task in an unarmed preflight mode. This mode only writes a marker containing the SYSTEM SID and must finish successfully. It checks whether the script really runs under the local execution policy, beyond confirming that the task exists. It does not use ExecutionPolicy Bypass. These scripts are not publisher-signed. Organizations using AllSigned must review and sign them through their approved process first. Handle downloaded files carrying Mark of the Web according to local policy; do not disable protection globally. A failed preflight leaves RSC and the NIC unchanged, with only an unarmed task left for inspection.

```powershell
.\scripts\Invoke-RscTrial.ps1 -WanAlias Ethernet -RollbackMinutes 15
.\scripts\Invoke-RscTrial.ps1 -WanAlias Ethernet -RollbackMinutes 15 -RestartAdapter -Apply -WhatIf
.\scripts\Invoke-RscTrial.ps1 -WanAlias Ethernet -RollbackMinutes 15 -RestartAdapter -Apply
```

Record the protected trial directory and UTC rollback deadline printed by the script. Inspect the specific rollback task before measuring. The script disables global RSC and IPv6 RSC on the WAN, then briefly restarts the selected NIC. Changing the setting with `NoRestart` may not activate the driver's new state. It does not change IPv4 RSC or other offload features. The adapter's IPv4 setting may therefore remain enabled while global RSC is disabled. Automatic rollback restores both protocols and the original global value, then restarts the original adapter by GUID instead of selecting any adapter with the same name.

If the test does not succeed, let the deadline expire or run the restore manually:

```powershell
$trial = Read-Host 'Trial directory reported by the script'
.\scripts\Restore-RscTrial.ps1 -TrialDirectory $trial -Apply
```

## 5. Confirm the result only after repeating the tests

Repeat the same destinations, directions and transfer sizes used before the change, and compare the captures as well. Confirm the change deliberately only after the tests succeed. The speedtest result does not trigger automatic confirmation. Confirmation is rejected shortly before the deadline or while rollback is running:

```powershell
.\scripts\Complete-RscTrial.ps1 -TrialDirectory $trial -Apply -WhatIf
.\scripts\Complete-RscTrial.ps1 -TrialDirectory $trial -Apply
```

The backup remains after the commit. In another approved maintenance window, restart the system and check both the settings and actual traffic again. Repeatedly disabling RSC at each boot does not replace checking whether the setting persists. The rollback task does not replace console access, a VM backup or a working Task Scheduler. A serious system failure may prevent even a SYSTEM task from completing the restore.

Finish with the [operational checks and recovery plan](07-Troubleshooting-and-recovery.md), rather than continuing to tune settings across the whole system.
