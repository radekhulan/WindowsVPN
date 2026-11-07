# Your first working VPN: WireGuard and IPv4 internet access

Start with one server and one client. First test traffic inside the tunnel, then internet access. This helps you tell whether a problem concerns keys and the endpoint or routing and NAT.

WireGuard for Windows supports a standalone tunnel service. No additional management layer is required. The service is named after the `.conf` file and uses a standard configuration with `Address`, `ListenPort`, `MTU` and individual peers. [Official enterprise documentation](https://git.zx2c4.com/wireguard-windows/about/docs/enterprise.md).

## 1. Create the server and two client identities

A private key is a secret belonging to one device; its public key lets others recognize it. The safest approach is to create the client's private key on the client and give the server only the public key. The included starter generator can also create a server key pair and two client key pairs locally using the installed `wg.exe`. It never prints a private key. While generating keys, do not enable debug tracing that could record variable values.

```powershell
$dns = Read-Host 'DNS resolver reachable by VPN clients'
$endpoint = Read-Host 'Actual DNS name of the VPN server'
.\scripts\New-WireGuardConfiguration.ps1 -Endpoint $endpoint -DnsServer $dns
.\scripts\New-WireGuardConfiguration.ps1 -Endpoint $endpoint -DnsServer $dns -Apply -WhatIf
.\scripts\New-WireGuardConfiguration.ps1 -Endpoint $endpoint -DnsServer $dns -Apply
```

You should find three separate profiles under `ProgramData\WindowsVPN\WireGuard`: `wg-server.conf`, `desktop.conf` and `mobile.conf`. The server has `10.77.0.1/25`, and the clients have `.2/32` and `.3/32`. The generator will not overwrite an existing configuration.

## 2. Start the native tunnel service

The installer uses the generated server profile, names the service after the file and sets it to start automatically:

```powershell
.\scripts\Install-WireGuardTunnel.ps1 -Apply -WhatIf
.\scripts\Install-WireGuardTunnel.ps1 -Apply
Get-Service -Name 'WireGuardTunnel$wg-server'
& (Join-Path $env:ProgramFiles 'WireGuard\wg.exe') show wg-server
```

The directory containing the generated profiles has a protected ACL for SYSTEM and Administrators. Treat transferring client profiles or a QR code as transferring secrets. Each client receives only its own profile. After a secure handover, remove the server copies of client keys according to your retention policy. Do not put the server file, the whole folder, a QR screenshot or an unredacted export in a public repository.

The example in `config/wireguard-server.conf.example` is a nonworking template with placeholders. The installer rejects it until you replace the keys. If you generate keys on clients, add only their public keys and exact `/32` addresses, or IPv6 `/128` addresses, to the server.

Expect a running service and an interface with address `10.77.0.1`. Before the first client connects, it is normal to have no handshake.

## 3. Prepare the shared WinNAT and forwarding

Copy `config/network.example.json` to your own working configuration and correct the WAN alias as described in the previous chapter. If you plan to run both OpenVPN servers, you can leave all three tunnel addresses in place and prepare all endpoint rules now. Until the OpenVPN adapters exist, the initializer only reports them as missing and looks for them again on its next run.

```powershell
$network = Read-Host 'Full path to the edited network configuration JSON'
.\scripts\Set-VpnNetworking.ps1 -ConfigPath $network
.\scripts\Set-VpnNetworking.ps1 -ConfigPath $network -Apply -WhatIf
.\scripts\Set-VpnNetworking.ps1 -ConfigPath $network -Apply
Get-NetNat
Get-ScheduledTask -TaskName 'WindowsVPN-Routing'
```

For a WireGuard-only server, pass `-Enable WireGuard` in all three calls and leave only its tunnel address in your working JSON copy. Still keep one NAT for `10.77.0.0/24` to allow future concurrent operation. After applying the plan, expect one NAT and a `WindowsVPN-Routing` task that sets forwarding at startup and every five minutes.

When adding OpenVPN later, deliberately update the protected `ProgramData\WindowsVPN\Routing\network.json` and the corresponding endpoint rules, with a backup and an impact check. The existing task does not reconfigure these automatically. Editing the original JSON in the package does not change the runtime copy.

The WG interface has `10.77.0.1/25`; this reservation does not extend into the OpenVPN subnets. A new peer gets, for example, `10.77.0.4/32`, rather than the whole `/24` in its server-side AllowedIPs. Do not give every peer `0.0.0.0/0` on the server. Two clients active at the same time must not share a key or address. Alternative IPv4/IPv6 endpoint profiles for the same device may share its key only if they are activated one at a time.

## 4. Connect the client and test the whole path

Import the client's own profile into the WireGuard client and activate it deliberately. The default `AllowedIPs = 0.0.0.0/0` sends IPv4 through the server. For an initial limited test, you can temporarily set only `10.77.0.0/24` on the client, then restore `0.0.0.0/0` after verifying the tunnel.

1. Watch `wg show wg-server` on the server. A new handshake and increasing counters confirm contact and the correct identity.
2. From the client, test `10.77.0.1` and an existing permitted service on the server. A response verifies traffic through the tunnel; a handshake alone does not guarantee this.
3. From the client, test an approved external IPv4 destination, then DNS separately. Corresponding sessions should appear in `Get-NetNatSession` during traffic.
4. Test prohibited destinations too, especially server management and other clients. The VPN should not automatically grant access to the whole LAN.

If the tunnel works but internet access does not, check forwarding, NAT, the firewall and the return path using the [troubleshooting chapter](07-Troubleshooting-and-recovery.md). Generating new keys usually does not fix this type of fault.

## 5. Add IPv6 and change MTU only as needed

An endpoint using a literal IPv6 address looks like `[2001:db8:100::10]:51820`. The generator accepts a DNS name; you can enter a literal address manually in the protected configuration. This is the outer transport. To carry IPv6 inside the tunnel, add a separate assigned address to the tunnel, a `/128` to the peer's server-side AllowedIPs, and routing as described in the [IPv6 chapter](05-IPv6.md). Without the corresponding configuration, client IPv6 may continue to use its original connection outside the IPv4 tunnel.

The generator uses a conservative MTU of 1280. Measurements in your environment may allow more. With a link MTU of 1492 and outer IPv6, the basic WG overhead is 80 B, leaving an MTU of 1412. The basic overhead for outer IPv4 is 60 B. Do not automatically copy an MTU of 1420 from a desktop profile to every mobile or IPv6 path. [Details and measurements](06-MTU-and-performance.md).

## 6. Keep track of access

Before editing a `.conf` file, make a protected backup. Changing the file does not guarantee that the running tunnel has changed. During a maintenance window, restart the specific service and verify the current public keys, AllowedIPs and handshake. Do not edit the same tunnel in both the GUI and a standalone tunnel service at the same time.

To revoke a peer's access, remove its public key from the server and apply the configuration. If the server's private key is exposed, replace the server key pair and securely update the server's public key on every client. Never print `wg show all dump`, `wg showconf` or `wg ... private-key` to a public log; some commands can contain secret values.

Once the tunnel and IPv4 internet access work, you can add [OpenVPN with certificate-based identities and a TCP option](03-OpenVPN.md).
