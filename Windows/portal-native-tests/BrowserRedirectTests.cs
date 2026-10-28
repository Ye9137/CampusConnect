using CampusConnect;
using Microsoft.Web.WebView2.Core;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Collections.Concurrent;

internal static class BrowserRedirectTests
{
    // Only the campus-adapter check is substituted. The production controller,
    // WebView2 callbacks, injected scripts and document lifecycle run unchanged.
    public static void Run(Action<bool, string> expect)
    {
        using var server = new FixtureServer();
        using var form = new Form { Width = 1000, Height = 700, ShowInTaskbar = false };
        var data = Path.Combine(Path.GetTempPath(), "CampusConnect-redirect-" + Guid.NewGuid().ToString("N"));
        var portal = new PortalController(() => CoreWebView2Environment.CreateAsync(null, data,
            new CoreWebView2EnvironmentOptions(PortalBrowserPolicy.Arguments)), _ => Task.FromResult(true));
        form.Controls.Add(portal.View);
        Exception? failure = null;
        form.Shown += async (_, _) => {
            try {
                var notices = new List<PortalProblem>();
                portal.Problem += notices.Add;
                var profile = new CampusProfile { Ssid = "Fixture-Campus", PortalUrl = server.Url("127.0.0.1", "/entry"),
                    Username = "fixture-user", AutoSubmit = true, Automatic = true };
                await portal.OpenAsync(profile, "fixture-secret");
                expect(!portal.View.CoreWebView2.Profile.IsInPrivateModeEnabled && portal.View.CoreWebView2.Profile.ProfileName.Equals(PortalBrowserPolicy.ProfileName, StringComparison.OrdinalIgnoreCase), "HTTP portal uses its own normal profile instead of InPrivate HTTPS-First mode");
                await Until(async () => {
                    if (notices.Count > 0) throw new Exception("Redirect raised a blocking notice: " + notices[0].Code);
                    if (server.Records.Count < 2 || !portal.Address.Contains("/second")) return false;
                    return JsonSerializer.Deserialize<int>(await portal.View.CoreWebView2.ExecuteScriptAsync("window.clicks || 0")) == 1;
                }, TimeSpan.FromSeconds(65));
                expect(server.Requests.Count(url => url.Contains("/bounce")) == 12, "native WebView2 follows more than ten redirects with host revisits");
                expect(server.Records.Count == 2 && server.Records.All(body => body == "[\"fixture-user\",\"fixture-secret\"]"), "both login documents receive the original account after slow redirect and popup");
                expect(notices.Count == 0, "31-second intermediate page and login popup never open the failure wizard");
                expect(profile.PortalUrl.EndsWith("/entry"), "native flow does not replace the saved entry");
                portal.ConfirmInternetAccess();
                expect(!portal.RequiresInteraction && !portal.IsAuthenticating, "actual connectivity confirmation finishes the redirected login attempt");

                // Reproduce a slow post-login landing failure after the network probe wins.
                var completed = new TaskCompletionSource<bool>();
                void LandingCompleted(object? _, CoreWebView2NavigationCompletedEventArgs e) { if (e.HttpStatusCode == 404) completed.TrySetResult(true); }
                portal.View.CoreWebView2.NavigationCompleted += LandingCompleted;
                portal.View.CoreWebView2.Navigate(server.Url("localhost", "/landing-error"));
                await Until(() => Task.FromResult(server.Requests.Any(url => url == "/landing-error")), TimeSpan.FromSeconds(10));
                portal.ConfirmInternetAccess();
                server.ReleaseLandingFailure.TrySetResult(true);
                await completed.Task.WaitAsync(TimeSpan.FromSeconds(10));
                portal.View.CoreWebView2.NavigationCompleted -= LandingCompleted;
                expect(notices.Count == 0 && portal.CurrentProblem is null && !portal.RequiresInteraction,
                    "a real late HTTP 404 cannot reopen the wizard after internet confirmation");

                // AutoSubmit=false must still fill the new destination after navigation.
                portal.Stop(clearView: false);
                await portal.OpenAsync(profile with { AutoSubmit = false, PortalUrl = server.Url("127.0.0.1", "/manual") }, "fixture-secret");
                await Until(async () => JsonSerializer.Deserialize<string>(await portal.View.CoreWebView2.ExecuteScriptAsync(
                    "document.querySelector('input[type=password]')?.value || ''")) == "fixture-secret", TimeSpan.FromSeconds(10));
                portal.View.CoreWebView2.Navigate(server.Url("localhost", "/manual-next"));
                await Until(async () => portal.Address.Contains("/manual-next") && JsonSerializer.Deserialize<string>(
                    await portal.View.CoreWebView2.ExecuteScriptAsync("document.querySelector('input[type=password]')?.value || ''")) == "fixture-secret", TimeSpan.FromSeconds(10));
                expect(server.Records.Count == 2 && portal.RequiresInteraction, "manual mode follows and fills another host without submitting");
                // The same HTTP error before confirmation must still be actionable.
                await portal.OpenAsync(profile with { PortalUrl = server.Url("localhost", "/landing-error") }, "fixture-secret");
                await Until(() => Task.FromResult(notices.Count > 0), TimeSpan.FromSeconds(10));
                expect(portal.CurrentProblem?.Code == "load-failed" && portal.CurrentProblem.Summary.Contains("HTTP 404"),
                    "a genuine pre-login HTTP 404 retains guidance and the concrete HTTP status");
                portal.Stop();
                expect(!portal.IsActive && !portal.IsAuthenticating, "Stop cancels all redirected work");
            } catch (Exception ex) { failure = ex; }
            finally { portal.Stop(clearView: false); form.Close(); }
        };
        Application.Run(form);
        portal.View.Dispose();
        if (failure is not null) throw new Exception("Native redirect browser test failed.", failure);
        Console.WriteLine("PASS: production WebView2 slow redirect, 12-hop cross-host chain, login popup, second login document and manual mode.");
    }

    private static async Task Until(Func<Task<bool>> ready, TimeSpan timeout)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (DateTimeOffset.UtcNow < deadline) {
            if (await ready()) return;
            await Task.Delay(100);
        }
        throw new TimeoutException("Native redirect fixture did not finish within " + timeout);
    }

    private sealed class FixtureServer : IDisposable
    {
        private readonly TcpListener listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource cancellation = new();
        public readonly ConcurrentQueue<string> Requests = new();
        public readonly ConcurrentQueue<string> Records = new();
        public readonly TaskCompletionSource<bool> ReleaseLandingFailure = new();
        public string Url(string host, string path) => $"http://{host}:{((IPEndPoint)listener.LocalEndpoint).Port}{path}";
        public FixtureServer() { listener.Start(); _ = Serve(); }
        public void Dispose() { cancellation.Cancel(); listener.Stop(); cancellation.Dispose(); }
        private async Task Serve()
        {
            try {
                while (!cancellation.IsCancellationRequested) {
                    var client = await listener.AcceptTcpClientAsync(cancellation.Token);
                    _ = Respond(client);
                }
            } catch (OperationCanceledException) { }
        }
        private async Task Respond(TcpClient client)
        {
            using (client) {
                try {
                    using var stream = client.GetStream();
                    using var reader = new StreamReader(stream, Encoding.UTF8, leaveOpen: true);
                    var first = await reader.ReadLineAsync();
                    if (first is null) return;
                    var target = first.Split(' ')[1];
                    var uri = new Uri(Url("127.0.0.1", target));
                    Requests.Enqueue(target);
                    var length = 0;
                    string? header;
                    while (!string.IsNullOrEmpty(header = await reader.ReadLineAsync())) {
                        if (header.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = int.Parse(header.Split(':')[1]);
                    }
                    if (length > 0) {
                        var body = new char[length];
                        await reader.ReadBlockAsync(body, 0, length);
                        if (uri.AbsolutePath == "/record") Records.Enqueue(new string(body));
                    }
                    var status = "200 OK"; var extra = ""; var html = "";
                    if (uri.AbsolutePath == "/landing-error") {
                        await ReleaseLandingFailure.Task.WaitAsync(cancellation.Token);
                        status = "404 Not Found"; html = "Landing page unavailable";
                    }
                    else if (uri.AbsolutePath == "/entry") { status = "302 Found"; extra = "Location: " + Url("localhost", "/bounce?step=0") + "\r\n"; }
                    else if (uri.AbsolutePath == "/bounce") {
                        var step = int.Parse(uri.Query.Split('=')[1]);
                        if (step < 11) { status = "302 Found"; extra = "Location: " + Url(step % 2 == 0 ? "127.0.0.1" : "localhost", "/bounce?step=" + (step + 1)) + "\r\n"; }
                        else html = "<p>Waiting for school login</p><script>setTimeout(()=>location.replace(" + JsonSerializer.Serialize(Url("localhost", "/login?ticket=fixture")) + "),31000)</script>";
                    }
                    else if (uri.AbsolutePath is "/login" or "/second" or "/manual" or "/manual-next") {
                        var next = uri.AbsolutePath == "/login" ? ".then(()=>window.open(" + JsonSerializer.Serialize(Url("127.0.0.1", "/second")) + ",'_blank'))" : "";
                        html = "<input name=username><input type=password><button id=login type=button>连接</button><script>window.clicks=0;login.onclick=()=>{clicks++;fetch('/record',{method:'POST',body:JSON.stringify([document.querySelector('[name=username]').value,document.querySelector('[type=password]').value])})" + next + "}</script>";
                    }
                    var bytes = Encoding.UTF8.GetBytes(html);
                    await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {bytes.Length}\r\n{extra}Connection: close\r\n\r\n"));
                    await stream.WriteAsync(bytes);
                } catch (IOException) { }
            }
        }
    }
}
