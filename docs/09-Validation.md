# Verify the package and prepare your own operational tests

A script with valid syntax does not prove that the VPN will work on a specific server. This package has verified PowerShell syntax and offline checks for safe default modes, address prefixes, ACL rules and handling of synthetic NDP packets. It does not have a complete test matrix for fresh installations on Windows Server 2022 and 2025 with every driver and client. Complete the following steps before production deployment.

## 1. Run checks that do not change the system

Open 64-bit Windows PowerShell 5.1 in the package root and run:

```powershell
.\scripts\Test-PackageOffline.ps1
.\scripts\Test-PathSafetyOffline.ps1
```

The first script checks the parser, JSON, network normalization and rejection of unrelated or multiple NAT objects. It replaces commands that would make changes with a failure trap when testing default modes. It also tests valid and invalid Neighbor Solicitation packets without opening a capture handle. The second script checks trusted path and ACL rules in memory.

Expect successful completion without errors. These commands do not change files, services, networking, certificate stores or scheduled tasks. Passing does not verify the actual DCO/TAP driver, signing requirements and SYSTEM task execution on your machine, or traffic passing through NAT.

## 2. Optionally test protection of actual filesystem paths

The following check explicitly permits temporary files and directories only under the package:

```powershell
.\scripts\Test-PathSafetyOffline.ps1 -UseFilesystemFixtures
```

It creates a protected test area and checks that a pre-existing untrusted owner and an ancestor junction are rejected. It then removes its own test area. It does not change network or system settings. For this test, the package must be on a real local path without ancestor junctions and must be writable by the test. This optional filesystem test does not install a VPN.

If you already have an approved PSScriptAnalyzer installation, you can also run a static check:

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error,Warning
```

The guide does not install any module automatically. Resolve parser or security check failures before continuing. Do not disable a path check simply because it rejects an unknown owner or broad permissions.

## 3. Distinguish a plan from an actual change

Installation and configuration scripts use `-Apply`. Without it, they read settings and show a plan. Use `-Apply -WhatIf` for a more detailed plan. Allow an actual `-Apply` only after reviewing the inputs and backup. Existing objects are not always updated automatically: some scripts stop after reporting the current state, while others reject a conflict. The installation chapters describe each script's behavior.

`Common.ps1` is a library. Loading it only defines functions, but manually calling `Protect-VpnDirectory`, `New-VpnBackup` or `Write-VpnUtf8` changes files or permissions. Manual calls to `Import-PfxCertificate`, `Stop-Service`, `Restart-Service`, `Start-ScheduledTask` and `pktmon start` also make real changes. A script's safe default mode does not turn those commands into read-only operations.

## 4. Verify the installation on your own test setup

Follow the chapters in installation order. For each result, record the Windows version, VPN version, network driver, client, outer IPv4/IPv6 transport and inner IPv4/IPv6 traffic.

1. **WireGuard:** check the service, unique keys and addresses, handshake, both directions of tunnel traffic, IPv4 internet access and DNS. Check that another peer does not overlap the OpenVPN reservations.
2. **OpenVPN:** check the actual worker SID and its minimum required access to PKI/logs. Connect UDP/DCO and TCP/TAP separately. Check the log, assigned address, internet access, and rejection of an invalid or revoked client certificate.
3. **IKEv2:** check the actual IKE and PEAP certificates offered, exact name and trusted root. Verify that an authorized user is accepted and an unauthorized user is rejected, an address is assigned from the RRAS pool, and internet access works through RRAS NAT. WinNAT sessions do not verify this NAT.
4. **Access policy:** check permitted destinations and blocked access to server management and between clients according to your policy. For an IPv4 full tunnel, also check for IPv6 and DNS leaks.
5. **IPv6:** verify the endpoint first, followed by addresses inside the tunnel, provider route, forwarding and return delivery. Add ICMPv6 Packet Too Big, DNS AAAA and larger transfers in both directions.
6. **Restart and recovery:** repeat the same tests after a planned restart. Check delayed adapter creation, the routing task, certificate availability and protected backups. Test restoration on a test copy before attempting it on the live server.

For an optional RSC trial, also verify the actual SYSTEM task preflight, restoration of the original global and IPv4/IPv6 state, and restored connectivity. The administrator confirms a successful result; no speedtest automatically accepts the change.

## 5. Understand the limits of the advanced sections

**Public IPv6 with RRAS/IKEv2 is not a verified, ready-to-use installation procedure.** The IPv6 chapter proposes a separate routed `/64` and test conditions. Working IPv4 VPN access or an IPv6 endpoint does not validate this part.

**The NDP helper is an advanced additional implementation that requires your own pilot.** It assumes explicit allocation of an entire on-link `/64`, an approved signed WinDivert driver, the exact router and an address whitelist. The offline validator does not prove the behavior of the actual router, raw socket, driver or neighbor cache after a restart. Prefer a prefix routed by the provider.

## Which script to use at each step

| Task | Scripts | What else to verify on the server |
| --- | --- | --- |
| Product installation | `Install-VpnPackage.ps1` | the specific MSI, components, signature and any required restart |
| WireGuard | `New-WireGuardConfiguration.ps1`, `Install-WireGuardTunnel.ps1` | resolver, profile handover, service and addresses after restart |
| OpenVPN | `Install-OpenVpnConfiguration.ps1` | actual worker SID, PKI, DCO/TAP and both initialization logs |
| WG/OpenVPN networking | `Set-VpnNetworking.ps1`, `Initialize-VpnRouting.ps1` | one suitable WinNAT, forwarding, firewall and adapters that appear later |
| IKEv2 server and client | `Install-Ikev2Roles.ps1`, `Set-Ikev2Server.ps1`, `New-Ikev2Client.ps1` | hosting support, MMC initialization, NPS, certificates, client and RRAS NAT |
| RSC trial and rollback | `Invoke-RscTrial.ps1`, `Restore-RscTrial.ps1`, `Complete-RscTrial.ps1` | policy, actual task execution, original GUID and transfers in both directions |
| Diagnostics | `Test-VpnState.ps1`, `Test-SourceBoundTcp.ps1` | an authorized destination, local source address and anonymized output for sharing |
| Advanced NDP | `advanced/Start-NdpProxy.ps1` | provider conditions, driver, whitelist, NS/NA and persistence |

See [diagnostics and recovery](07-Troubleshooting-and-recovery.md) for detailed operational commands and rollback procedures. The [introduction](../README.md) gives an overview of the complete process.
