using CampusConnect;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using System.Text.Json;

internal static class DrcomBrowserTests
{
    public static void Run(Action<bool, string> expect)
    {
        using var server = new FixtureServer();
        using var form = new Form { Width = 900, Height = 600, ShowInTaskbar = false };
        var data = Path.Combine(Path.GetTempPath(), "CampusConnect-drcom-" + Guid.NewGuid().ToString("N"));
        var portal = new PortalController(() => CoreWebView2Environment.CreateAsync(null, data,
            new CoreWebView2EnvironmentOptions(PortalBrowserPolicy.Arguments)), _ => Task.FromResult(true));
        Dictionary<WebView2, Form> Popups() => (Dictionary<WebView2, Form>)typeof(PortalController)
            .GetField("drcomPopups", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(portal)!;
        form.Controls.Add(portal.View);
        Exception? failure = null;
        form.Shown += async (_, _) => {
            try {
                var notices = new List<PortalProblem>();
                portal.Problem += notices.Add;
                var profile = new CampusProfile { Ssid = "Fixture-Campus", PortalUrl = server.Entry,
                    Username = "fixture-user", AutoSubmit = true, Automatic = true };
                await portal.OpenAsync(profile, "fixture-secret");
                await Until(() => Task.FromResult(server.Posts.Count == 1 && portal.Address.EndsWith("/landing") &&
                    Popups().Count == 1 && !portal.RequiresInteraction && !portal.IsAuthenticating));
                expect(server.Posts.Single().Contains("DDDDD=fixture-user") && server.Posts.Single().Contains("upass=fixture-secret"),
                    "Dr.COM onclick popup does not interrupt the main form POST");
                expect(server.Logouts == 0 && notices.Count == 0, "native Dr.COM confirmation never requests logout or opens a failure guide");
                var popup = Popups().Keys.Single();
                expect(popup.CoreWebView2.Source == "http://127.0.0.1:9002/In0" &&
                    popup.CoreWebView2.Profile.ProfileName == portal.View.CoreWebView2.Profile.ProfileName,
                    "Dr.COM status popup retains its cross-port document and shares the opener profile");
                for (var i = 0; i < 3; i++) await portal.OpenAsync(profile, "fixture-secret", automaticRetry: true);
                expect(server.Posts.Count == 1 && !popup.IsDisposed, "automatic retries reuse the authenticated status window without a second POST");
                portal.ConfirmInternetAccess(); portal.ReportInternetUnavailable();
                await portal.OpenAsync(profile, "fixture-secret", automaticRetry: true);
                expect(server.Posts.Count == 1, "a later ambiguous connectivity probe cannot tear down an established Dr.COM session");
                Popups()[popup].Close();
                expect(!popup.IsDisposed && !Popups()[popup].Visible && server.Logouts == 0,
                    "closing the status UI hides it without unloading or logging out");

                // The school's unload handler replaces its window with :9002/0.
                popup.CoreWebView2.Navigate("http://127.0.0.1:9002/replace");
                await Until(() => Task.FromResult(Popups().Keys.Any(p => !p.IsDisposed && p.CoreWebView2.Source == "http://127.0.0.1:9002/0")));
                await portal.OpenAsync(profile, "fixture-secret", automaticRetry: true);
                expect(server.Posts.Count == 1 && server.Logouts == 0, "onUnload replacement status window stays independent and prevents duplicate login");
                portal.Stop(clearView: false);
                expect(Popups().Count == 0 && !portal.IsActive, "Stop disposes all status windows and cancels popup callbacks");

                // The same status page can be the main document on older gateways.
                await portal.OpenAsync(profile with { PortalUrl = server.MainStatus }, "fixture-secret");
                await Until(() => Task.FromResult(!portal.IsAuthenticating && !portal.RequiresInteraction));
                expect(server.Posts.Count == 1, "already-online main document is confirmed before login-form preflight");
            } catch (Exception ex) { failure = ex; }
            finally { portal.Stop(clearView: false); form.Close(); }
        };
        Application.Run(form);
        portal.View.Dispose();
        if (failure is not null) throw new Exception("Native Dr.COM browser test failed.", failure);
        Console.WriteLine("PASS: production Dr.COM WebView2 popup, main POST, cross-port success, automatic retry deduplication, window hiding, onUnload replacement and Stop cleanup.");
    }

    private static async Task Until(Func<Task<bool>> ready)
    {
        var deadline = DateTimeOffset.UtcNow.AddSeconds(20);
        while (DateTimeOffset.UtcNow < deadline) {
            if (await ready()) return;
            await Task.Delay(100);
        }
        throw new TimeoutException("Native Dr.COM fixture did not finish.");
    }

    private sealed class FixtureServer : IDisposable
    {
        private readonly TcpListener main = new(IPAddress.Loopback, 0);
        private readonly TcpListener status = new(IPAddress.Loopback, 9002);
        private readonly CancellationTokenSource stop = new();
        private readonly TaskCompletionSource<bool> loggedIn = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly ConcurrentQueue<string> Posts = new();
        private int logouts;
        public int Logouts => logouts;
        private string Origin => $"http://127.0.0.1:{((IPEndPoint)main.LocalEndpoint).Port}";
        public string Entry => Origin + "/login";
        public string MainStatus => Origin + "/online";
        public FixtureServer() { main.Start(); status.Start(); _ = Serve(main); _ = Serve(status); }
        public void Dispose() { stop.Cancel(); main.Stop(); status.Stop(); stop.Dispose(); }
        private async Task Serve(TcpListener listener)
        {
            try {
                while (!stop.IsCancellationRequested) _ = Respond(await listener.AcceptTcpClientAsync(stop.Token));
            } catch (OperationCanceledException) { }
        }
        private async Task Respond(TcpClient client)
        {
            using (client) {
                try {
                    using var stream = client.GetStream();
                    using var reader = new StreamReader(stream, Encoding.UTF8, leaveOpen: true);
                    var line = await reader.ReadLineAsync();
                    if (line is null) return;
                    var parts = line.Split(' ');
                    var path = new Uri(Origin + parts[1]).AbsolutePath;
                    var length = 0;
                    string? header;
                    while (!string.IsNullOrEmpty(header = await reader.ReadLineAsync())) {
                        if (header.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = int.Parse(header.Split(':')[1]);
                    }
                    if (length > 0) {
                        var buffer = new char[length]; await reader.ReadBlockAsync(buffer, 0, length);
                        if (path == "/result") { Posts.Enqueue(new string(buffer)); loggedIn.TrySetResult(true); }
                    }
                    string html;
                    if (path == "/login") html = "<title>Drcom上网登录窗</title><form method=post action=/result onsubmit='return true'><input id=username name=DDDDD><input id=password type=password name=upass><input id=submit type=submit name=0MKKey value='登　录' onclick=\"window.open('http://127.0.0.1:9002/In0','p99','width=360,height=160')\"><input id=submit type=reset value='重　置'></form>";
                    else if (path == "/result") html = "<script>location.replace('/landing')</script>";
                    else if (path == "/F.htm") { Interlocked.Increment(ref logouts); html = "<title>信息返回</title><script>Msg=14</script>注销成功"; }
                    else if (path is "/In0" or "/0" or "/online") {
                        await loggedIn.Task.WaitAsync(stop.Token);
                        await Task.Delay(300, stop.Token);
                        html = "<title>Logout</title><script>url1='http://127.0.0.1:9002/0';url2=" + JsonSerializer.Serialize(Origin + "/F.htm") + ";s2=0;function ee(){if(s2!=1){window.open(url1,'','width=360,height=160');window.close()}}function wc(){if(confirm('注销')){s2=1;window.open(url2);window.close()}}</script><body onunload='ee()'><a href='javascript:wc()'>注 销</a>";
                    }
                    else html = "<title>Navigation</title>登录后的导航页面";
                    var bytes = Encoding.UTF8.GetBytes(html);
                    await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {bytes.Length}\r\nConnection: close\r\n\r\n"));
                    await stream.WriteAsync(bytes);
                } catch (Exception ex) when (ex is IOException or OperationCanceledException) { }
            }
        }
    }
}
