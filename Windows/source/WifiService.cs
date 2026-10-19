using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;

namespace CampusConnect;

internal sealed record WifiNetwork(Guid InterfaceId, string Ssid, string ProfileName, uint Signal, bool Secure, bool Connectable)
{
    public override string ToString() => $"{Ssid}    {Signal}%    {(Secure ? "加密 / 使用系统配置" : "开放网络")}";
}
internal sealed record WifiSnapshot(string? Current, IReadOnlyList<WifiNetwork> Networks);

// Native WLAN avoids parsing localized netsh output and keeps passwords out of command lines.
internal sealed class WifiService : IDisposable
{
    private IntPtr handle;
    public WifiService() => Check(WlanOpenHandle(2, IntPtr.Zero, out _, out handle));
    public void Dispose() { if (handle != IntPtr.Zero) { WlanCloseHandle(handle, IntPtr.Zero); handle = IntPtr.Zero; } }

    // Opening a WLAN handle and even querying the current connection can wait
    // on a driver/service. Keep the entire handle lifetime off the UI thread.
    public static Task<string?> ReadCurrentAsync(string? preferred = null) => Task.Run(() => {
        using var wifi = new WifiService();
        return wifi.CurrentSsid(preferred);
    });
    public static Task<Guid?> ReadInterfaceAsync(string ssid) => Task.Run(() => {
        using var wifi = new WifiService();
        var connection = wifi.CurrentConnection(ssid);
        return connection.Ssid == ssid ? connection.InterfaceId : null;
    });
    public static Task<WifiSnapshot> ReadSnapshotAsync(string? preferred = null, bool scan = true, bool waitForScan = true) => Task.Run(async () => {
        using var wifi = new WifiService();
        return await wifi.ScanAsync(preferred, scan, waitForScan).ConfigureAwait(false);
    });
    public static Task JoinAsync(CampusProfile profile, WifiSnapshot snapshot) => Task.Run(async () => {
        using var wifi = new WifiService();
        await wifi.ConnectAsync(profile, snapshot).ConfigureAwait(false);
    });

    private List<InterfaceInfo> Interfaces()
    {
        Check(WlanEnumInterfaces(handle, IntPtr.Zero, out var pointer));
        try { return ReadList<InterfaceInfo>(pointer); }
        finally { WlanFreeMemory(pointer); }
    }
    private static List<T> ReadList<T>(IntPtr pointer) where T : struct
    {
        var count = Marshal.ReadInt32(pointer);
        if (count < 0 || count > 10000) throw new InvalidDataException("无线接口返回了无效数据。");
        var result = new List<T>();
        for (var i = 0; i < count; i++) result.Add(Marshal.PtrToStructure<T>(IntPtr.Add(pointer, 8 + i * Marshal.SizeOf<T>())));
        return result;
    }
    public string? CurrentSsid(string? preferred = null) => CurrentConnection(preferred).Ssid;
    private (string? Ssid, Guid? InterfaceId) CurrentConnection(string? preferred)
    {
        (string? Ssid, Guid? InterfaceId) first = (null, null);
        foreach (var item in Interfaces()) {
            var id = item.Id;
            var code = WlanQueryInterface(handle, ref id, 7, IntPtr.Zero, out _, out var data, out _);
            if (code == 5023) continue; // ERROR_INVALID_STATE: interface is disconnected.
            Check(code);
            try {
                var connection = Marshal.PtrToStructure<ConnectionAttributes>(data);
                if (connection.State != 1) continue;
                var ssid = connection.Association.Ssid.Text;
                if (ssid == preferred) return (ssid, id);
                if (first.Ssid is null) first = (ssid, id);
            } finally { WlanFreeMemory(data); }
        }
        return first;
    }
    public async Task<WifiSnapshot> ScanAsync(string? preferred = null, bool scan = true, bool waitForScan = true)
    {
        var interfaces = Interfaces();
        if (interfaces.Count == 0) throw new InvalidOperationException("没有找到 Wi-Fi 网卡，请检查无线网卡和 WLAN AutoConfig 服务。");
        if (scan && waitForScan) {
            RequestScan(interfaces);
            await Task.Delay(1800).ConfigureAwait(false);
        }
        var networks = new List<WifiNetwork>();
        foreach (var item in interfaces) {
            var id = item.Id;
            var code = WlanGetAvailableNetworkList(handle, ref id, 0, IntPtr.Zero, out var pointer);
            if (code == 5023 || code == 2150899714) continue; // Radio powered off.
            Check(code);
            try {
                foreach (var n in ReadList<AvailableNetwork>(pointer))
                    if (n.Ssid.Length > 0) networks.Add(new(id, n.Ssid.Text, n.ProfileName, n.Signal, n.SecurityEnabled != 0, n.Connectable != 0));
            } finally { WlanFreeMemory(pointer); }
        }
        // Older releases exposed an internal hex-based profile name in Windows.
        // Rename only our legacy open profile for the selected SSID. Keep the
        // connection and profile contents intact; a conflict/denial is cosmetic
        // and must not prevent scanning or authentication.
        if (!string.IsNullOrEmpty(preferred)) {
            var legacy = "CampusConnect-" + Convert.ToHexString(Encoding.UTF8.GetBytes(preferred));
            foreach (var idValue in networks.Where(n => n.Ssid == preferred && !n.Secure && n.ProfileName == legacy)
                         .Select(n => n.InterfaceId).Distinct().ToList()) {
                if (networks.Any(n => n.InterfaceId == idValue && n.ProfileName == preferred)) continue;
                var id = idValue;
                if (WlanRenameProfile(handle, ref id, legacy, preferred, IntPtr.Zero) != 0) continue;
                for (var i = 0; i < networks.Count; i++)
                    if (networks[i].InterfaceId == id && networks[i].ProfileName == legacy)
                        networks[i] = networks[i] with { ProfileName = preferred };
            }
        }
        var snapshot = new WifiSnapshot(CurrentSsid(preferred), networks.OrderByDescending(n => n.Signal).ToList());
        // WlanScan may flush its cache: read the previous result BEFORE requesting
        // a background scan. Subsequent one-second heartbeats read the new result.
        if (scan && !waitForScan) RequestScan(interfaces);
        return snapshot;
    }
    private void RequestScan(IEnumerable<InterfaceInfo> interfaces)
    {
        foreach (var item in interfaces) {
            var id = item.Id;
            var code = WlanScan(handle, ref id, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (code == 5) Check(code);
        }
    }
    public async Task ConnectAsync(CampusProfile profile, WifiSnapshot snapshot)
    {
        if (CurrentSsid(profile.Ssid) == profile.Ssid) return;
        var matches = snapshot.Networks.Where(n => n.Ssid == profile.Ssid).ToList();
        var network = (profile.UseSavedWifiProfile ? matches.FirstOrDefault(n => n.ProfileName.Length > 0) : matches.FirstOrDefault(n => !n.Secure))
            ?? throw new InvalidOperationException(profile.UseSavedWifiProfile
                ? "未发现已保存的校园 Wi-Fi。请先在 Windows Wi-Fi 设置中连接一次并保存密码 / 企业认证。"
                : "未发现该开放 Wi-Fi；如果网络已加密，请选择使用 Windows 已保存的配置。");
        var id = network.InterfaceId;
        string profileName;
        if (profile.UseSavedWifiProfile) profileName = network.ProfileName;
        else {
            profileName = profile.Ssid;
            // Reuse a matching open profile; never overwrite a user's saved
            // profile just because its display name matches the target SSID.
            if (!matches.Any(n => n.InterfaceId == id && !n.Secure && n.ProfileName == profileName))
                Check(WlanSetProfile(handle, ref id, 2, OpenProfileXml(profile.Ssid), null, false, IntPtr.Zero, out _));
        }
        var parameters = new ConnectionParameters { Mode = 0, Profile = profileName, BssType = 1 };
        Check(WlanConnect(handle, ref id, ref parameters, IntPtr.Zero));
        for (var i = 0; i < 25; i++) {
            await Task.Delay(1000).ConfigureAwait(false);
            if (CurrentSsid(profile.Ssid) == profile.Ssid) return;
        }
        throw new TimeoutException("连接超时，请检查 Wi-Fi 信号和系统中保存的网络配置。");
    }
    internal static string OpenProfileXml(string ssid)
    {
        var hex = Convert.ToHexString(Encoding.UTF8.GetBytes(ssid));
        return $"""
            <?xml version="1.0"?>
            <WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
              <name>{SecurityElement.Escape(ssid)}</name>
              <SSIDConfig><SSID><hex>{hex}</hex><name>{SecurityElement.Escape(ssid)}</name></SSID></SSIDConfig>
              <connectionType>ESS</connectionType><connectionMode>manual</connectionMode>
              <MSM><security><authEncryption><authentication>open</authentication><encryption>none</encryption><useOneX>false</useOneX></authEncryption></security></MSM>
            </WLANProfile>
            """;
    }
    private static void Check(uint code)
    {
        if (code == 5) throw new InvalidOperationException("Windows 拒绝访问 Wi-Fi 信息。请在 设置 → 隐私和安全性 → 位置 中开启定位服务并允许桌面应用访问，然后重试。");
        if (code != 0) throw new Win32Exception((int)code);
    }

    [StructLayout(LayoutKind.Sequential)] internal struct Ssid
    {
        public uint Length;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] Bytes;
        public readonly string Text => Encoding.UTF8.GetString(Bytes, 0, (int)Math.Min(Length, 32));
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct InterfaceInfo
    {
        public Guid Id;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Description;
        public uint State;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct AvailableNetwork
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string ProfileName;
        public Ssid Ssid;
        public uint BssType, BssidCount;
        public int Connectable;
        public uint Reason, PhyCount;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)] public uint[] Phys;
        public int MorePhys;
        public uint Signal;
        public int SecurityEnabled;
        public uint Auth, Cipher, Flags, Reserved;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct Association
    {
        public Ssid Ssid;
        public uint BssType;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public byte[] Bssid;
        public uint PhyType, PhyIndex, Signal, RxRate, TxRate;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct ConnectionAttributes
    {
        public uint State, Mode;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string ProfileName;
        public Association Association;
        public int SecurityEnabled, OneXEnabled;
        public uint Auth, Cipher;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct ConnectionParameters
    {
        public uint Mode;
        [MarshalAs(UnmanagedType.LPWStr)] public string Profile;
        public IntPtr Ssid, BssidList;
        public uint BssType, Flags;
    }
    [DllImport("wlanapi.dll")] private static extern uint WlanOpenHandle(uint version, IntPtr reserved, out uint negotiated, out IntPtr handle);
    [DllImport("wlanapi.dll")] private static extern uint WlanCloseHandle(IntPtr handle, IntPtr reserved);
    [DllImport("wlanapi.dll")] private static extern uint WlanEnumInterfaces(IntPtr handle, IntPtr reserved, out IntPtr list);
    [DllImport("wlanapi.dll")] private static extern void WlanFreeMemory(IntPtr memory);
    [DllImport("wlanapi.dll")] private static extern uint WlanQueryInterface(IntPtr handle, ref Guid id, uint opcode, IntPtr reserved, out uint size, out IntPtr data, out uint type);
    [DllImport("wlanapi.dll")] private static extern uint WlanScan(IntPtr handle, ref Guid id, IntPtr ssid, IntPtr ie, IntPtr reserved);
    [DllImport("wlanapi.dll")] private static extern uint WlanGetAvailableNetworkList(IntPtr handle, ref Guid id, uint flags, IntPtr reserved, out IntPtr list);
    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] private static extern uint WlanSetProfile(IntPtr handle, ref Guid id, uint flags, string xml, string? security, [MarshalAs(UnmanagedType.Bool)] bool overwrite, IntPtr reserved, out uint reason);
    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] private static extern uint WlanConnect(IntPtr handle, ref Guid id, ref ConnectionParameters parameters, IntPtr reserved);
    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] private static extern uint WlanRenameProfile(IntPtr handle, ref Guid id, string oldName, string newName, IntPtr reserved);
}
