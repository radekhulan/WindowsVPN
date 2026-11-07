#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][ValidateSet('WireGuard', 'OpenVPN')][string]$Product,
    [Parameter(Mandatory = $true)][string]$MsiPath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256,
    [switch]$Apply
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$file = Get-Item -LiteralPath $MsiPath
if ($file.Extension -ne '.msi') { throw 'A local MSI is required.' }
if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $ExpectedSha256) { throw 'SHA256 mismatch.' }
$signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
$publisher = if ($Product -eq 'WireGuard') { 'WireGuard' } else { 'OpenVPN' }
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch [regex]::Escape($publisher)) { throw 'MSI must have a valid signature from the selected publisher.' }
if (-not $Apply) { Write-Output "Plan: install signed $Product MSI interactively, no forced restart."; return }
Assert-Administrator
if ($PSCmdlet.ShouldProcess($Product, 'Install verified MSI; existing installation may be upgraded')) {
    $backup = New-VpnBackup 'Installer'
    $log = Join-Path $backup 'msi.log'
    $arguments = '/i "' + $file.FullName + '" /norestart /L*v "' + $log + '"'
    if ($Product -eq 'WireGuard') { $arguments += ' DO_NOT_LAUNCH=1' }
    $process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\msiexec.exe') -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) { throw "MSI failed ($($process.ExitCode)). See protected installer log." }
    [pscustomobject]@{ Product = $Product; ExitCode = $process.ExitCode; RestartRequired = ($process.ExitCode -eq 3010); Log = $log }
}
