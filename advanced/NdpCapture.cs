using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.ComponentModel;
using System.Net;
using System.Runtime.InteropServices;
using System.Threading;

public sealed class WindowsVpnNdpRequest
{
    public string Source;
    public string Target;
}

public static class WindowsVpnNdpCapture
{
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetDllDirectory(string directory);
    [DllImport("WinDivert.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    private static extern IntPtr WinDivertOpen(string filter, int layer, short priority, ulong flags);
    [DllImport("WinDivert.dll", SetLastError = true)]
    private static extern bool WinDivertRecv(IntPtr handle, byte[] packet, uint size, out uint length, byte[] address);
    [DllImport("WinDivert.dll", SetLastError = true)]
    private static extern bool WinDivertClose(IntPtr handle);
    private static IntPtr handle = IntPtr.Zero;
    private static Thread worker;
    private static volatile bool stopping;
    private static ConcurrentQueue<WindowsVpnNdpRequest> queue = new ConcurrentQueue<WindowsVpnNdpRequest>();
    public static long Received, Accepted, Rejected;
    public static string Error;

    public static bool ChecksumValid(byte[] packet, int length)
    {
        if (packet == null || length < 40 || length > packet.Length) return false;
        uint sum = 0;
        for (int i = 8; i < 40; i += 2) sum += (uint)((packet[i] << 8) | packet[i + 1]);
        sum += (uint)(length - 40) + 58;
        for (int i = 40; i < length; i += 2) sum += (uint)((packet[i] << 8) | (i + 1 < length ? packet[i + 1] : 0));
        while (sum > 65535) sum = (sum & 65535) + (sum >> 16);
        return sum == 65535;
    }

    public static WindowsVpnNdpRequest Validate(byte[] packet, int length, string[] targets, string[] trustedRouters)
    {
        if (packet == null || length < 64 || length > 296 || length > packet.Length ||
            (packet[0] >> 4) != 6 || packet[6] != 58 || packet[7] != 255 ||
            packet[40] != 135 || packet[41] != 0 || ((packet[4] << 8) | packet[5]) != length - 40) return null;
        byte[] sourceBytes = new byte[16], targetBytes = new byte[16], destinationBytes = new byte[16];
        Array.Copy(packet, 8, sourceBytes, 0, 16);
        Array.Copy(packet, 24, destinationBytes, 0, 16);
        Array.Copy(packet, 48, targetBytes, 0, 16);
        string source = new IPAddress(sourceBytes).ToString(), target = new IPAddress(targetBytes).ToString();
        if (!new HashSet<string>(trustedRouters, StringComparer.OrdinalIgnoreCase).Contains(source) ||
            !new HashSet<string>(targets, StringComparer.OrdinalIgnoreCase).Contains(target) ||
            !ChecksumValid(packet, length)) return null;
        byte[] solicited = new byte[16];
        solicited[0] = 0xff; solicited[1] = 2; solicited[11] = 1; solicited[12] = 0xff;
        Array.Copy(targetBytes, 13, solicited, 13, 3);
        bool unicast = true, multicast = true;
        for (int i = 0; i < 16; i++) { unicast &= destinationBytes[i] == targetBytes[i]; multicast &= destinationBytes[i] == solicited[i]; }
        if (!unicast && !multicast) return null;
        for (int i = 64; i < length; )
        {
            if (i + 1 >= length || packet[i + 1] == 0) return null;
            i += 8 * packet[i + 1];
            if (i > length) return null;
        }
        return new WindowsVpnNdpRequest { Source = source, Target = target };
    }

    public static void Start(string directory, int interfaceIndex, string[] targets, string[] trustedRouters, bool allowDriverInstallation)
    {
        if (worker != null) throw new InvalidOperationException("Use a fresh process per helper instance.");
        if (!SetDllDirectory(directory)) throw new Win32Exception(Marshal.GetLastWin32Error());
        ulong flags = allowDriverInstallation ? 5UL : 21UL;
        handle = WinDivertOpen("inbound and !loopback and ipv6 and icmpv6 and icmpv6.Type == 135 and ifIdx == " + interfaceIndex, 0, 0, flags);
        if (handle == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        worker = new Thread(() => {
            byte[] packet = new byte[2048], address = new byte[80]; uint count;
            try
            {
                while (WinDivertRecv(handle, packet, (uint)packet.Length, out count, address))
                {
                    Interlocked.Increment(ref Received);
                    WindowsVpnNdpRequest request = Validate(packet, (int)count, targets, trustedRouters);
                    if (request == null || queue.Count >= 64) { Interlocked.Increment(ref Rejected); continue; }
                    queue.Enqueue(request); Interlocked.Increment(ref Accepted);
                }
                if (!stopping) Error = "Capture stopped: " + Marshal.GetLastWin32Error();
            }
            catch (Exception ex) { if (!stopping) Error = ex.Message; }
        });
        worker.IsBackground = true; worker.Start();
    }

    public static WindowsVpnNdpRequest Next()
    {
        WindowsVpnNdpRequest request; return queue.TryDequeue(out request) ? request : null;
    }

    public static void Stop()
    {
        stopping = true;
        if (handle != IntPtr.Zero && handle != new IntPtr(-1)) WinDivertClose(handle);
        if (worker != null) worker.Join(3000);
    }
}
