# Prepare the server, addresses and installation packages

Before creating the first tunnel, identify the actual internet-facing interface, available ports and a way to recover if something goes wrong. This preparation is shared by all three protocols. Run the guide's commands from the package root, and perform installation in 64-bit Windows PowerShell 5.1 as an administrator.

## 1. Check access and prepare the network

Use an updated Windows Server 2022 or 2025, 64-bit Windows PowerShell 5.1, an administrator account and a separate console provided by your hypervisor or hosting provider. On a domain server, check permissions, NPS and any required AD registration. For a VM, first check whether the platform supports the VPN role; being able to install a role does not guarantee that the hosting platform supports it.

Record the WAN alias, default route, assigned public addresses, DNS and available routed prefixes. Replace the public DNS name `vpn.example.com` with your own name. Add A/AAAA records only for endpoints that are actually reachable. Allow or forward the appropriate ports on the provider's firewall or upstream NAT. This guide's default design uses:

| Purpose | Public traffic | Note |
| --- | --- | --- |
| WireGuard | UDP 51820 | the tunnel can carry both IPv4 and IPv6 |
| OpenVPN UDP | UDP 1194 | defaults to `udp4`; IPv6 transport is a separate choice |
| OpenVPN TCP | TCP 1195 | deliberately different from the usual HTTPS port 443 |
| IKEv2 | UDP 500 and 4500 | native ESP without NAT-T also requires IP protocol 50 |
| IPv6 infrastructure | required ICMPv6 | Packet Too Big, errors and NDP on the relevant segment |

Do not use TCP 443 if IIS or another service already listens on the same address. Any port change must match the server, clients and firewalls. Opening an endpoint does not grant access to the whole LAN. Restrict VPN clients separately through NPS groups, destination ACLs and router/WFP rules as appropriate for your architecture. Specifically test that server management access and communication between clients are blocked where required. Simply omitting `client-to-client` in OpenVPN does not guarantee isolation through host routing.

Before making changes, take a consistent VM or system backup and back up service and firewall configurations. Make RSC changes and NAT migrations only during a maintenance window. The backups that scripts create in `ProgramData\WindowsVPN\Backups` are not complete system images and do not provide a universal automatic rollback on their own.

```powershell
Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, ifIndex
Get-NetRoute -DestinationPrefix '0.0.0.0/0'
Get-NetNat
Get-NetTCPConnection -State Listen | Where-Object LocalPort -in 443,1195
Get-NetUDPEndpoint | Where-Object LocalPort -in 500,4500,1194,51820
.\scripts\Test-VpnState.ps1
```

Find the WAN adapter and its default route in the output. Record the exact alias, for example `Ethernet`, and check that another service is not using your planned ports. If NAT or a VPN already exists, first identify its owner and address range. Do not delete it just to follow a new guide.

The output contains real local addresses and names. Do not put it into public documentation. `Test-VpnState.ps1` does not read private keys or VPN profile contents, but it does not anonymize diagnostic output either.

## 2. Prepare signed installation packages

Download the WireGuard MSI through the [official installation page](https://www.wireguard.com/install/) and OpenVPN Community through the [official download page](https://openvpn.net/community/). The guide starts from OpenVPN 2.7.9 and DCO 2.8.14, verified when it was prepared. Check current security fixes again before installing; these version numbers are no reason to stay on an older vulnerable release. Record the actual version, architecture and hash of the approved file. [DCO releases](https://github.com/OpenVPN/ovpn-dco-win/releases).

Obtain the expected SHA256 through an independently verified channel, or after verifying the signature and origin as part of package approval. Merely calculating the hash of an arbitrary downloaded file does not verify its origin. The script requires both a valid Authenticode signature and the appropriate publisher. It is neither a downloader nor a version manager; running an installation again may trigger an MSI repair or upgrade.

```powershell
$package = Join-Path $PWD 'WireGuard-approved-amd64.msi'
$approvedHash = Read-Host 'Approved SHA256 from a verified source'
.\scripts\Install-VpnPackage.ps1 -Product WireGuard -MsiPath $package -ExpectedSha256 $approvedHash
.\scripts\Install-VpnPackage.ps1 -Product WireGuard -MsiPath $package -ExpectedSha256 $approvedHash -Apply -WhatIf
.\scripts\Install-VpnPackage.ps1 -Product WireGuard -MsiPath $package -ExpectedSha256 $approvedHash -Apply
```

For OpenVPN, repeat the process with `-Product OpenVPN`. The installer opens interactively; select the automatic startup service, DCO and TAP-Windows6, including `tapctl.exe`. The script reports a reboot request (`3010`) but does not force a reboot. Check component selection and the current behavior of your particular MSI in its documentation. OpenVPN 2.7 changed service permissions, so older instructions for logs may not match a new installation. [Release history](https://community.openvpn.net/ReleaseHistory).

## 3. Break installation into steps you can test

1. Prepare a local copy of `config/network.example.json` and correct the WAN alias. Decide whether you will use only WG or both OpenVPN endpoints as well.
2. Set up WireGuard with private IPv4 addresses as described in the next chapter. For the first test, the client can route only `10.77.0.0/24`.
3. Run `Set-VpnNetworking.ps1` first without `-Apply`, then with `-Apply -WhatIf`, and finally with `-Apply`. Test the tunnel and IPv4 internet access.
4. Prepare the OpenVPN PKI and both server profiles. TCP gets a real TAP adapter; check UDP DCO in the log. Use the shared WinNAT already prepared for concurrent operation.
5. Add IKEv2 through RRAS, NPS, a separate address pool and RRAS NAT. Do not migrate all protocols at once.
6. Add IPv6 only after IPv4 tests pass in both directions. Adjust MTU and offload separately, based on measurements.
7. Schedule a reboot and repeat the same tests. Then check services, task history, adapters and client addresses.

Generated WireGuard profiles with `AllowedIPs = 0.0.0.0/0` send IPv4 through the VPN. **On their own, they provide neither IPv6 internet through the VPN nor protection against traffic outside the tunnel.** Add an actual tunnel IPv6 address and `::/0` only as described in the IPv6 chapter. Without that change, client IPv6 may use the original connection. Choose a deliberate client policy for split tunneling, DNS and any kill switch, and test it on the actual platform.

## 4. Read the plan before each change

Use `-WhatIf` together with `-Apply` for a more detailed action plan. Read-only input validation still runs, so the supplied files and required modules must exist. Without `-Apply`, no directories, firewall rules, keys or tasks are created.

New configurations are not overwritten. An existing tunnel service is not reinstalled, and restarting a running VPN remains the administrator's decision. If the managed task already exists, the networking script only reports its state; it does not automatically reconcile later JSON or firewall changes. When updating, compare the protected saved configuration with the desired one, then make a deliberate maintenance change with a backup. If a step fails halfway through, inspect the objects already created first. Running it again is no reason to delete unrelated NAT objects or configurations.

## 5. Store runtime files in trusted paths

The shared helper securely initializes `ProgramData\WindowsVPN` before creating its subdirectories. A new directory is created atomically with a protected DACL for SYSTEM and Administrators, owned by Administrators. For an existing path, the helper checks ownership and dangerous permissions along the entire path. It does not automatically take over a root directory created in advance by an untrusted account. The destination must not allow ordinary accounts to write, and parent directories must not allow replacement through DELETE_CHILD, ACL changes or taking ownership.

The same checks apply to a custom OutputDirectory: use an absolute local path on a trusted volume, without junctions, symlinks or alternate streams. Reparse points in parent paths are checked too, not just the final directory. A directory shared for writing, a user profile, a UNC share or a path through a development junction is unsuitable for the runtime files of a privileged service. If ownership or permissions are rejected, first establish where the directory came from. Do not simply grant Everyone FullControl or use a script to take over an unknown tree.

Files run as SYSTEM are checked and protected separately after copying. A privileged script, its configuration and its libraries must not retain an untrusted owner or an explicit ACE that grants untrusted write access. After the initial copy, check the ACLs and the command run by the scheduled task. The policy is deliberately conservative, so some legitimate directories owned by individual accounts need separate administrative preparation. The guide does not blindly adopt their existing permissions.

Once you have recorded the addresses and have console access, a backup and a verified installer, continue with [WireGuard](02-WireGuard.md). The next chapter's goal is a first client with working IPv4 internet access.
