# Your own VPN on Windows Server 2022 and 2025

This guide walks you through setting up a VPN that securely connects a computer or phone to your server and, depending on your policy, to the internet. You will start with a simple IPv4 connection. Once it works, you can add other protocols, IPv6 and any performance adjustments you need. The package includes PowerShell scripts and configuration templates without real keys.

WireGuard is a good place to start: its configuration is straightforward, and it identifies each device by its public key. OpenVPN adds client certificate management, fast UDP connections with DCO and a separate TCP option for networks that restrict UDP. IKEv2 uses the native Windows client and the RRAS and NPS server roles. You do not have to run all three protocols; choose the ones your clients need.

## How the network fits together

Each service gets its own address range. WireGuard and both OpenVPN services share one WinNAT for IPv4 internet access. IKEv2 gets a separate range and its own RRAS NAT. This makes it clear which service assigns addresses and which one translates outgoing traffic.

The tunnel first carries a packet from the client to the server. Forwarding lets the server send it onward, and NAT for IPv4 internet access translates the client's private address to the server's address. This is why a VPN can be connected while internet access still fails. The guide tests these parts one at a time.

| Service | Internal range | Server address and client assignments | IPv4 internet access |
| --- | --- | --- | --- |
| WireGuard | `10.77.0.0/25` | server `.1`, first devices `.2` and `.3` | WinNAT for `10.77.0.0/24` |
| OpenVPN UDP | `10.77.0.128/26` | server `.129`, OpenVPN assigns client addresses | the same WinNAT |
| OpenVPN TCP | `10.77.0.192/26` | server `.193`, separate client pool | the same WinNAT |
| IKEv2 | `10.78.0.0/24` | RRAS pool, for example `.10` to `.200` | RRAS NAT |

Add further WireGuard devices only within its reserved range, for example `.4` to `.126`. Give each device a unique address and set its server-side `AllowedIPs` to that address with `/32`. Do not use the OpenVPN ranges or the RRAS pool for them. First rule out overlaps with the LAN, other VPNs, Docker, Hyper-V and client networks.

Windows WinNAT supports one internal NAT prefix. That is why we do not create a separate NAT for each tunnel. An existing suitable object is preserved, including its sessions; an administrator must review any unrelated configuration first. The script also recognizes `10.77.0.1/24` as the network `10.77.0.0/24`. [Microsoft: setting up NAT](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/setup-nat-network).

In this design, RRAS terminates IKEv2 and provides its own IPv4 NAT between the WAN and the Internal interface. We do not add WireGuard or OpenVPN interfaces to RRAS NAT. RRAS handles IKEv2 independently of the shared WinNAT used by WireGuard and OpenVPN.

## Follow the chapters in order

1. [Prepare the server, addresses and installation packages](docs/01-Installation.md). Identify the WAN interface, check the ports and prepare a safe way to undo changes.
2. [Set up WireGuard and IPv4 internet access](docs/02-WireGuard.md). Create keys, start the native service and test both the tunnel and NAT.
3. [Add OpenVPN UDP and TCP](docs/03-OpenVPN.md). Prepare certificates, separate profiles and client identities.
4. [Set up IKEv2 with RRAS and NPS](docs/04-IKEv2.md). Bring together the server certificate, user authentication, address assignment and RRAS NAT.
5. [Decide how IPv6 should work](docs/05-IPv6.md). Distinguish the endpoint address from the addresses inside the VPN and arrange routing with your provider.
6. [Measure MTU and performance](docs/06-MTU-and-performance.md). Adjust settings to suit the actual path and your measurements.
7. [Prepare for operation, troubleshooting and recovery](docs/07-Troubleshooting-and-recovery.md). Check startup after a reboot and plan what to do when something fails.

[Official sources](docs/08-References.md) supplement the links beside individual steps. OpenVPN **2.7.9** and DCO **2.8.14** were verified in the official distributions when this guide was prepared. Before installing, check current fixes, signatures and compatibility again. OpenVPN 2.7 removed Wintun and the `windows-driver` option; this guide uses UDP with DCO and TCP with `disable-dco` and TAP-Windows6. [OpenVPN Community](https://openvpn.net/community/), [DCO releases](https://github.com/OpenVPN/ovpn-dco-win/releases), [OpenVPN 2.7 changes](https://community.openvpn.net/Development/StatusOfOpenvpn27).

## What to expect from the scripts

Move the package outside the webroot into a protected administrative folder. Run the commands from the package root in 64-bit Windows PowerShell 5.1. Installation steps require administrator privileges. All addresses here, including `vpn.example.com`, are examples; in particular, `192.0.2.53` is not a usable public DNS resolver.

Start by reading the current state and the plan:

```powershell
.\scripts\Test-VpnState.ps1
.\scripts\New-WireGuardConfiguration.ps1 -DnsServer 192.0.2.53
.\scripts\Set-VpnNetworking.ps1 -ConfigPath .\config\network.example.json
```

Configuration scripts make no changes without `-Apply`. With `-Apply -WhatIf`, they show the intended action; only `-Apply` performs it. Read-only validation also runs while planning, so input files and required modules must already exist. Manual commands shown separately, such as importing a certificate or starting a service, have a real effect.

The scripts do not download anything automatically or grant broad groups access to private keys. They store runtime files under the protected `ProgramData\WindowsVPN` directory and check ownership, permissions and reparse points in parent paths. They do not blindly take over existing configurations. Protect backups, client profiles and QR codes as secrets.

The basic installation does not disable RSC, restart the WAN adapter or enable the NDP helper. Those advanced changes have their own conditions. Whenever you change routing or the network adapter, have console access that is independent of the VPN.

The default client profiles send IPv4 through the VPN. IPv6 may continue to use the original connection until you configure IPv6 and the corresponding client policy. An IPv4 full tunnel alone does not guarantee that all traffic and DNS stay inside the tunnel.

Before production use, read [verification and its limits](docs/09-Validation.md). The automation has passed syntax and offline checks; the package does not have a complete test matrix of clean Server 2022/2025 installations. Public IPv6 for IKEv2 is a design for you to validate, and the advanced NDP helper requires a separate live test.
