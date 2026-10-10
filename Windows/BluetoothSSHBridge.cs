// An authenticated Bluetooth byte pipe to local OpenSSH, never an input endpoint.
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

sealed class BluetoothSSHAddress : EndPoint {
    public readonly ulong Address;
    public readonly uint Channel;
    public BluetoothSSHAddress(uint channel, ulong address = 0) { Channel = channel; Address = address; }
    public override AddressFamily AddressFamily { get { return (AddressFamily)32; } }
    public override SocketAddress Serialize() {
        var value = new SocketAddress(AddressFamily, 30);
        for (int i = 0; i < 8; i++) value[2 + i] = (byte)(Address >> (8 * i));
        for (int i = 0; i < 4; i++) value[26 + i] = (byte)(Channel >> (8 * i));
        return value;
    }
    public override EndPoint Create(SocketAddress value) {
        ulong address = 0; uint channel = 0;
        for (int i = 0; i < 8; i++) address |= (ulong)value[2 + i] << (8 * i);
        for (int i = 0; i < 4; i++) channel |= (uint)value[26 + i] << (8 * i);
        return new BluetoothSSHAddress(channel, address);
    }
}

static class BluetoothSSHBridge {
    static void Main() {
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "LocalInputRouter");
        Directory.CreateDirectory(directory);
        string status = Path.Combine(directory, "bluetooth-ssh-status.json");
        while (true) {
            try {
                string[] peer = File.ReadAllLines(Path.Combine(directory,"bluetooth-peer.txt"));
                ulong macAddress = Convert.ToUInt64(peer[0].Replace(":", "").Replace("-", ""),16);
                uint channel = UInt32.Parse(peer[1]);
                if (channel < 1 || channel > 30) throw new IOException("Invalid Bluetooth channel");
                using (var listener = new Socket((AddressFamily)32, SocketType.Stream, (ProtocolType)3)) {
                    listener.SetSocketOption((SocketOptionLevel)3, unchecked((SocketOptionName)0x80000001), 1);
                    listener.SetSocketOption((SocketOptionLevel)3, (SocketOptionName)2, 1);
                    listener.Bind(new BluetoothSSHAddress(channel)); listener.Listen(2);
                    File.WriteAllText(status, "{\"ready\":true,\"channel\":"+channel+"}");
                    while (true) {
                        var client = listener.Accept();
                        if (((BluetoothSSHAddress)client.RemoteEndPoint).Address != macAddress) { client.Close(); continue; }
                        Task.Run(() => Forward(client));
                    }
                }
            } catch (Exception e) {
                File.WriteAllText(status, "{\"ready\":false,\"error\":\"" + e.GetType().Name + "\",\"code\":" +
                    (e is SocketException ? ((SocketException)e).ErrorCode : 0) + "}");
                Thread.Sleep(5000); // The Bluetooth radio can become available after boot.
            }
        }
    }
    static void Forward(Socket bluetooth) {
        using (bluetooth)
        using (var ssh = new TcpClient()) {
            try {
                ssh.NoDelay = true; ssh.Connect(IPAddress.Loopback, 22);
                using (var input = new NetworkStream(bluetooth, false)) {
                    NetworkStream output = ssh.GetStream();
                    Task.WaitAny(input.CopyToAsync(output, 4096), output.CopyToAsync(input, 4096));
                }
            } catch (IOException) { } catch (SocketException) { }
        }
    }
}
