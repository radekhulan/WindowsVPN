# IKEv2/IPsec through RRAS and NPS

IKEv2 is useful when you want to use the built-in Windows VPN client. On the server, opening a port or creating a client profile is not enough. RRAS terminates the tunnel, NPS makes authentication decisions, and RRAS NAT provides IPv4 internet access. The following procedure prepares these components separately so that you can verify each one.

With password-based authentication, the client first validates the server certificate. The user then authenticates with EAP-MSCHAPv2 inside the protected PEAP exchange. Checking the correct certificate name and root therefore also protects the credentials. Do not disable validation to work around a certificate error.

## 1. Install the server roles

IKEv2 requires running RRAS and IPsec services, an authentication policy, and a working data path. Creating a Windows VPN profile or a PowerShell listener does not create an IKEv2 server. This guide uses the **DirectAccess-VPN, Routing, and NPAS** roles, a separate `10.78.0.0/24` pool, and RRAS NAT. Keep the Routing role installed because it provides the RRAS NAT data path.

```powershell
.\scripts\Install-Ikev2Roles.ps1 -WanAlias Ethernet
.\scripts\Install-Ikev2Roles.ps1 -WanAlias Ethernet -Apply -WhatIf
.\scripts\Install-Ikev2Roles.ps1 -WanAlias Ethernet -Apply
```

The script installs the prerequisites and opens UDP 500/4500 only on the selected WAN interface. It does not reinitialize an existing RRAS installation or change NPS policies. Also check the upstream firewall and, for connections without NAT-T, allow ESP (IP protocol 50) as required by your topology. Do not enable older tunneling protocols alongside IKEv2 simply for convenience.

After installation, verify that `rrasmgmt.msc` and `nps.msc` are available. If installation requires a restart, schedule it before continuing. An installed role does not yet mean that the server accepts clients.

## 2. Prepare a certificate for the actual server name

Obtain a certificate with DNS SAN `vpn.example.com`, the **Server Authentication** EKU (`1.3.6.1.5.5.7.3.1`), and the corresponding private key. Install it in `LocalMachine\My` on the VPN server. The public chain must be trusted and complete, with reachable revocation information. Explicitly select the NPS/PEAP certificate in the NPS policy. This simple design assumes that PEAP runs on the same server and validates the same DNS name. A separate RADIUS server may require a different PEAP name and root, which must be included in the client's validation settings.

```powershell
$pfx = Read-Host 'Protected path to the server PFX'
$password = Read-Host 'PFX password' -AsSecureString
Import-PfxCertificate -FilePath $pfx -CertStoreLocation 'Cert:\LocalMachine\My' -Password $password
Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, DnsNameList, HasPrivateKey, NotAfter, EnhancedKeyUsageList
```

Importing the certificate is a **real manual change**, not a diagnostic check. Do not use `-Exportable` unless an approved recovery procedure requires it. Do not send the PFX or its password to clients. Grant private key access only to the system services that need it, then verify a successful signature/handshake. `HasPrivateKey = true` alone does not prove that the process has permission to use the key.

Do not fix an incorrect CA by disabling validation. Two CAs with the same CN can have different keys. Identify the exact certificate by its thumbprint and public key, check the relationship between the leaf certificate and issuer through AKI/SKI, and verify the actual signature/chain. Subject/CN alone is insufficient. Do not delete a CA by name. OpenVPN PEM PKI is independent of Windows certificate stores; removing a Windows certificate does not revoke or automatically delete PEM files.

RRAS selection of the IKE certificate and NPS selection of the PEAP certificate are separate steps. `Set-VpnAuthProtocol -CertificateAdvertised` is documented for S2S authentication and is not presented here as a universal certificate binding for all user IKEv2 connections. On a machine with multiple candidate certificates, verify the certificate actually offered through client/server IKE events and, if necessary, a capture. Do not delete other valid leaf certificates without first inventorying their dependencies. [Set-VpnAuthProtocol](https://learn.microsoft.com/en-us/powershell/module/remoteaccess/set-vpnauthprotocol).

## 3. Configure RRAS, address assignment, and user authentication

The following steps are for a new installation. On an existing server, first [back up RRAS/NPS](07-Troubleshooting-and-recovery.md) and record the current pools, NAT interfaces, and active sessions. Do not rerun the initialization wizard over a running configuration.

1. Open `rrasmgmt.msc`, select the server, and start the Routing and Remote Access configuration wizard. Choose a custom configuration with VPN access and NAT, and enable the required IPv4 routing. In the IPv4 properties, set a static pool from `10.78.0.10` to `10.78.0.200`. RRAS also uses part of the pool for its own interface, so do not assume that the server has `.1`.
2. Under Ports, enable **only WAN Miniport (IKEv2)** with the required number of incoming ports. Disable both incoming and demand-dial access for PPTP, L2TP, and SSTP. Check the state again after upgrades; fresh Server 2025 installations have different PPTP/L2TP defaults from older configurations.
3. Under IPv4 -> NAT, add the actual WAN as a public interface with NAT, and RRAS Internal as a private interface. Do not add OpenVPN or WireGuard to this NAT. Do not reuse old GUIDs belonging to adapters that no longer exist.
4. Under RRAS Security, use approved EAP authentication through local NPS or an explicitly managed RADIUS server. In NPS, create an allow policy restricted to a group of authorized users and VPN access. Do not create a blanket allow rule for all accounts.
5. Under Constraints -> Authentication Methods, enable PEAP with inner EAP-MSCHAPv2 for password-based authentication. Edit the PEAP settings and select the exact valid server certificate. Do not enable outer, unprotected MSCHAPv2, PAP, or CHAP. Use long, unique passwords, account lockout, and monitoring of failed attempts. If your infrastructure supports managed client certificates, consider EAP-TLS.

After completing these steps, you should see your static pool, enabled incoming IKEv2 ports, the public WAN and private Internal interfaces in RRAS NAT, and a specific NPS allow policy. Check the NPS policy order so that a broader rule does not take precedence. On a domain server, also verify that NPS can read the required AD information. The official [RRAS guide](https://learn.microsoft.com/en-us/windows-server/remote/remote-access/get-started-install-ras-as-vpn?tabs=powershell) covers installation, pools, and individual ports.

## 4. Check and configure the pool, ports, and RRAS NAT with a script

After initializing VPN access and IPv4 NAT in MMC, you can configure the pool, ports, and two NAT interfaces with a script. `Set-Ikev2Server.ps1` requires the exact server certificate thumbprint from your own store and checks the private key, exact SAN, EKU, and validity dates. It does not import a PFX or change IKE/PEAP certificate selection, and it does not treat metadata as proof of complete chain/revocation validation. NPS/PEAP configuration remains the explicit step described above.

```powershell
$serverThumb = Read-Host 'Thumbprint of the approved server certificate in LocalMachine My'
.\scripts\Set-Ikev2Server.ps1 -WanAlias Ethernet -ServerName vpn.example.com -CertificateThumbprint $serverThumb
.\scripts\Set-Ikev2Server.ps1 -WanAlias Ethernet -ServerName vpn.example.com -CertificateThumbprint $serverThumb -Apply -WhatIf
.\scripts\Set-Ikev2Server.ps1 -WanAlias Ethernet -ServerName vpn.example.com -CertificateThumbprint $serverThumb -Apply
```

The script rejects active RRAS clients, a different existing pool, and additional or differently configured RRAS NAT interfaces. It does not add identical existing assignments again. It creates protected RRAS and NPS exports and records the previous IPsec policy metadata. **NPS XML contains plaintext RADIUS shared secrets** if they are configured; keep the file in the protected backup and never publish it or transfer it unencrypted. The script enables incoming IKEv2, disables the other three VPN miniports including demand-dial, sets the pool to `.10` through `.200`, and configures exactly WAN FULL / RRAS Internal PRIVATE. The shared WinNAT is unchanged. Check nonstandard localized miniport or RRAS Internal names on the local system; you can pass the Internal name with `-RrasInternalName`.

The script does not restart RemoteAccess automatically. Do that during a maintenance window after completing NPS configuration and verifying the changes. The script stops when a command fails, but it may not undo earlier steps that have already succeeded. Use the prepared backup and console access. Rerunning it without investigating the partial state is not an automatic rollback. Pool and port syntax follows the [netsh ras documentation](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-ras).

After approving the configuration, perform the actual service restart and check its dependencies:

```powershell
Restart-Service RemoteAccess
Get-Service RemoteAccess,IKEEXT,PolicyAgent,IAS | Select-Object Name,Status,StartType
```

Expect RRAS and the IPsec services to be running, along with IAS when using local NPS. Investigate startup failures through service and certificate events first, rather than disabling certificate validation.

## 5. Create a Windows client with server validation

The client needs to trust the public CA in `LocalMachine\Root`; it does **not** need the server's private key. Verify the CA certificate independently and transfer its file through a trusted channel. The included script accepts the SHA256 of that specific public file and uses the thumbprint of the CA it actually loads inside EAP. It validates the server name, root, and chain through PEAP and prevents the user from approving an unverified server. [VPN authentication](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/vpn/vpn-authentication), [PEAP validation](https://learn.microsoft.com/en-us/windows/win32/eaphost/mspeapconnectionpropertiesv1schema-servervalidationparameters-complextype).

```powershell
$publicCa = Read-Host 'Path to the public root certificate CER file only'
$approvedCaHash = Read-Host 'Independently verified SHA256 of the CER file'
.\scripts\New-Ikev2Client.ps1 -ServerName vpn.example.com -PublicRootCertificate $publicCa -ExpectedRootFileSha256 $approvedCaHash
.\scripts\New-Ikev2Client.ps1 -ServerName vpn.example.com -PublicRootCertificate $publicCa -ExpectedRootFileSha256 $approvedCaHash -Apply -WhatIf
.\scripts\New-Ikev2Client.ps1 -ServerName vpn.example.com -PublicRootCertificate $publicCa -ExpectedRootFileSha256 $approvedCaHash -Apply
```

The script uses the current user, so run it elevated as the same account that will use the VPN. It does not automatically create an all-user profile, save a password, connect the VPN, or disconnect it. To change an existing disconnected profile, it requires `-UpdateExisting` and backs up the profile first. The `-SplitTunneling` switch requires explicit destination routes afterward. By default, IPv4 traffic goes through the server, which requires working NAT and DNS.

If the machine has the global setting `DisableIKENameEkuCheck = 1`, the script stops. This setting is not recommended. First inventory **all** existing IKE profiles and their SAN/EKU requirements, because correcting the setting also affects other connections. After fixing certificates and names, enable strict validation in a separate, reversible step and test every profile. The script does not change the global switch itself.

After applying the configuration, expect the `Example IKEv2` profile and trust in the exact public root. Connect manually as the user who owns the profile. The client should validate the DNS name and root of the server certificate. A prompt to approve an unknown server is not an expected part of signing in.

## 6. Verify authentication, internet access, and matching IPsec policies

Check the negotiated algorithms on a real connection. Any optional policy hardening must match on the server and client and remain compatible with all supported devices. Changing the server policy has a broader impact and needs its own maintenance window. The example uses AES256/SHA256 and DH14; it does not claim that every platform accepts every combination:

```powershell
Get-VpnServerConfiguration
Set-VpnServerConfiguration -CustomPolicy -EncryptionMethod AES256 -IntegrityCheckMethod SHA256 -DHGroup Group14 -CipherTransformConstants AES256 -AuthenticationTransformConstants SHA256128 -PfsGroup PFS2048 -WhatIf
Set-VpnConnectionIPsecConfiguration -ConnectionName 'Example IKEv2' -EncryptionMethod AES256 -IntegrityCheckMethod SHA256 -DHGroup Group14 -CipherTransformConstants AES256 -AuthenticationTransformConstants SHA256128 -PfsGroup PFS2048 -WhatIf
```

Removing `-WhatIf` is a deliberate change to make only after backing up and verifying support. Once connected, check authentication, the assigned address, tunnel TCP traffic, and internet access separately. RRAS NAT sessions differ from `Get-NetNatSession`, which lists WinNAT sessions. An absent WinNAT session therefore does not indicate a fault in this recommended IKEv2 data path.

Public IPv6 through IKEv2 is **not a verified, complete procedure here**. The design for your own routed `/64` and its test conditions are in the [IPv6 chapter](05-IPv6.md). Do not treat an assigned ULA, an IPv6 endpoint, or a successful IKE handshake as proof of public IPv6 internet access inside the VPN.

A successful IPv4 test should produce three separate results: NPS allows the correct user, the client receives an address from the RRAS pool, and external IPv4 TCP traffic passes through RRAS NAT. Also verify rejection of an account outside the authorized group and an incorrect server certificate. Only then continue with [IPv6](05-IPv6.md) or [operational tests](07-Troubleshooting-and-recovery.md).
