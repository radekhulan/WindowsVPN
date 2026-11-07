# Official sources and verification scope

These sources were checked on November 7, 2026. For a later installation, check for current fixes and documentation changes. The links describe the products and commands. You still need to measure how the components work together in your specific deployment.

| Source | What it is used for |
| --- | --- |
| [WireGuard install](https://www.wireguard.com/install/) | official distribution |
| [WireGuard Windows enterprise](https://git.zx2c4.com/wireguard-windows/about/docs/enterprise.md) | MSI, tunnel service, standard conf and ACLs |
| [WireGuard protocol](https://www.wireguard.com/protocol/) | data encapsulation |
| [OpenVPN Community](https://openvpn.net/community/) | current Windows installers; version 2.7.9 at verification |
| [OpenVPN ReleaseHistory](https://community.openvpn.net/ReleaseHistory) | security fixes and changes in 2.7 |
| [OpenVPN 2.7 status](https://community.openvpn.net/Development/StatusOfOpenvpn27) | removal of Wintun, DCO server and related changes |
| [OpenVPN windows-driver removal](https://patchwork.openvpn.net/project/openvpn2/patch/20251210074904.27067-1-gert%40greenie.muc.de/) | removal of the windows-driver option |
| [OpenVPN 2.7 manual](https://openvpn.net/community-docs/community-articles/openvpn-2-7-manual/) | configuration, pools, IPv6 and DCO limitations |
| [OpenVPN Windows service](https://openvpn.net/community-docs/running-openvpn-as-a-windows-service/) | automatic service and profiles; check the new log/ACL behavior in 2.7 |
| [Windows DCO releases](https://github.com/OpenVPN/ovpn-dco-win/releases) | release 2.8.14 at verification, including a security fix |
| [Easy-RSA](https://github.com/OpenVPN/easy-rsa) | an alternative for managing VPN PKI |
| [OpenSSL ca](https://docs.openssl.org/3.5/man1/openssl-ca/) | CA database, signing and CRLs |
| [OpenSSL req](https://docs.openssl.org/3.5/man1/openssl-req/) | CSRs, keys and requests |
| [Windows NAT network](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/setup-nat-network) | a single WinNAT internal prefix and conflicts between multiple NATs |
| [RRAS installation](https://learn.microsoft.com/en-us/windows-server/remote/remote-access/get-started-install-ras-as-vpn?tabs=powershell) | roles, IKEv2 ports, pool and Server 2025 differences |
| [Remote Access overview](https://learn.microsoft.com/en-us/windows-server/remote/remote-access/remote-access) | Routing role and platform support |
| [VPN authentication](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/vpn/vpn-authentication) | EAP and PEAP, server validation |
| [EAP network access](https://learn.microsoft.com/en-us/windows-server/networking/technologies/extensible-authentication-protocol/network-access) | EAP XML and name/root checks |
| [PEAP schema](https://learn.microsoft.com/en-us/windows/win32/eaphost/mspeapconnectionpropertiesv1schema-servervalidationparameters-complextype) | fail-closed validation without user approval |
| [Set-VpnAuthProtocol](https://learn.microsoft.com/en-us/powershell/module/remoteaccess/set-vpnauthprotocol) | the actual scope of S2S parameters |
| [Set-VpnServerConfiguration](https://learn.microsoft.com/en-us/powershell/module/remoteaccess/set-vpnserverconfiguration) | server IPsec policy |
| [Set-VpnConnectionIPsecConfiguration](https://learn.microsoft.com/en-us/powershell/module/vpnclient/set-vpnconnectionipsecconfiguration) | client policy |
| [Netsh RAS](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-ras) | static pool and WAN port syntax |
| [NPS export](https://learn.microsoft.com/en-us/windows-server/networking/technologies/nps/nps-manage-export) | backup, plaintext secrets and restore scope |
| [Set-NetOffloadGlobalSetting](https://learn.microsoft.com/en-us/powershell/module/nettcpip/set-netoffloadglobalsetting) | global RSC |
| [Pktmon syntax](https://learn.microsoft.com/en-us/windows-server/networking/technologies/pktmon/pktmon-syntax) | component capture and drop diagnostics |
| [WinDivert release](https://github.com/basil00/WinDivert/releases/tag/v2.2.2) | manually obtaining the official 2.2.2-A release |
| [WinDivert documentation](https://github.com/basil00/WinDivert/blob/master/doc/windivert.html) | narrow capture scope, driver and signatures |
| [WinDivert flags](https://github.com/basil00/WinDivert/blob/master/include/windivert.h) | SNIFF/RECV_ONLY/NO_INSTALL values |
| [RFC 4861](https://www.rfc-editor.org/rfc/rfc4861) | Neighbor Discovery and NS/NA validation |

The guidance on RRAS and WinNAT, OpenVPN IPv6 assignments and RSC troubleshooting applies to the topology described here. Validate these behaviors in your own environment; they are not universal Windows limitations. Examples use generic addresses, names and certificate identities, with placeholders for secret keys.
