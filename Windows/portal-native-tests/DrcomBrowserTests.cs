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
        bool Confirmed() => (bool)typeof(PortalController)
            .GetField("authenticationConfirmed", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(portal)!;
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
                    Popups().Count == 1 && Confirmed() && !portal.RequiresInteraction && !portal.IsAuthenticating));
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

                // Exercise the school's replacement handler directly. Modern
                // Chromium can suppress window.open during actual unload.
                try { await popup.CoreWebView2.ExecuteScriptAsync("ee()"); }
                catch (System.Runtime.InteropServices.COMException) { /* ee closes its own document. */ }
                await Until(() => Task.FromResult(Popups().Keys.Any(p => !p.IsDisposed && p.CoreWebView2.Source == "http://127.0.0.1:9002/0")));
                await portal.OpenAsync(profile, "fixture-secret", automaticRetry: true);
                expect(server.Posts.Count == 1 && server.Logouts == 0, "school replacement handler keeps its new status window independent and prevents duplicate login");
                portal.Stop(clearView: false);
                expect(Popups().Count == 0 && !portal.IsActive, "Stop disposes all status windows and cancels popup callbacks");

                // MainForm uses Stop when the target adapter actually disconnects.
                // A later automatic reconnect must not trust the old online page.
                await portal.OpenAsync(profile, "fixture-secret", automaticRetry: true);
                await Until(() => Task.FromResult(server.Posts.Count == 2 && Confirmed() && !portal.IsAuthenticating));
                expect(server.Posts.Count == 2, "automatic reconnect after a real link loss creates a fresh login instead of reusing stale status");
                portal.Stop(clearView: false);

                // The same status page can be the main document on older gateways.
                await portal.OpenAsync(profile with { PortalUrl = server.MainStatus }, "fixture-secret");
                await Until(() => Task.FromResult(portal.Address == server.MainStatus && Confirmed() && !portal.IsAuthenticating && !portal.RequiresInteraction));
                expect(server.Posts.Count == 2, "already-online main document is confirmed before login-form preflight");
                portal.Stop(clearView: false);
                var railway = profile with { PortalUrl = server.RailwayEntry, ServiceOption = "校内网" };
                await portal.OpenAsync(railway with { AutoSubmit = false }, "fixture-secret");
                await Until(async () => portal.Address == server.RailwayEntry && await portal.View.CoreWebView2.ExecuteScriptAsync(
                    "document.forms.f1?.DDDDD.value === 'fixture-user' && document.forms.f1.upass.value === 'fixture-secret' && document.forms.other.alt.value === ''") == "true");
                expect(server.RailwayPosts.Count == 0, "manual mode fills only the normal account form and leaves submission to the user");
                await portal.OpenAsync(railway, "fixture-secret");
                await Until(() => Task.FromResult(server.RailwayPosts.Count == 1 && portal.Address.EndsWith("/a79.htm") && Confirmed() && !portal.IsAuthenticating));
                var posted = server.RailwayPosts.Single();
                expect(posted.Contains("DDDDD=fixture-user") && posted.Contains("upass=fixture-secret") && posted.Contains("ISP_select=campus"),
                    "named login button invokes the original page handler with the selected service");
                expect(server.Logouts == 0 && notices.Count == 0, "usage page is recognized without activating logout");
                portal.ConfirmInternetAccess(); portal.ReportInternetUnavailable();
                await portal.OpenAsync(railway, "fixture-secret", automaticRetry: true);
                await Until(() => Task.FromResult(server.RailwayPosts.Count == 2 && Confirmed()));
                expect(server.Logouts == 0, "cached usage page does not suppress a fresh login following an outage");
                portal.Stop(clearView: false);
                var stale = railway with { PortalUrl = server.UsagePage };
                var statuses = new List<string>();
                portal.Status += statuses.Add;
                await portal.OpenAsync(stale, "fixture-secret", discover: true);
                await Until(() => Task.FromResult(portal.Address == server.RailwayEntry && statuses.Any(s => s.Contains("已找到学校登录表单"))));
                expect(server.RailwayPosts.Count == 2 && await portal.View.CoreWebView2.ExecuteScriptAsync(
                    "document.forms.f1.DDDDD.value === '' && document.forms.f1.upass.value === ''") == "true",
                    "discovery with a saved usage URL follows the gateway's JavaScript redirect and leaves the login form empty");
                await portal.OpenAsync(stale, "fixture-secret");
                portal.ConfirmInternetAccess(); // A probe succeeds while the school is redirecting.
                await Until(() => Task.FromResult(server.RailwayPosts.Count == 3 && Confirmed() && portal.Address == server.UsagePage));
                portal.ConfirmInternetAccess();
                var core = portal.View.CoreWebView2;
                await core.ExecuteScriptAsync("document.querySelector('[name=logout]').click(); document.querySelector('#cancel').click()");
                expect(!await portal.ObserveSchoolLogoutAsync(), "canceling the logout dialog leaves the authenticated session in place");
                await core.ExecuteScriptAsync("document.querySelector('[name=logout]').click(); document.querySelector('#confirm').click()");
                expect(await portal.ObserveSchoolLogoutAsync() && !Confirmed() && !portal.RequiresInteraction && !portal.IsAuthenticating,
                    "logout success in the same document clears the previous online result and allows an automatic retry");
                await portal.OpenAsync(stale, "fixture-secret", automaticRetry: true);
                await Until(() => Task.FromResult(server.RailwayPosts.Count == 4 && Confirmed()));
                expect(server.RailwayPosts.Last() == posted, "automatic retry returns to the school form with the selected service");

                server.RootLanding = "/notice";
                statuses.Clear();
                await portal.OpenAsync(stale, "fixture-secret", discover: true);
                await Until(() => Task.FromResult(statuses.Any(s => s.Contains("已找到学校登录表单"))));
                expect(portal.Address.EndsWith("/notice") && server.RailwayPosts.Count == 4 &&
                    await core.ExecuteScriptAsync("window.noticeClicks === 1 && document.forms.f1.DDDDD.value === ''") == "true",
                    "discovery waits for the delayed notice click handler and opens the same-document form exactly once");
                await portal.OpenAsync(stale, "fixture-secret", automaticRetry: true);
                await Until(() => Task.FromResult(server.RailwayPosts.Count == 5 && Confirmed()));
                expect(server.RailwayPosts.Last() == posted, "automatic authentication traverses the notice and submits the normal form with the selected service");
                server.RootLanding = "/unrelated";
                await portal.OpenAsync(stale, "fixture-secret");
                await Until(() => Task.FromResult(portal.Address.EndsWith("/unrelated") && statuses.LastOrDefault()?.Contains("等待跳转") == true));
                expect(await core.ExecuteScriptAsync("document.querySelector('input[type=password]').value === ''") == "true",
                    "a generic login form at the school gateway receives no saved credentials");
                // Keep this test offline even if the navigation guard regresses.
                core.AddWebResourceRequestedFilter("https://www.msn.cn/*", CoreWebView2WebResourceContext.All);
                core.WebResourceRequested += (_, e) => {
                    if (e.Request.Uri.StartsWith("https://www.msn.cn/"))
                        e.Response = core.Environment.CreateWebResourceResponse(null, 204, "No Content", "");
                };
                await core.ExecuteScriptAsync("location.href='https://www.msn.cn/zh-cn'");
                await Until(() => Task.FromResult(statuses.Any(s => s.Contains("跳到了公共网页"))));
                expect(portal.Address.EndsWith("/unrelated") && server.RailwayPosts.Count == 5, "MSN redirect is canceled before replacing the school page");

                var lf = profile with { PortalUrl = server.LfEntry };
                await portal.OpenAsync(lf with { AutoSubmit = false }, "fixture-secret");
                await Until(async () => portal.Address == server.LfEntry && await core.ExecuteScriptAsync(
                    "document.forms._wifi_login?.passwd.value === 'fixture-secret' && document.forms.other.alt.value === ''") == "true");
                expect(server.LfPosts.IsEmpty, "manual LFRadius login only fills the selected form");
                await portal.OpenAsync(lf, "fixture-secret", automaticRetry: true);
                await Until(() => Task.FromResult(portal.Address.EndsWith("/login/cmcc_login/") && server.LfPosts.Count == 1));
                var body = server.LfPosts.Single();
                expect(body.Contains("usrname=fixture-user") && body.Contains("passwd=fixture-secret") &&
                    body.Contains("treaty=on") && body.Contains("nasid=fixture-session"),
                    "LFRadius uses the school's own button and keeps the gateway fields intact");
                portal.Stop(clearView: false);
                server.LfAgreementChecked = false;
                await portal.OpenAsync(lf, "fixture-secret");
                await Until(() => Task.FromResult(portal.CurrentProblem?.Code == "agreement-required"));
                expect(server.LfPosts.Count == 1 && await core.ExecuteScriptAsync("!document.forms._wifi_login.treaty.checked") == "true",
                    "an unchecked school disclaimer holds automatic submission");
            } catch (Exception ex) { failure = ex; }
            finally { portal.Stop(clearView: false); form.Close(); }
        };
        Application.Run(form);
        portal.View.Dispose();
        if (failure is not null) throw new Exception("Native Dr.COM browser test failed.", failure);
        Console.WriteLine("PASS: production Dr.COM WebView2 popup, main POST, cross-port success, automatic retry deduplication, window hiding, school replacement handler and Stop cleanup.");
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
        private const string RailwayForm = """
            <meta charset=utf-8><form name=other><input name=phone><input type=password name=alt><button>登录</button></form>
            <form name=f1 method=post action=/a79.htm><input name=DDDDD><input type=password name=upass>
            <select name=ISP_select><option value=-1>请选择</option><option value=campus>校内网</option></select>
            <input type=button name=0MKKey value="登 录(Login)" onclick="this.form.requestSubmit()"></form>
            """;
        public string RootLanding = "/railway";
        public string UsagePage => Origin + "/a79.htm";
        public string RailwayEntry => Origin + "/railway";
        public readonly ConcurrentQueue<string> RailwayPosts = new();
        private const string LfLogin = "/lfradius/libs/portal/unify/portal.php/login/";
        public string LfEntry => Origin + LfLogin + "main/nasid/1/";
        public readonly ConcurrentQueue<string> LfPosts = new();
        public bool LfAgreementChecked = true;
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
                        if (path == LfLogin + "cmcc_login/") LfPosts.Enqueue(new string(buffer));
                        if (path == "/a79.htm") RailwayPosts.Enqueue(new string(buffer));
                        if (path == "/result") { Posts.Enqueue(new string(buffer)); loggedIn.TrySetResult(true); }
                    }
                    string html;
                    if (path == "/login") html = "<title>Drcom上网登录窗</title><form method=post action=/result onsubmit='return true'><input id=username name=DDDDD><input id=password type=password name=upass><input id=submit type=submit name=0MKKey value='登　录' onclick=\"window.open('http://127.0.0.1:9002/In0','p99','width=360,height=160')\"><input id=submit type=reset value='重　置'></form>";
                    else if (path == "/") html = "<script>location.replace(" + JsonSerializer.Serialize(RootLanding) + ")</script>";
                    else if (path == "/unrelated") html = "<form><input name=username><input type=password><button>登录</button></form>";
                    else if (path == LfLogin + "main/nasid/1/") html = $$"""
                        <form name=other><input name=phone><input type=password name=alt></form>
                        <form id=_wifi_login name=_wifi_login method=post action="{{LfLogin}}cmcc_login/">
                        <input type=text name=usrname><input type=password name=passwd>
                        <label><input type=checkbox name=treaty {{(LfAgreementChecked ? "checked" : "")}}>同意免责协议</label>
                        <button id=_wifi_btn_login type=button onclick="document.forms['_wifi_login'].submit()">用户登录</button>
                        <input type=hidden name=nasid value=fixture-session></form>
                        """;
                    else if (path == "/railway") html = RailwayForm;
                    else if (path == "/notice") html = """
                        <script type="text/plain" src="/eportal/extern/nanjingtiedao/ip/4/pc_79.js"></script>
                        <div id="edit_body" class="divbg"><div id="advertTime">10</div>校园网络使用须知：点击任意位置
                        <form name=f79><input type=hidden name=DDDDD></form>
                        <form name=f78><input type=hidden name=upass></form></div>
                        <script>
                        const panel = document.querySelector('#edit_body');
                        window.noticeClicks = 0;
                        setTimeout(() => {
                          window.jQuery = { _data: el => el === panel ? {click:[{}]} : {} };
                          panel.addEventListener('click', () => {
                            window.noticeClicks++;
                            setTimeout(() => panel.replaceWith(document.querySelector('template').content.cloneNode(true)), 600);
                          });
                        }, 1100);
                        </script>
                        """ + "<template>" + RailwayForm + "</template>";
                    else if (path == "/a79.htm") html = """
                        <title>上网登录页</title><form name=f1><div name=PageTips>已使用时间 / 已使用流量</div>
                        <input type=button name=logout onclick="javascript:wc()" value="注 销(Logout)"></form>
                        <dialog><button id=cancel onclick="this.parentElement.close()">取消</button>
                        <button id=confirm onclick="document.forms.f1.hidden=true;this.parentElement.close();document.querySelector('#message').textContent='注销成功'">确定</button></dialog>
                        <div id=message></div><script>function wc(){document.querySelector('dialog').showModal()}</script>
                        """;
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
