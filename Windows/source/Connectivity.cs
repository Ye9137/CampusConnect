using System.Net.NetworkInformation;

namespace CampusConnect;

internal static class Connectivity
{
    public static async Task<InternetStatus> CheckAsync(Guid? interfaceId)
    {
        if (interfaceId is null) return InternetStatus.Unavailable;
        try {
            if (!NetworkInterface.GetAllNetworkInterfaces().Any(n =>
                Guid.TryParse(n.Id, out var id) && id == interfaceId && n.OperationalStatus == OperationalStatus.Up))
                return InternetStatus.Unavailable;
            // Like the system ping command, ICMP uses the current system route.
            using var ping = new Ping();
            return await CheckWithPingAsync(async () => (await ping.SendPingAsync("www.baidu.com", 3000)).Status);
        } catch (NetworkInformationException) { return InternetStatus.Unavailable; }
    }
    internal static async Task<InternetStatus> CheckWithPingAsync(Func<Task<IPStatus>> send, TimeSpan? timeout = null)
    {
        try {
            var status = await send().WaitAsync(timeout ?? TimeSpan.FromSeconds(4));
            return status == IPStatus.Success ? InternetStatus.Online : InternetStatus.Unavailable;
        } catch (Exception ex) when (ex is PingException or TimeoutException or OperationCanceledException or
                                    System.Net.Sockets.SocketException or InvalidOperationException) {
            return InternetStatus.Unavailable;
        }
    }
}

internal sealed record NetworkLink(Guid Id, string Name, NetworkInterfaceType Type, OperationalStatus Status);

// Ethernet link detection must work before DHCP / PPPoE / 802.1X has supplied an IP address.
internal static class CampusNetwork
{
    internal static bool IsWiredInterface(NetworkInterfaceType type, OperationalStatus status)
        => status == OperationalStatus.Up && type is NetworkInterfaceType.Ethernet
            or NetworkInterfaceType.GigabitEthernet or NetworkInterfaceType.FastEthernetFx
            or NetworkInterfaceType.FastEthernetT;
    public static IReadOnlyList<NetworkLink> ReadLinks()
    {
        try {
            return NetworkInterface.GetAllNetworkInterfaces().Where(n => Guid.TryParse(n.Id, out _))
                .Select(n => new NetworkLink(Guid.Parse(n.Id), n.Name, n.NetworkInterfaceType, n.OperationalStatus)).ToArray();
        } catch (NetworkInformationException) { return []; }
    }
    internal static NetworkLink? SelectEthernet(string preferred, IEnumerable<NetworkLink> links)
        => links.FirstOrDefault(n => IsWiredInterface(n.Type, n.Status)
            && (string.IsNullOrEmpty(preferred) || n.Name.Equals(preferred, StringComparison.OrdinalIgnoreCase)));
    internal static NetworkLink? SelectPpp(string name, IEnumerable<NetworkLink> links)
        => links.FirstOrDefault(n => n.Type == NetworkInterfaceType.Ppp && n.Status == OperationalStatus.Up
            && !string.IsNullOrWhiteSpace(name) && n.Name.Equals(name, StringComparison.OrdinalIgnoreCase));
    public static Guid? ReadWiredInterface() => SelectEthernet("", ReadLinks())?.Id;
    public static NetworkLink? ReadPhysicalLink(CampusProfile profile) => SelectEthernet(profile.WiredAuth == "pppoe" ? "" : profile.EthernetName, ReadLinks());
    public static Guid? ReadWiredInterface(CampusProfile profile)
    {
        var links = ReadLinks();
        var ethernet = SelectEthernet(profile.WiredAuth == "pppoe" ? "" : profile.EthernetName, links);
        return ethernet is null ? null : profile.WiredAuth == "pppoe" ? SelectPpp(profile.BroadbandName, links)?.Id : ethernet.Id;
    }
    public static Task<bool> IsAvailableAsync(CampusProfile profile)
        => IsAvailableAsync(profile, () => ReadWiredInterface(profile), WifiService.ReadCurrentAsync);
    internal static async Task<bool> IsAvailableAsync(CampusProfile profile,
        Func<Guid?> readWired, Func<string?, Task<string?>> readWifi)
        => profile.IsWired ? readWired() is not null
            : profile.MatchesNetwork(await readWifi(profile.Ssid), false);
    public static Task<Guid?> ReadInterfaceAsync(CampusProfile profile)
        => profile.IsWired ? Task.FromResult(ReadWiredInterface(profile)) : WifiService.ReadInterfaceAsync(profile.Ssid);
}
