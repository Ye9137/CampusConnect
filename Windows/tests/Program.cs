using CampusConnect;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Xml.Linq;

var checks = 0;
void Expect(bool condition, string message) { checks++; if (!condition) throw new Exception("FAIL: " + message); }
void Invalid(CampusProfile profile) {
    try { profile.Validate(); } catch (InvalidOperationException) { checks++; return; }
    throw new Exception("Invalid profile accepted.");
}
PortalRedirectTests.Run(Expect);
Expect(!DesktopBridge.ControlsBusy(true, true), "background poll keeps every control usable");
Expect(!DesktopBridge.ControlsBusy(false, false), "idle controls remain usable");
Expect(DesktopBridge.ControlsBusy(true, false), "explicit scan and connect retain the operation lock");
if (args.Length == 2 && args[0] == "--redirect-fixture") {
    var landing = PortalRedirectTests.LandingProfile(Expect);
    var entry = landing with { PortalUrl = "http://1.1.1.1" };
    File.WriteAllText(args[1], JsonSerializer.Serialize(new {
        finalUrl = landing.PortalUrl,
        probe = PortalScript.LoginFormProbe(landing),
        entryProbe = PortalScript.LoginFormProbe(entry),
        fill = PortalScript.Build(landing, "fixture-password"),
        wrongOriginFill = PortalScript.Build(entry, "fixture-password")
    }));
    Console.WriteLine($"PASS: {checks} redirect checks; browser fixture generated.");
    return;
}
var profile = new CampusProfile(); profile.Validate();
Expect(profile.ServiceOption == "", "service selection defaults to blank");
var serviceProfile = JsonSerializer.Deserialize<CampusProfile>(JsonSerializer.Serialize(profile with { ServiceOption = "联通接入服务" }))!;
Expect(serviceProfile.ServiceOption == "联通接入服务", "service selection survives configuration round trip");
Expect(!profile.Automatic, "automation off for first launch");

// Previous API/browser selections are ignored on upgrade, preserving the web form settings.
foreach (var oldMethod in new[] { "direct", "browser" }) {
    var legacy = JsonSerializer.Deserialize<CampusProfile>(JsonSerializer.Serialize(new {
        Ssid = "HNPI-STU", Username = "kept-account", PortalUrl = "http://192.0.2.1/eportal/",
        LoginMethod = oldMethod, ServiceName = "legacy-service", AutoSubmit = false,
        Automatic = true, UserSelector = "#username", PasswordSelector = "#pwd"
    }))!;
    legacy.Validate();
    Expect(legacy.Username == "kept-account" && legacy.PortalUrl == "http://192.0.2.1/eportal/", "upgrade preserves account and portal");
    Expect(legacy.Automatic && !legacy.AutoSubmit, "upgrade preserves automation and submit preference");
    using var migrated = JsonDocument.Parse(JsonSerializer.Serialize(legacy));
    Expect(!migrated.RootElement.TryGetProperty("UserSelector", out _) && !migrated.RootElement.TryGetProperty("PasswordSelector", out _) && !migrated.RootElement.TryGetProperty("SubmitSelector", out _), "saving drops removed selector settings");
    Expect(!migrated.RootElement.TryGetProperty("LoginMethod", out _) && !migrated.RootElement.TryGetProperty("ServiceName", out _), "saving drops obsolete API settings");
    Expect(PortalScript.Build(legacy, "dummy-secret").Contains("dummy-secret"), "upgraded configuration builds browser authentication script");
}

var wired = profile with { Ssid = "" };
wired.Validate();
Expect(wired.IsWired, "blank SSID selects wired mode");
Expect((profile with { Ssid = "  " }).IsWired, "whitespace selects wired mode");
Expect(!profile.IsWired, "legacy configured SSID remains Wi-Fi mode");
Expect(wired.MatchesNetwork(null, true), "wired authentication works without a Wi-Fi adapter");
Expect(!wired.MatchesNetwork("HNPI-STU", false), "Wi-Fi cannot stand in for unplugged Ethernet");
Expect(!profile.MatchesNetwork("Other", true), "Ethernet cannot bypass configured Wi-Fi SSID");
Expect(profile.MatchesNetwork("HNPI-STU", false), "configured Wi-Fi works without Ethernet");
var reloadedWired = JsonSerializer.Deserialize<CampusProfile>(JsonSerializer.Serialize(wired))!;
Expect(reloadedWired.IsWired && reloadedWired.Ssid == "", "wired mode survives config reload");
Invalid(wired with { PortalUrl = "javascript:alert(1)" });
Invalid(wired with { PortalUrl = "http://user:secret@example.com" });
foreach (var type in new[] { System.Net.NetworkInformation.NetworkInterfaceType.Ethernet,
    System.Net.NetworkInformation.NetworkInterfaceType.GigabitEthernet }) {
    Expect(CampusNetwork.IsWiredInterface(type, System.Net.NetworkInformation.OperationalStatus.Up), "Ethernet link recognized");
    Expect(!CampusNetwork.IsWiredInterface(type, System.Net.NetworkInformation.OperationalStatus.Down), "unplugged Ethernet rejected");
}
foreach (var type in new[] { System.Net.NetworkInformation.NetworkInterfaceType.Wireless80211,
    System.Net.NetworkInformation.NetworkInterfaceType.Loopback, System.Net.NetworkInformation.NetworkInterfaceType.Tunnel })
    Expect(!CampusNetwork.IsWiredInterface(type, System.Net.NetworkInformation.OperationalStatus.Up), "non-Ethernet rejected");
// This call must work even on macOS, where Windows WLAN APIs cannot load.
_ = await CampusNetwork.IsAvailableAsync(wired);
// Each wired method bypasses WLAN and uses the chosen interface, even before an IP is assigned.
var fakeEthernet = Guid.NewGuid();
var wifiReads = 0; var wiredReads = 0;
Expect(await CampusNetwork.IsAvailableAsync(wired, () => { wiredReads++; return fakeEthernet; }, _ => { wifiReads++; throw new Exception("WLAN must not load"); }), "wired branch works without WLAN");
Expect(wifiReads == 0 && wiredReads == 1, "wired does not read Wi-Fi");
Expect(!await CampusNetwork.IsAvailableAsync(wired, () => null, _ => Task.FromResult<string?>("HNPI-STU")), "active Wi-Fi cannot replace missing Ethernet");
Expect(await CampusNetwork.IsAvailableAsync(profile, () => throw new Exception("wrong branch"), _ => Task.FromResult<string?>("HNPI-STU")), "Wi-Fi ignores wired interfaces");
var linkA = new NetworkLink(fakeEthernet, "Ethernet A", System.Net.NetworkInformation.NetworkInterfaceType.Ethernet, System.Net.NetworkInformation.OperationalStatus.Up);
var linkB = linkA with { Id = Guid.NewGuid(), Name = "Ethernet B" };
Expect(CampusNetwork.SelectEthernet("Ethernet B", [linkA, linkB])?.Id == linkB.Id, "exact selected Ethernet interface");
Expect(CampusNetwork.SelectEthernet("Missing", [linkA]) is null, "missing interface cannot fall back to another network");
Expect(CampusNetwork.SelectEthernet("", [linkA])?.Id == fakeEthernet, "link detected without a DHCP address");
Expect(CampusNetwork.SelectEthernet("", [linkA with { Status = System.Net.NetworkInformation.OperationalStatus.Down }]) is null, "unplugged link rejected");
var pppLink = linkA with { Type = System.Net.NetworkInformation.NetworkInterfaceType.Ppp, Name = "School broadband" };
Expect(CampusNetwork.SelectPpp("School broadband", [pppLink]) is not null, "matching dial-up interface recognized");
Expect(CampusNetwork.SelectPpp("Other", [pppLink]) is null, "other VPN or dial-up interface cannot replace selected PPPoE");
var entries = WiredAuthentication.ParsePhonebook("[VPN]\nType=2\n[School broadband]\nType=5\n[拨号]\nType=1\n", "/test/rasphone.pbk");
Expect(entries.Count == 1 && entries[0].Name == "School broadband", "only broadband phonebook entries selectable");
var dialProfile = wired with { WiredAuth = "pppoe", BroadbandName = "School broadband", Username = "never-a-command-argument", PortalUrl = "unused" };
dialProfile.Validate();
Expect(dialProfile.UsesSystemAuthentication && !dialProfile.UsesWebPortal, "PPPoE does not require portal credentials");
var dialCommand = WiredAuthentication.BuildCommand(dialProfile, "Ethernet A", entries, "/system");
Expect(Path.GetFileName(dialCommand.Executable) == "rasdial.exe", "PPPoE invokes Windows dialer");
Expect(dialCommand.Arguments.SequenceEqual(new[] { "School broadband", "/PHONEBOOK:/test/rasphone.pbk" }), "dialer receives only existing profile and phonebook path");
Expect(!string.Join(" ", dialCommand.Arguments).Contains(dialProfile.Username), "no credential in command arguments");
var dot1x = wired with { WiredAuth = "dot1x", EthernetName = "Campus Ethernet & 2", PortalUrl = "unused" };
dot1x.Validate();
var dotCommand = WiredAuthentication.BuildCommand(dot1x, dot1x.EthernetName, [], "/system");
Expect(dotCommand.Arguments.SequenceEqual(new[] { "lan", "reconnect", "interface=Campus Ethernet & 2" }), "802.1X targets only selected interface as one argument");
try { WiredAuthentication.BuildCommand(dot1x, "", [], "/system"); throw new Exception("reconnect-all accepted"); } catch (InvalidOperationException) { checks++; }
try { WiredAuthentication.BuildCommand(dialProfile with { BroadbandName = "VPN" }, "", entries, "/system"); throw new Exception("VPN accepted as PPPoE"); } catch (InvalidOperationException) { checks++; }
foreach (var method in new[] { "web", "pppoe", "dot1x", "client" }) {
    var configured = wired with { WiredAuth = method, BroadbandName = "School broadband", AuthenticationClient = @"C:\School\client.exe" };
    configured.Validate();
    var reload = JsonSerializer.Deserialize<CampusProfile>(JsonSerializer.Serialize(configured))!;
    Expect(reload.WiredAuth == method && reload.IsWired, "wired method persists");
}
Invalid(wired with { WiredAuth = "unknown" });
Invalid(wired with { WiredAuth = "pppoe" });
Invalid(wired with { WiredAuth = "client", AuthenticationClient = "https://example.com" });
Invalid(profile with { Ssid = new string('网', 11) });
Invalid(profile with { PortalUrl = "javascript:alert(1)" });
Invalid(profile with { PortalUrl = "https://user:secret@example.com" });
Expect(CampusProfile.Origin("http://EXAMPLE.com:80/a") == "http://example.com", "default port normalization");
Expect(CampusProfile.Origin("https://example.com:8443/a") == "https://example.com:8443", "port retained");
Expect(CampusProfile.Origin("http://[::1]/") == "http://[::1]", "IPv6 origin");
var policy = new AutoPolicy(); var now = DateTimeOffset.UtcNow;
Expect(!policy.ShouldJoin(true, "", null, [""], false, now), "wired mode never joins a Wi-Fi network");
Expect(policy.ShouldPrepareWired(true, true, false, now), "system authentication starts immediately");
Expect(!policy.ShouldPrepareWired(false, true, false, now), "pause prevents system authentication");
Expect(!policy.ShouldPrepareWired(true, true, true, now), "no overlapping system authentication");
Expect(!policy.ShouldPrepareWired(true, false, false, now), "online connection is not repeatedly authenticated");
Expect(policy.ShouldJoin(true, "HNPI-STU", "Home", ["HNPI-STU"], false, now), "visible target");
Expect(!policy.ShouldJoin(true, "HNPI-STU", null, ["HNPI-STU-fake"], false, now), "exact SSID");
Expect(!policy.ShouldJoin(false, "HNPI-STU", null, ["HNPI-STU"], false, now), "pause");
Expect(!policy.ShouldJoin(true, "HNPI-STU", "HNPI-STU", ["HNPI-STU"], false, now), "already connected");
Expect(!policy.ShouldJoin(true, "HNPI-STU", null, ["HNPI-STU"], true, now), "busy guard");
policy.Begin(now);
Expect(!policy.ShouldJoin(true, "HNPI-STU", null, ["HNPI-STU"], false, now.AddMilliseconds(999)), "no Wi-Fi retry before one second");
Expect(policy.ShouldJoin(true, "HNPI-STU", null, ["HNPI-STU"], false, now.AddSeconds(1)), "Wi-Fi retry at one second");
Expect(!policy.ShouldJoin(true, "HNPI-STU", null, ["HNPI-STU"], true, now.AddSeconds(1)), "one-second polling does not overlap a join");
Expect(!policy.ShouldJoin(true, "HNPI-STU", null, [], false, now.AddSeconds(1)), "startup waits for target to appear");
Expect(!policy.ShouldPrepareWired(true, true, false, now.AddSeconds(59)), "system authentication keeps its cooldown");
Expect(policy.ShouldPrepareWired(true, true, false, now.AddSeconds(60)), "system authentication retries at sixty seconds");
for (var i = 1; i <= 1000; i++) {
    var retryAt = now.AddSeconds(i);
    Expect(policy.ShouldJoin(true, "HNPI-STU", null, ["HNPI-STU"], false, retryAt), "Wi-Fi retries without a failure limit");
    policy.Begin(retryAt);
}
policy.Reset(); Expect(policy.ShouldJoin(true, "HNPI-STU", null, ["HNPI-STU"], false, now), "reset allows immediate connection");
var special = "校<&\"园";
var xml = XDocument.Parse(WifiService.OpenProfileXml(special));
XNamespace ns = "http://www.microsoft.com/networking/WLAN/profile/v1";
Expect(xml.Descendants(ns + "SSID").Single().Element(ns + "name")!.Value == special, "SSID XML escaping");
Expect(xml.Root!.Element(ns + "connectionMode")!.Value == "manual", "OS cannot autoconnect behind pause toggle");
Expect(Marshal.SizeOf<WifiService.Ssid>() == 36, "native SSID ABI");
Expect(Marshal.SizeOf<WifiService.InterfaceInfo>() == 532, "native interface ABI");
Expect(Marshal.SizeOf<WifiService.AvailableNetwork>() == 628, "native network ABI");
Expect(Marshal.SizeOf<WifiService.Association>() == 68, "native association ABI");
Expect(Marshal.SizeOf<WifiService.ConnectionAttributes>() == 604, "native connection ABI");
var secret = "test'\\\"\n</script>";
var script = PortalScript.Build(profile with { Username = secret, ServiceOption = secret }, secret);
var payload = script.Split("const cfg = ")[1].Split(';')[0];
using var json = JsonDocument.Parse(payload);
Expect(json.RootElement.GetProperty("password").GetString() == secret, "credential JSON escaping");
Expect(json.RootElement.GetProperty("serviceOption").GetString() == secret, "service option JSON escaping");
Expect(!script.Contains("/*CAMPUS_CONFIG*/"), "embedded resource substituted");
Expect(!script.Contains("/*CAMPUS_AGREEMENTS*/") && script.Contains("__campusAgreementAttempts"), "Windows agreement resource injected into generated script");
Expect(!script.Contains("/*CAMPUS_CAPTCHA*/") && script.Contains("captcha-required"), "Windows captcha resource injected into generated script");
var probe = PortalScript.BuildCaptchaProbe(profile with { PortalUrl = "http://portal.test", Username = "not-in-probe" });
Expect(!probe.Contains("/*CAPTCHA*/") && probe.Contains("captcha-required"), "standalone captcha probe embeds helper");
Expect(!probe.Contains("not-in-probe") && !probe.Contains(secret), "standalone captcha probe contains no saved credentials");
var imageScript = PortalScript.BuildCaptchaImage(profile with { PortalUrl = "http://portal.test" }, "fixture-image");
Expect(!imageScript.Contains("/*RESPONSE*/") && !imageScript.Contains(secret), "response image bridge excludes saved credentials");
await CaptchaResponseTests.RunAsync(Expect);
foreach (var code in new[] { "aB7Z", "1234", "abcd", "ABCD" }) {
    Expect(CaptchaInput.IsValid(code, 4, false), "manual alphanumeric CAPTCHA preserves case");
    Expect(code.All(c => CaptchaInput.Allows(c, false)), "typed alphanumeric CAPTCHA allowed");
}
foreach (var code in new[] { "", "abc", "abcde", "ab 7", "中文12", "ＡB12", "ab-7", "ab\n7" })
    Expect(!CaptchaInput.IsValid(code, 4, false), "invalid pasted CAPTCHA rejected");
Expect(CaptchaInput.IsValid("aB7Z", 0, false), "unspecified length accepts letters");
Expect(!CaptchaInput.IsValid(new string('a', 13), 0, false), "CAPTCHA length bounded");
Expect(CaptchaInput.IsValid("1234", 4, true) && !CaptchaInput.IsValid("aB7Z", 4, true), "explicit numeric page constraint retained");
if (args.Length >= 1) { Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(args[0]))!); File.WriteAllText(args[0], script); }
if (args.Length >= 2) { Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(args[1]))!); File.WriteAllText(args[1], probe); }
if (args.Length >= 3) { Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(args[2]))!); File.WriteAllText(args[2], imageScript); }
if (args.Length >= 4) {
    foreach (var file in Directory.EnumerateFiles(args[3], "*.json")) {
        using var response = File.OpenRead(file);
        Expect(await PortalCaptchaResponse.ReadAsync(response) is not null, "local image-only response replay accepted");
    }
}

Expect(DesktopBridge.IsTrustedSource("https://campusconnect-ui.invalid/"), "trust exact embedded UI");
Expect(!DesktopBridge.IsTrustedSource("http://campusconnect-ui.invalid/"), "reject insecure UI origin");
Expect(!DesktopBridge.IsTrustedSource("https://campusconnect-ui.invalid.evil/"), "reject lookalike host");
Expect(!DesktopBridge.IsTrustedSource("https://campusconnect-ui.invalid/?redirect=school"), "reject extra UI URL");
Expect(!DesktopBridge.IsTrustedSource("http://192.168.0.123/"), "school page cannot issue native UI commands");
Expect(!DesktopBridge.IsTrustedSource(null), "missing message origin rejected");
using var rect = JsonDocument.Parse("""{"x":244,"y":220,"width":792,"height":476,"viewportWidth":1060,"viewportHeight":760}""");
var scaled = DesktopBridge.ScaleBounds(rect.RootElement, 1325, 950);
Expect(scaled == (305, 275, 990, 595), "portal bounds scale to Windows 125 percent DPI");
using var invalidRect = JsonDocument.Parse("""{"x":-10,"y":0,"width":100,"height":100,"viewportWidth":1060,"viewportHeight":760}""");
Expect(DesktopBridge.ScaleBounds(invalidRect.RootElement, 1060, 760) is null, "reject offscreen browser bounds");
using var missingRect = JsonDocument.Parse("{}");
Expect(DesktopBridge.ScaleBounds(missingRect.RootElement, 1060, 760) is null, "reject missing browser bounds");

if (OperatingSystem.IsWindows()) {
    // Use an isolated HKCU key: tests must never enable the real logon application.
    var testKey = @"Software\CampusConnect.StartupTests\" + Guid.NewGuid().ToString("N");
    try {
        var startup = new StartupRegistration(@"C:\含空格 Test\CampusConnect.exe", testKey);
        Expect(!startup.IsEnabled(), "startup defaults off");
        startup.SetEnabled(true);
        using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(testKey))
            Expect((string?)key!.GetValue(StartupRegistration.ValueName) == "\"C:\\含空格 Test\\CampusConnect.exe\" --startup", "quoted startup path and tray flag");
        Expect(startup.IsEnabled(), "startup enabled");
        startup.SetEnabled(true);
        startup.SetEnabled(false);
        startup.SetEnabled(false);
        Expect(!startup.IsEnabled(), "startup removed idempotently");
        using (var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(testKey)) key.SetValue("OtherApp", "unchanged");
        startup.SetEnabled(true); startup.SetEnabled(false);
        using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(testKey))
            Expect((string?)key!.GetValue("OtherApp") == "unchanged", "preserve unrelated startup entries");
        try { new StartupRegistration(new string('x', 261), testKey).SetEnabled(true); throw new Exception("Long path accepted"); }
        catch (InvalidOperationException) { checks++; }
    } finally { if (OperatingSystem.IsWindows()) Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(testKey, false); }
} else Console.WriteLine("SKIP: Windows startup registry integration (requires Windows).");

// Regression: unchanged SSID must not latch a formerly successful authentication forever.
var recovery = new PortalRecovery();
Expect(recovery.ShouldAuthenticate(true, true, now), "first authentication starts before probes or timer ticks");
Expect(!recovery.ShouldAuthenticate(false, true, now), "startup respects pause");
Expect(!recovery.ShouldAuthenticate(true, false, now), "startup respects disabled portal");
recovery.Observe(InternetStatus.Online);
Expect(!recovery.ShouldAuthenticate(true, true, now), "online does not reauthenticate");
recovery.Observe(InternetStatus.Unavailable);
Expect(recovery.ShouldAuthenticate(true, true, now), "expired authentication on same SSID recovers");
recovery.Begin(now);
Expect(!recovery.ShouldAuthenticate(true, true, now.AddSeconds(20)), "no repeated submission every heartbeat");
Expect(recovery.ShouldAuthenticate(true, true, now.AddSeconds(60)), "retry after cooldown");
recovery.Begin(now.AddSeconds(60));
Expect(!recovery.ShouldAuthenticate(true, true, now.AddSeconds(120)), "second attempt uses longer backoff");
Expect(recovery.ShouldAuthenticate(true, true, now.AddSeconds(180)), "second backoff expires");
Expect(!recovery.ShouldAuthenticate(false, true, now.AddHours(1)), "pause prevents authentication");
Expect(!recovery.ShouldAuthenticate(true, false, now.AddHours(1)), "disabled portal prevents authentication");
recovery.Observe(InternetStatus.Online);
Expect(recovery.Attempts == 0 && !recovery.ShouldAuthenticate(true, true, now.AddHours(1)), "internet recovery resets attempts");
recovery.Observe(InternetStatus.Unavailable);
Expect(recovery.ShouldAuthenticate(true, true, now), "first failed ping triggers recovery");
recovery.Observe(InternetStatus.Unavailable);
Expect(recovery.ShouldAuthenticate(true, true, now), "repeated failures trigger recovery");
var authenticationTime = now;
for (var i = 0; i < 1000; i++) {
    Expect(recovery.ShouldAuthenticate(true, true, authenticationTime), "authentication retries indefinitely");
    recovery.Begin(authenticationTime);
    recovery.Observe(InternetStatus.Unavailable);
    authenticationTime += recovery.RetryDelay;
}
recovery.Reset();
Expect(recovery.ShouldAuthenticate(true, true, now), "new connection resets first authentication delay");
Expect(await Connectivity.CheckAsync(null) == InternetStatus.Unavailable, "missing campus adapter is offline");
Expect(await Connectivity.CheckWithPingAsync(() => Task.FromResult(System.Net.NetworkInformation.IPStatus.Success)) == InternetStatus.Online, "ICMP reply is online");
foreach (var status in new[] { System.Net.NetworkInformation.IPStatus.TimedOut, System.Net.NetworkInformation.IPStatus.DestinationHostUnreachable, System.Net.NetworkInformation.IPStatus.TtlExpired })
    Expect(await Connectivity.CheckWithPingAsync(() => Task.FromResult(status)) == InternetStatus.Unavailable, "non-success ICMP reply is offline");
Expect(await Connectivity.CheckWithPingAsync(() => throw new System.Net.NetworkInformation.PingException("fixture")) == InternetStatus.Unavailable, "ping error is offline");
Expect(await Connectivity.CheckWithPingAsync(() => throw new System.Net.Sockets.SocketException()) == InternetStatus.Unavailable, "DNS error is offline");
Expect(await Connectivity.CheckWithPingAsync(() => new TaskCompletionSource<System.Net.NetworkInformation.IPStatus>().Task, TimeSpan.FromMilliseconds(20)) == InternetStatus.Unavailable, "hung DNS/ping has a deadline");
Console.WriteLine($"PASS: {checks} checks (validation, ping, retry policy, native ABI, XML, credentials).");
