Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run Windows PowerShell as Administrator.' }
}

function Get-VpnProtectedAcl {
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    return $acl
}

function Assert-VpnAclTrusted {
    param([Security.AccessControl.FileSystemSecurity]$Acl, [switch]$Strict)
    $trusted = @('S-1-5-18', 'S-1-5-32-544')
    $installer = (New-Object Security.Principal.NTAccount('NT SERVICE\TrustedInstaller')).Translate([Security.Principal.SecurityIdentifier]).Value
    if (-not $Strict) { $trusted += $installer }
    $owner = $Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin $trusted) { throw 'Untrusted directory owner. Refuse existing path instead of taking ownership.' }
    $dangerous = [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership -bor [Security.AccessControl.FileSystemRights]::WriteAttributes -bor [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes
    if ($Strict) { $dangerous = $dangerous -bor [Security.AccessControl.FileSystemRights]::WriteData -bor [Security.AccessControl.FileSystemRights]::AppendData }
    foreach ($rule in $Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or $rule.IdentityReference.Value -in $trusted) { continue }
        if (-not $Strict -and ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
        if (($rule.FileSystemRights -band $dangerous) -ne 0) { throw 'Untrusted directory write/delete-child/ACL rights. Refuse unsafe ancestor or target.' }
    }
}

function Get-VpnDirectoryChain {
    param([string]$Path)
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(2).Contains(':')) { throw 'Only absolute local filesystem paths without alternate streams are accepted.' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':')) { throw 'Only absolute local filesystem paths without alternate streams are accepted.' }
    $chain = New-Object Collections.Generic.List[string]
    $item = New-Object IO.DirectoryInfo($full)
    while ($null -ne $item) { $chain.Insert(0, $item.FullName); $item = $item.Parent }
    return $chain.ToArray()
}

function Assert-VpnNoReparsePoint {
    param([string]$Path)
    foreach ($part in @(Get-VpnDirectoryChain $Path)) {
        if (Test-Path -LiteralPath $part) {
            $item = Get-Item -LiteralPath $part -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse point or non-directory ancestor refused.' }
        }
    }
}

function Assert-VpnPathTrusted {
    param([string]$Path, [switch]$StrictLeaf)
    Assert-VpnNoReparsePoint $Path
    $chain = @(Get-VpnDirectoryChain $Path)
    for ($i = $chain.Count - 1; $i -ge 0; $i--) {
        if (Test-Path -LiteralPath $chain[$i]) {
            Assert-VpnAclTrusted -Acl (Get-Acl -LiteralPath $chain[$i]) -Strict:($StrictLeaf -and $i -eq $chain.Count - 1)
        }
    }
}

function Initialize-VpnTrustedDirectory {
    param([string]$Path)
    $chain = @(Get-VpnDirectoryChain $Path)
    if ($chain.Count -lt 2) { throw 'Never change drive-root ACL.' }
    Assert-VpnPathTrusted -Path $Path -StrictLeaf
    foreach ($part in $chain) {
        if (Test-Path -LiteralPath $part) { continue }
        $acl = Get-VpnProtectedAcl
        $method = [IO.Directory].GetMethod('CreateDirectory', [type[]]@([string], [Security.AccessControl.DirectorySecurity]))
        if ($method) { $null = $method.Invoke($null, @($part, $acl)) }
        else { $null = [IO.FileSystemAclExtensions]::CreateDirectory($acl, $part) }
        Assert-VpnNoReparsePoint $part
        Assert-VpnAclTrusted -Acl (Get-Acl -LiteralPath $part) -Strict
    }
    Assert-VpnPathTrusted -Path $Path -StrictLeaf
    Set-Acl -LiteralPath $Path -AclObject (Get-VpnProtectedAcl)
}

function Protect-VpnDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-Administrator
    $runtimeRoot = Join-Path $env:ProgramData 'WindowsVPN'
    Initialize-VpnTrustedDirectory $runtimeRoot
    Initialize-VpnTrustedDirectory $Path
}

function Assert-VpnFileTrusted {
    param([string]$Path)
    Assert-VpnPathTrusted -Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))) -StrictLeaf
    if (Test-Path -LiteralPath $Path) {
        $file = Get-Item -LiteralPath $Path -Force
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse point or directory in place of a file refused.' }
        Assert-VpnAclTrusted -Acl (Get-Acl -LiteralPath $Path) -Strict
    }
}

function Protect-VpnFile {
    param([string]$Path)
    Assert-VpnFileTrusted $Path
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($id in @('S-1-5-18', 'S-1-5-32-544')) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($id)), 'FullControl', 'Allow'))) }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Write-VpnUtf8 {
    param([string]$Path, [string]$Text)
    Assert-VpnFileTrusted $Path
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
    Protect-VpnFile $Path
}

function New-VpnBackup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Label)
    $root = Join-Path $env:ProgramData 'WindowsVPN\Backups'
    $path = Join-Path $root ($Label + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    if ($PSCmdlet.ShouldProcess($path, 'Create protected backup directory')) {
        Protect-VpnDirectory $root
        Protect-VpnDirectory $path
        return $path
    }
}

function Invoke-VpnNative {
    param([string]$File, [string[]]$Arguments)
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw ('Native command failed: ' + [IO.Path]::GetFileName($File) + ', code ' + $LASTEXITCODE) }
}

function Get-VpnIPv4Network {
    param([string]$Cidr)
    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2) { throw 'Expected IPv4 CIDR.' }
    $ip = [Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
    $bits = [int]$parts[1]
    if ($ip.Length -ne 4 -or $bits -lt 0 -or $bits -gt 32) { throw 'Invalid IPv4 CIDR.' }
    for ($i = 0; $i -lt 4; $i++) {
        $keep = [Math]::Max(0, [Math]::Min(8, $bits - 8 * $i))
        $mask = if ($keep -eq 0) { 0 } else { (255 -shl (8 - $keep)) -band 255 }
        $ip[$i] = $ip[$i] -band $mask
    }
    return (($ip -join '.') + '/' + $bits)
}
