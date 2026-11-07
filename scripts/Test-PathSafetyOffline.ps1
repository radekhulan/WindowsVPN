#Requires -Version 5.1
[CmdletBinding()]
param([switch]$UseFilesystemFixtures)
. (Join-Path $PSScriptRoot 'Common.ps1')
$script:Checks = 0
function Assert-PathFailure {
    param([scriptblock]$Code, [string]$Pattern)
    $matched = $false
    try { & $Code | Out-Null } catch { $matched = $_.Exception.Message -match $Pattern }
    if (-not $matched) { throw ('Expected refusal pattern at check ' + $script:Checks + ': ' + $Pattern) }
    $script:Checks++
}
$safe = Get-VpnProtectedAcl
Assert-VpnAclTrusted -Acl $safe -Strict
$script:Checks++
$foreign = New-Object Security.AccessControl.DirectorySecurity
$foreign.SetSecurityDescriptorSddlForm('O:S-1-5-21-111-222-333-1000G:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)')
Assert-PathFailure { Assert-VpnAclTrusted -Acl $foreign -Strict } 'Untrusted directory owner'
$deleteChild = Get-VpnProtectedAcl
$deleteChild.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')), 'DeleteSubdirectoriesAndFiles', 'Allow')))
Assert-PathFailure { Assert-VpnAclTrusted -Acl $deleteChild } 'write/delete-child'
$writer = Get-VpnProtectedAcl
$writer.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-11')), 'WriteData', 'Allow')))
Assert-PathFailure { Assert-VpnAclTrusted -Acl $writer -Strict } 'write/delete-child'
Assert-VpnAclTrusted -Acl $writer
$script:Checks++
Assert-PathFailure { Get-VpnDirectoryChain '\\example.com\share\vpn' } 'Only absolute local'
Assert-PathFailure { Get-VpnDirectoryChain 'C:\ProgramData\WindowsVPN:stream' } 'Only absolute local'

if ($UseFilesystemFixtures) {
    $package = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\')
    Assert-VpnNoReparsePoint $package
    $sandbox = Join-Path $package ('.path-test-' + [guid]::NewGuid().ToString('N'))
    if (-not ([IO.Path]::GetFullPath($sandbox).StartsWith($package + '\', [StringComparison]::OrdinalIgnoreCase))) { throw 'Fixture path escaped package.' }
    $junction = Join-Path $sandbox 'junction'
    $target = Join-Path $sandbox 'target'
    try {
        $null = New-Item -ItemType Directory -Path $sandbox
        $fixtureAcl = New-Object Security.AccessControl.DirectorySecurity
        $fixtureAcl.SetAccessRuleProtection($true, $false)
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $fixtureAcl.SetOwner($currentSid)
        foreach ($id in @($currentSid, (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')), (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))) {
            $fixtureAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        }
        Set-Acl -LiteralPath $sandbox -AclObject $fixtureAcl
        Assert-PathFailure { Assert-VpnPathTrusted -Path (Join-Path $sandbox 'not-created') -StrictLeaf } 'Untrusted directory owner'
        if (Test-Path -LiteralPath (Join-Path $sandbox 'not-created')) { throw 'Read-only trust validation created a child.' }
        $script:Checks++
        $null = New-Item -ItemType Directory -Path $target
        $null = New-Item -ItemType Junction -Path $junction -Target $target
        Assert-PathFailure { Assert-VpnNoReparsePoint -Path (Join-Path $junction 'child') } 'Reparse point'
    } finally {
        if (Test-Path -LiteralPath $junction) { Remove-Item -LiteralPath $junction -Force }
        foreach ($directory in @($target, $sandbox)) {
            if (Test-Path -LiteralPath $directory) {
                $resolved = (Get-Item -LiteralPath $directory -Force).FullName
                if (-not $resolved.StartsWith($package + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
                if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected cleanup reparse point.' }
                Remove-Item -LiteralPath $directory -Force
            }
        }
    }
}
Write-Output "PASS: $script:Checks path/ACL checks. Filesystem fixtures requested: $UseFilesystemFixtures. No system configuration changed."
