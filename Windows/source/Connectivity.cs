using System.Net.NetworkInformation;
using System.Net;
using System.Net.Http.Headers;

namespace CampusConnect;

internal enum PortalProbeState { Clear, Captive, Unknown }
internal sealed record PortalProbe(PortalProbeState State, string? PortalUrl = null);
internal sealed record ConnectivityObservation(InternetStatus Status, PortalProbe Portal);

internal static class Connectivity
{
    private static readonly Uri ProbeAddress = new("http://www.msftconnecttest.com/connecttest.txt");
    private static readonly HttpClient ProbeClient = new(new HttpClientHandler {
        UseProxy = false, AllowAutoRedirect = false,
        AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli
    }) { Timeout = Timeout.InfiniteTimeSpan };
    private static readonly Uri EntryProbeAddress = new("http://www.baidu.com/");
    private static readonly HttpClient EntryProbeClient = new(new HttpClientHandler {
        UseProxy = false, AllowAutoRedirect = false, UseCookies = false,
        AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli
    }) { Timeout = Timeout.InfiniteTimeSpan };

    public static async Task<InternetStatus> CheckAsync(Guid? interfaceId)
        => (await InspectAsync(interfaceId)).Status;

    public static async Task<ConnectivityObservation> InspectAsync(Guid? interfaceId, bool checkPortal = true)
    {
        var unknown = new PortalProbe(PortalProbeState.Unknown);
        if (interfaceId is null) return new(InternetStatus.Unavailable, unknown);
        try {
            if (!NetworkInterface.GetAllNetworkInterfaces().Any(n =>
                Guid.TryParse(n.Id, out var id) && id == interfaceId && n.OperationalStatus == OperationalStatus.Up))
                return new(InternetStatus.Unavailable, unknown);
            // Both probes use the system route. A campus gateway may allow ICMP
            // before login, so an explicit captive HTTP result overrides ping.
            using var ping = new Ping();
            return await CheckWithPortalAsync(
                async () => (await ping.SendPingAsync("www.baidu.com", 3000)).Status,
                checkPortal ? ProbePortalAsync : () => Task.FromResult(unknown));
        } catch (NetworkInformationException) { return new(InternetStatus.Unavailable, unknown); }
    }

    internal static async Task<ConnectivityObservation> CheckWithPortalAsync(
        Func<Task<IPStatus>> ping, Func<Task<PortalProbe>> portal, TimeSpan? timeout = null)
    {
        var pingTask = CheckWithPingAsync(ping, timeout);
        async Task<PortalProbe> ReadPortal() {
            try { return await portal().WaitAsync(timeout ?? TimeSpan.FromSeconds(5)); }
            catch { return new(PortalProbeState.Unknown); }
        }
        var portalTask = ReadPortal();
        await Task.WhenAll(pingTask, portalTask);
        var result = await portalTask;
        return new(result.State == PortalProbeState.Captive ? InternetStatus.Unavailable : await pingTask, result);
    }

    internal static PortalProbe ClassifyPortalResponse(int status, Uri address, Uri? location, string body)
    {
        if (status is 301 or 302 or 303 or 307 or 308) {
            Uri? destination = location is null ? null : location.IsAbsoluteUri ? location : new Uri(address, location);
            var url = destination is not null && CampusProfile.Origin(destination.AbsoluteUri) is not null
                ? destination.AbsoluteUri : null;
            return new(PortalProbeState.Captive, url);
        }
        if (status == 511) return new(PortalProbeState.Captive);
        if (status != 200) return new(PortalProbeState.Unknown);
        return new(body.Trim() == "Microsoft Connect Test" ? PortalProbeState.Clear : PortalProbeState.Captive);
    }

    internal static async Task<PortalProbe> ProbePortalAsync()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(4));
        try {
            using var request = new HttpRequestMessage(HttpMethod.Get, ProbeAddress);
            request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
            using var response = await ProbeClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            string body = "";
            if (response.StatusCode == HttpStatusCode.OK) {
                await using var content = await response.Content.ReadAsStreamAsync(timeout.Token);
                var bytes = new byte[512]; var size = 0;
                while (size < bytes.Length) {
                    var count = await content.ReadAsync(bytes.AsMemory(size), timeout.Token);
                    if (count == 0) break;
                    size += count;
                }
                body = System.Text.Encoding.UTF8.GetString(bytes, 0, size);
            }
            return ClassifyPortalResponse((int)response.StatusCode, ProbeAddress, response.Headers.Location, body);
        } catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or IOException) {
            return new(PortalProbeState.Unknown);
        }
    }

    internal static bool IsUsablePortalEntry(string? address)
    {
        if (address is null || CampusProfile.Origin(address) is null) return false;
        var uri = new Uri(address, UriKind.Absolute);
        // Public probe services can redirect HTTP to their own HTTPS site.
        // That redirect is not evidence of a campus authentication entry.
        var host = uri.IdnHost.TrimEnd('.');
        if (new[] { "baidu.com", "msftconnecttest.com", "msftncsi.com" }.Any(domain =>
            host.Equals(domain, StringComparison.OrdinalIgnoreCase) ||
            host.EndsWith("." + domain, StringComparison.OrdinalIgnoreCase))) return false;
        if (!IsEportalAddress(uri)) return true;
        var path = uri.AbsolutePath.TrimEnd('/');
        return !path.EndsWith("/success.jsp", StringComparison.OrdinalIgnoreCase)
            && !path.Contains("redirectortosuccess", StringComparison.OrdinalIgnoreCase)
            && !(path.EndsWith("/index.jsp", StringComparison.OrdinalIgnoreCase) && uri.Query.Length <= 1);
    }

    private static bool IsEportalAddress(Uri address)
        => address.AbsolutePath.StartsWith("/eportal/", StringComparison.OrdinalIgnoreCase)
            || address.AbsolutePath.Equals("/eportal", StringComparison.OrdinalIgnoreCase);

    public static Task<string?> DiscoverPortalEntryAsync(string savedEntry, string? observedEntry)
        => DiscoverPortalEntryAsync(savedEntry, observedEntry,
            (request, token) => EntryProbeClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token));

    // Only discover the gateway's current entry; never send credentials or invent
    // userip/wlanuserip or wired/wireless parameters from a previous session.
    internal static async Task<string?> DiscoverPortalEntryAsync(string savedEntry, string? observedEntry,
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send, TimeSpan? timeout = null)
    {
        if (IsUsablePortalEntry(observedEntry)) return observedEntry;
        var probes = new List<Uri> { EntryProbeAddress };
        if (CampusProfile.Origin(savedEntry) is { } origin && IsEportalAddress(new Uri(savedEntry, UriKind.Absolute)))
            probes.Add(new Uri(origin + "/"));
        foreach (var address in probes) {
            using var deadline = new CancellationTokenSource(timeout ?? TimeSpan.FromSeconds(4));
            try {
                using var request = new HttpRequestMessage(HttpMethod.Get, address);
                request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
                using var response = await send(request, deadline.Token).WaitAsync(deadline.Token);
                if ((int)response.StatusCode is not (301 or 302 or 303 or 307 or 308) || response.Headers.Location is not { } location)
                    continue;
                var candidate = location.IsAbsoluteUri ? location.AbsoluteUri : new Uri(address, location).AbsoluteUri;
                if (IsUsablePortalEntry(candidate)) return candidate;
            } catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or IOException or UriFormatException) {
                // A probe can be unavailable independently of the campus gateway.
                // Continue to the configured ePortal origin; callers decide how to
                // handle absence instead of receiving the stale saved entry.
            }
        }
        return null;
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
