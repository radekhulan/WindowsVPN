#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][Net.IPAddress]$SourceAddress,
    [Parameter(Mandatory = $true)][Net.IPAddress]$DestinationAddress,
    [ValidateRange(1, 65535)][int]$Port = 443,
    [ValidateRange(100, 30000)][int]$TimeoutMilliseconds = 3000
)
$ErrorActionPreference = 'Stop'
if ($SourceAddress.AddressFamily -ne $DestinationAddress.AddressFamily) { throw 'Source/destination address families differ.' }
$local = @(Get-NetIPAddress -IPAddress $SourceAddress.ToString() -ErrorAction SilentlyContinue)
if ($local.Count -eq 0) { throw 'Source address is not assigned to this machine.' }
$socket = New-Object Net.Sockets.Socket($SourceAddress.AddressFamily, [Net.Sockets.SocketType]::Stream, [Net.Sockets.ProtocolType]::Tcp)
$watch = [Diagnostics.Stopwatch]::StartNew()
$waitHandle = $null
try {
    $socket.Bind((New-Object Net.IPEndPoint($SourceAddress, 0)))
    $operation = $socket.BeginConnect($DestinationAddress, $Port, $null, $null)
    $waitHandle = $operation.AsyncWaitHandle
    if (-not $waitHandle.WaitOne($TimeoutMilliseconds)) { throw 'TCP connect timeout.' }
    $socket.EndConnect($operation)
    [pscustomobject]@{ Connected = $true; Source = $SourceAddress.ToString(); Destination = $DestinationAddress.ToString(); Port = $Port; Milliseconds = $watch.ElapsedMilliseconds }
} catch {
    [pscustomobject]@{ Connected = $false; Source = $SourceAddress.ToString(); Destination = $DestinationAddress.ToString(); Port = $Port; Milliseconds = $watch.ElapsedMilliseconds; Error = $_.Exception.Message }
} finally { $socket.Dispose(); if ($waitHandle) { $waitHandle.Dispose() } }
