#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Name = 'Example IKEv2',
    [ValidatePattern('^[a-zA-Z0-9.-]+$')][string]$ServerName = 'vpn.example.com',
    [Parameter(Mandatory = $true)][string]$PublicRootCertificate,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedRootFileSha256,
    [switch]$SplitTunneling,
    [switch]$UpdateExisting,
    [switch]$Apply
)
. (Join-Path $PSScriptRoot 'Common.ps1')
if ((Get-FileHash -LiteralPath $PublicRootCertificate -Algorithm SHA256).Hash -ne $ExpectedRootFileSha256) { throw 'Root certificate file SHA256 mismatch.' }
$root = New-Object Security.Cryptography.X509Certificates.X509Certificate2((Resolve-Path -LiteralPath $PublicRootCertificate).Path)
$basic = @($root.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' })
if ($root.HasPrivateKey -or $basic.Count -ne 1 -or -not $basic[0].CertificateAuthority -or $root.Subject -ne $root.Issuer -or $root.NotAfter -lt (Get-Date) -or $root.NotBefore -gt (Get-Date)) { throw 'Expected a valid public root CA certificate, without private key.' }
$registry = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\RasMan\Parameters' -ErrorAction SilentlyContinue
if ($registry -and $registry.PSObject.Properties['DisableIKENameEkuCheck'] -and $registry.DisableIKENameEkuCheck -ne 0) { throw 'Machine-wide IKE name/EKU validation is weakened. Audit all VPN profiles before changing the global setting.' }
$existing = Get-VpnConnection -Name $Name -ErrorAction SilentlyContinue
if ($existing -and [string]$existing.ConnectionStatus -ne 'Disconnected') { throw 'Disconnect this VPN manually before profile maintenance.' }
if ($existing -and -not $UpdateExisting) { throw 'Profile exists. Review backup and use UpdateExisting for an intentional update.' }
$thumb = $root.Thumbprint -replace '(..)(?!$)', '$1 '
[xml]$eap = @"
<EapHostConfig xmlns="http://www.microsoft.com/provisioning/EapHostConfig">
 <EapMethod><Type xmlns="http://www.microsoft.com/provisioning/EapCommon">25</Type><VendorId xmlns="http://www.microsoft.com/provisioning/EapCommon">0</VendorId><VendorType xmlns="http://www.microsoft.com/provisioning/EapCommon">0</VendorType><AuthorId xmlns="http://www.microsoft.com/provisioning/EapCommon">0</AuthorId></EapMethod>
 <Config><Eap xmlns="http://www.microsoft.com/provisioning/BaseEapConnectionPropertiesV1"><Type>25</Type><EapType xmlns="http://www.microsoft.com/provisioning/MsPeapConnectionPropertiesV1">
 <ServerValidation><DisableUserPromptForServerValidation>true</DisableUserPromptForServerValidation><ServerNames>$ServerName</ServerNames><TrustedRootCA>$thumb</TrustedRootCA></ServerValidation>
 <FastReconnect>true</FastReconnect><InnerEapOptional>false</InnerEapOptional>
 <Eap xmlns="http://www.microsoft.com/provisioning/BaseEapConnectionPropertiesV1"><Type>26</Type><EapType xmlns="http://www.microsoft.com/provisioning/MsChapV2ConnectionPropertiesV1"><UseWinLogonCredentials>false</UseWinLogonCredentials></EapType></Eap>
 <EnableQuarantineChecks>false</EnableQuarantineChecks><RequireCryptoBinding>true</RequireCryptoBinding>
 <PeapExtensions><PerformServerValidation xmlns="http://www.microsoft.com/provisioning/MsPeapConnectionPropertiesV2">true</PerformServerValidation><AcceptServerName xmlns="http://www.microsoft.com/provisioning/MsPeapConnectionPropertiesV2">true</AcceptServerName></PeapExtensions>
 </EapType></Eap></Config>
</EapHostConfig>
"@
if (-not $Apply) { Write-Output 'Plan: trust verified public CA in LocalMachine Root and create/update current-user IKEv2 profile with PEAP25/MSCHAPv2 inner26, explicit name/root validation. No connection or saved credentials.'; return }
Assert-Administrator
if (-not $PSCmdlet.ShouldProcess($Name, 'Back up profile, install public CA and configure IKEv2 EAP')) { return }
$backup = New-VpnBackup 'IKEv2-Client'
if ($existing) { $existing | Export-Clixml -LiteralPath (Join-Path $backup 'profile.xml') }
$alreadyTrusted = Test-Path -LiteralPath ('Cert:\LocalMachine\Root\' + $root.Thumbprint)
Write-VpnUtf8 (Join-Path $backup 'root-before.json') (@{ WasTrusted = $alreadyTrusted; Thumbprint = $root.Thumbprint } | ConvertTo-Json)
if (-not $alreadyTrusted) { $null = Import-Certificate -FilePath $PublicRootCertificate -CertStoreLocation 'Cert:\LocalMachine\Root' }
$parameters = @{ Name = $Name; ServerAddress = $ServerName; TunnelType = 'Ikev2'; AuthenticationMethod = 'Eap'; EncryptionLevel = 'Required'; EapConfigXmlStream = $eap; SplitTunneling = [bool]$SplitTunneling; RememberCredential = $false; Force = $true }
if ($existing) { $null = Set-VpnConnection @parameters } else { $null = Add-VpnConnection @parameters }
Write-VpnUtf8 (Join-Path $backup 'eap-config.xml') $eap.OuterXml
Write-Output "Configured current-user profile with validated server identity. Backup: $backup. Connect manually."
