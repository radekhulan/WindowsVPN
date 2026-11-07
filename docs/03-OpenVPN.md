# OpenVPN Community: UDP with DCO and TCP with TAP

Add OpenVPN once you understand the tunnel addresses and have verified IPv4 NAT. UDP with DCO is the primary option; a separate TCP profile provides an alternative on networks that restrict UDP. Each server uses its own subnet, while both share the WinNAT instance prepared in the previous chapter.

DCO moves data traffic processing into the driver. The TCP option here uses regular OpenVPN processing and a TAP-Windows6 virtual adapter. This difference concerns the server's data path. Both options serve the same purpose for users, and each requires a properly validated client certificate.

## 1. Prepare the correct drivers and service

This guide uses OpenVPN 2.7.9 and DCO 2.8.14 as its starting point. Before installation, check the current signed updates and their compatibility. The UDP profile uses DCO. The TCP profile deliberately retains `disable-dco` and TAP-Windows6. The command `tapctl create --hwid root\tap0901 --name VPN-TCP` creates a TAP adapter even though the configuration uses routed `dev tun`. Using `dev tap` would change the tunnel type and is not a substitute. [OpenVPN Community](https://openvpn.net/community/), [DCO releases](https://github.com/OpenVPN/ovpn-dco-win/releases).

OpenVPN 2.7 no longer supports Wintun or `windows-driver`. Remove these directives from migrated profiles. Do not add unrecognized options to `ignore-unknown-option` simply to make the configuration pass validation. [OpenVPN 2.7 changes](https://community.openvpn.net/Development/StatusOfOpenvpn27), [removal of windows-driver](https://patchwork.openvpn.net/project/openvpn2/patch/20251210074904.27067-1-gert%40greenie.muc.de/).

The automatic startup service loads every `.ovpn` file in `Program Files\OpenVPN\config-auto`. Any old profiles left there would also start. Inventory them first, then move them out of the automatic startup directory during a maintenance window, retaining a protected backup. Leave unrelated VPNs alone. [OpenVPN service](https://openvpn.net/community-docs/running-openvpn-as-a-windows-service/).

## 2. Create a CA and prepare certificates

Each client needs its own certificate and private key. Keep the CA private key on a separate protected or offline signing computer. The server receives only the public CA certificate, its own server certificate and private key, the current CRL, and `tls-crypt.key`. Each client receives the public CA certificate, its own certificate/key, and the shared tls-crypt key. A client **never** needs the server's `.key`, the CA private key, or the server PFX.

You can use an existing organizational PKI or [official Easy-RSA](https://github.com/OpenVPN/easy-rsa). The following standalone option uses a local OpenSSL installation and `config/openssl-ca.cnf.example`. Before using it, replace the server's SAN and CN with your actual endpoint. Adapt certificate policy, validity periods, key protection, and revocation distribution to your PKI. This procedure does not provide automatic certificate renewal.

On the isolated CA computer, open PowerShell in a new protected directory. Copy the configuration as `ca.cnf`, set the actual DNS name in the SAN, and prepare the database. The following commands create secret files, so run them in your private PKI directory, not in the public package:

```powershell
$openssl = Read-Host 'Full path to a trusted openssl.exe'
foreach ($existing in @('ca.key','ca.crt','index.txt','serial','crlnumber','newcerts')) {
    if (Test-Path -LiteralPath $existing) { throw 'The CA already contains state. Do not initialize it again.' }
}
$null = New-Item -ItemType Directory -Path .\newcerts
$null = New-Item -ItemType File -Path .\index.txt
Set-Content -LiteralPath .\serial -Value '1000' -Encoding Ascii
Set-Content -LiteralPath .\crlnumber -Value '1000' -Encoding Ascii
& $openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -aes-256-cbc -out .\ca.key
if ($LASTEXITCODE -ne 0) { throw 'CA key generation failed' }
& $openssl req -new -x509 -sha256 -days 3650 -key .\ca.key -out .\ca.crt -config .\ca.cnf
if ($LASTEXITCODE -ne 0) { throw 'CA certificate generation failed' }
```

The CA key password is entered interactively. Do not pass it as a command-line argument. On the VPN server, create the server CSR and private key in a protected working directory. The service needs unattended access to the key, so this example uses an unencrypted server PEM key protected by NTFS ACLs. If you use another mechanism, choose a supported provider and verify DCO compatibility.

```powershell
$openssl = Read-Host 'Full path to a trusted openssl.exe'
& $openssl req -new -newkey rsa:3072 -sha256 -noenc -keyout .\server.key -out .\server.csr -subj '/CN=vpn.example.com'
if ($LASTEXITCODE -ne 0) { throw 'Server CSR failed' }
```

After success, `server.key` and `server.csr` should exist. The private key stays on the server. Create a separate CSR on the client. The following option prompts for a client key password; first verify that your chosen client supports using it:

```powershell
$openssl = Read-Host 'Full path to a trusted openssl.exe'
& $openssl req -new -newkey rsa:3072 -sha256 -keyout .\client-desktop.key -out .\client-desktop.csr -subj '/CN=client-desktop'
if ($LASTEXITCODE -ne 0) { throw 'Client CSR failed' }
```

Transfer only the CSRs to the CA. Sign each CSR with the correct role on the CA computer. A `.csr` file is not a trusted identity by itself; the administrator must approve the requester and CN:

```powershell
& $openssl ca -config .\ca.cnf -extensions vpn_server -in .\server.csr -out .\server.crt -notext
if ($LASTEXITCODE -ne 0) { throw 'Server certificate signing failed' }
& $openssl ca -config .\ca.cnf -extensions vpn_client -in .\client-desktop.csr -out .\client-desktop.crt -notext
if ($LASTEXITCODE -ne 0) { throw 'Client certificate signing failed' }
& $openssl ca -config .\ca.cnf -gencrl -out .\crl.pem
if ($LASTEXITCODE -ne 0) { throw 'CRL generation failed' }
& $openssl verify -CAfile .\ca.crt -purpose sslserver .\server.crt
if ($LASTEXITCODE -ne 0) { throw 'Server EKU/chain verification failed' }
& $openssl verify -CAfile .\ca.crt -purpose sslclient .\client-desktop.crt
if ($LASTEXITCODE -ne 0) { throw 'Client EKU/chain verification failed' }
```

Run all signing commands from the CA directory because `dir = .` is relative to the current location. Expect the certificates and CRL to be created and both verification commands to return `OK`. Initialize the database and serial/crlnumber only once. During renewal, do not delete the index or recreate the CA; preserve the revocation history. [OpenSSL ca](https://docs.openssl.org/3.5/man1/openssl-ca/), [OpenSSL req](https://docs.openssl.org/3.5/man1/openssl-req/).

On the server, generate the tls-crypt key in a protected working directory:

```powershell
& (Join-Path $env:ProgramFiles 'OpenVPN\bin\openvpn.exe') --genkey tls-crypt .\tls-crypt.key
if ($LASTEXITCODE -ne 0) { throw 'tls-crypt key generation failed' }
```

TLS-crypt protects the control channel; client certificates are still required. If a client is compromised, revoke its certificate with `openssl ca -revoke`, generate a new CRL, and deliver it securely to the server. Renew the CRL regularly before its `nextUpdate` time. An expired CRL can prevent users from connecting. Renewal scheduling and alerts are operational responsibilities, not automatic features of the staging script provided here.

## 3. Prepare the files and verify the worker account

Prepare a private source directory containing exactly five files: `ca.crt`, `server.crt`, `server.key`, `crl.pem`, and `tls-crypt.key`. Do not put `ca.key` there. The source directory must have ACLs as strict as the destination PKI. Before staging, verify that the certificate and key match, for example by comparing their public keys with `openssl x509 -pubkey` and `openssl pkey -pubout`. You may hash the public key; do not print the private key.

OpenVPN 2.7 uses restricted privileges. This guide calls the process that actually handles VPN connections the worker. **Verify its identity for the installed MSI**, rather than relying solely on the account of the service that launches it. The installation script therefore requires `-WorkerAccount`, which it resolves to a SID on the local system. It grants only read access to PKI and profiles, with write access to a separate log directory. It does not solve missing read access by granting Users or Everyone access to the entire PKI, nor does it automatically switch the worker back to SYSTEM.

The script accepts only an individual account that can be verified, the exact OpenVPN virtual service identity, or a standard system service account. **It rejects all groups, including BUILTIN groups and IIS_IUSRS.** Acceptance by the script does not prove that the worker actually uses that account. Before stopping an existing installation, you can verify the process identity with `Get-CimInstance Win32_Process` and `Invoke-CimMethod -MethodName GetOwnerSid`, or with an approved process manager. For a fresh installation, start with verified documentation for the MSI, then repeat the check on the running worker. Do not grant read access to additional accounts by trial and error.

```powershell
Get-CimInstance Win32_Service -Filter "Name='OpenVPNService'" | Select-Object Name, StartName, PathName
Get-CimInstance Win32_Process -Filter "Name='openvpn.exe'" | ForEach-Object {
    $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid
    [pscustomobject]@{ ProcessId = $_.ProcessId; OwnerSid = $owner.Sid }
}
```

Expect the SID of the actual `openvpn.exe` process. It may differ from the service account shown by the first command. On a fresh installation without a running worker, verify the identity against the documentation for the installed version, then repeat the check after startup. Correct an incorrect account specifically rather than broadening access to the entire PKI.

## 4. Deploy the UDP and TCP profiles

First inventory the other profiles in `config-auto`. During a maintenance window, stop the automatic service; the script checks that it is stopped even during planning. The following `Stop-Service` is a real operational change and interrupts its existing connections.

```powershell
Stop-Service OpenVPNService
$worker = Read-Host 'Verified OpenVPN worker account for this installation'
$pkiSource = Read-Host 'Protected directory containing the server PEM files'
$dns = Read-Host 'DNS resolver reachable by clients'
.\scripts\Install-OpenVpnConfiguration.ps1 -PkiSourceDirectory $pkiSource -WorkerAccount $worker -DnsServer $dns
.\scripts\Install-OpenVpnConfiguration.ps1 -PkiSourceDirectory $pkiSource -WorkerAccount $worker -DnsServer $dns -Apply -WhatIf
.\scripts\Install-OpenVpnConfiguration.ps1 -PkiSourceDirectory $pkiSource -WorkerAccount $worker -DnsServer $dns -Apply
```

After applying the configuration, expect two profiles, protected runtime PKI/log directories, and a `VPN-TCP` TAP adapter if needed. The script does not start the service. It stops if an adapter name or configuration already exists, so it does not take over unrelated objects. After checking ACLs and all other `.ovpn` files in `config-auto`, start the service deliberately:

```powershell
Start-Service OpenVPNService
Get-Content -LiteralPath (Join-Path $env:ProgramData 'WindowsVPN\OpenVPN\Log\udp.log') -Tail 60
Get-Content -LiteralPath (Join-Path $env:ProgramData 'WindowsVPN\OpenVPN\Log\tcp.log') -Tail 60
Get-NetIPAddress -IPAddress 10.77.0.129,10.77.0.193
```

Look for completed initialization, the DCO version, and the appropriate UDP adapter. TCP should use TAP `VPN-TCP` and address `.193`; UDP uses `.129`. Do not reuse a DCO GUID or alias from a previous installation. The routing task locates the interface by its actual server-side tunnel IPv4 address.

If you already prepared all three tunnel addresses and endpoint rules in the previous chapter, simply rerun the routing task:

```powershell
Start-ScheduledTask -TaskName 'WindowsVPN-Routing'
Get-ScheduledTaskInfo -TaskName 'WindowsVPN-Routing'
```

If the original installation was WG-only, first deliberately extend the protected routing JSON and the corresponding firewall rules. Rerunning `Set-VpnNetworking.ps1` with different input does not reconfigure the existing task. Keep a single WinNAT for `10.77.0.0/24`; do not create another NAT for OpenVPN.

## 5. Connect a client and test both protocols

In `config/openvpn-client.ovpn.example`, replace the client certificate/key name and the actual endpoint. The server certificate must have the approved name, shown here as CN `vpn.example.com`. `remote-cert-tls server` checks its role, while `verify-x509-name ... name` checks the expected CN. A DNS SAN is useful for other uses of the certificate, but it is not a replacement for this specific OpenVPN CN check. Do not skip validation to work around a certificate problem.

For a TCP copy, set `proto tcp4-client`, change the port to `1195`, and add `disable-dco`. On Windows, the client needs an available TAP-Windows6 adapter. For an outer IPv6 connection, you can create a separate profile using `udp6` or `tcp6-client` and a corresponding server listener. The default templates use IPv4 transport. They do not guarantee public IPv6 inside the tunnel. Introduce and test the IPv6 listener and IPv6 payload separately.

Two separate server processes make it easier to separate UDP/DCO from TCP/TAP. Do not infer TCP capacity from a UDP benchmark; TCP-over-TCP behaves differently under packet loss. Compression is disabled, and this design does not automatically fall back to old CBC ciphers or obsolete clients.

Activate only the UDP profile first. Expect successful certificate validation, an address from the UDP pool, and connectivity to the server at `10.77.0.129`. Then verify external IPv4 TCP connectivity and DNS. Disconnect UDP and repeat the same tests over TCP, whose server address is `10.77.0.193`. On the server, monitor the corresponding log and WinNAT sessions during internet traffic. This prevents a second active connection from masking a problem with the profile under test.

Issue a separate certificate to each additional device and prepare access revocation through the CRL. If you need a native Windows connection instead of an OpenVPN client, continue with [IKEv2 through RRAS](04-IKEv2.md).
