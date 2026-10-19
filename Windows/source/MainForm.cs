using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace CampusConnect;

internal sealed partial class MainForm : Form
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private CampusProfile saved = new();
    private string savedPassword = "";
    private readonly AutoPolicy policy = new();
    private readonly PortalRecovery recovery = new();
    private readonly PortalController portal;
    private WebView2 shell = new() { Dock = DockStyle.Fill };
    private readonly System.Windows.Forms.Timer timer = new() { Interval = AutoPolicy.NetworkCheckIntervalMilliseconds };
    private readonly NotifyIcon tray;
    private readonly StartupRegistration startup = new(Application.ExecutablePath);
    private IReadOnlyList<WifiNetwork> networks = [];
    private string? currentSsid;
    private Guid? wiredInterface;
    private string[] ethernetAdapters = [], broadbandEntries = [];
    private CancellationTokenSource? wiredAttempt;
    private string status = "准备就绪";
    private string portalStatus = "连接校园网后，在这里完成上网认证。";
    private string page = "dashboard";
    private bool pageTransitioning;
    private string lastScan = "";
    private bool busy, joining, checking, exiting, uiReady, permissionNeeded, stateQueued;
    private bool backgroundRefreshing;
    private Task? backgroundRefreshTask;
    private string? lastStateJson;
    private Task<CoreWebView2Environment>? browserEnvironment;
    private Task<(CampusProfile Profile, string Password)>? configurationLoad;
    private bool? online;
    private DateTimeOffset lastInternetCheck = DateTimeOffset.MinValue;
    private DateTimeOffset lastWifiScan = DateTimeOffset.MinValue;
    private int generation;
    private Rectangle portalBounds;
    private readonly string? verificationPath;

    public MainForm(string? verificationPath = null, bool startInTray = false)
    {
        this.verificationPath = verificationPath;
        portal = new(GetBrowserEnvironmentAsync);
        Text = "校园网助手";
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(1280, 860);
        MinimumSize = new Size(996, 739);
        StartPosition = FormStartPosition.CenterScreen;
        if (startInTray) { WindowState = FormWindowState.Minimized; ShowInTaskbar = false; }
        BackColor = Color.White;
        Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application;
        Controls.Add(shell);
        portal.View.Dock = DockStyle.None;
        portal.View.Visible = false;
        Controls.Add(portal.View);
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开主窗口", null, (_, _) => RestoreWindow());
        menu.Items.Add("刷新界面", null, (_, _) => RestoreWindow());
        menu.Items.Add("暂停自动连接", null, (_, _) => Pause());
        menu.Items.Add("退出", null, (_, _) => { exiting = true; Close(); });
        tray = new NotifyIcon { Icon = Icon, Text = "校园网助手", Visible = true, ContextMenuStrip = menu };
        tray.DoubleClick += (_, _) => RestoreWindow();
        FormClosing += (_, e) => {
            if (!exiting && e.CloseReason == CloseReason.UserClosing) {
                e.Cancel = true; Hide();
                tray.ShowBalloonTip(2500, "校园网助手", "程序保留在系统托盘，右键图标可暂停或退出。", ToolTipIcon.Info);
            }
        };
        FormClosed += (_, _) => {
            wiredAttempt?.Cancel();
            timer.Stop(); timer.Dispose(); tray.Dispose();
            portal.View.Dispose(); shell.Dispose();
        };
        portal.Status += message => {
            if (portalStatus != message && message != "已经连接成功") Record(message);
            portalStatus = message; UpdatePortalVisibility(); PushState();
        };
        portal.AddressChanged += () => PushState();
        portal.CaptchaRequired += () => { Navigate("portal"); };
        portal.Submitted += async () => {
            var expected = generation;
            await Task.Delay(1000);
            if (!IsDisposed && expected == generation) await SafeAsync(() => CheckInternetAsync(false));
        };
        timer.Tick += async (_, _) => {
            if (!saved.Automatic || busy || backgroundRefreshTask is { IsCompleted: false }) return;
            backgroundRefreshTask = online == true
                ? SafeAsync(() => CheckInternetAsync(false))
                : RefreshAsync(scan: currentSsid != saved.Ssid && DateTimeOffset.UtcNow - lastWifiScan >= AutoPolicy.WifiScanInterval,
                    waitForScan: false, background: true);
            await backgroundRefreshTask;
        };
        InitializeBrowserRecovery();
        Activated += (_, _) => { if (uiReady) PushStartup(); };
        Shown += async (_, _) => {
            if (startInTray) Hide();
            // Overlap disk/DPAPI work with the WebView2 runtime startup.
            configurationLoad = verificationPath is null ? Task.Run(LocalStore.Load) : Task.FromResult((new CampusProfile(), ""));
            try { await InitializeShellAsync(); }
            catch (WebView2RuntimeNotFoundException) {
                MessageBox.Show(this, "缺少 Microsoft Edge WebView2 组件。请联网后重新运行安装程序，完成组件安装再打开应用。", Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
                exiting = true; Close();
            }
            catch (Exception ex) {
                MessageBox.Show(this, "界面启动失败：" + ex.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
                exiting = true; Close();
            }
        };
    }

    private Task<CoreWebView2Environment> GetBrowserEnvironmentAsync()
    {
        Directory.CreateDirectory(LocalStore.DirectoryPath);
        if (browserEnvironment is { IsFaulted: true } or { IsCanceled: true }) browserEnvironment = null;
        return browserEnvironment ??= CoreWebView2Environment.CreateAsync(null,
            Path.Combine(LocalStore.DirectoryPath, "WebView2"), new CoreWebView2EnvironmentOptions("--no-proxy-server"));
    }

    private async Task InitializeShellAsync()
    {
        var view = shell;
        var environment = await GetBrowserEnvironmentAsync();
        if (IsDisposed || view.IsDisposed || view != shell) return;
        var options = environment.CreateCoreWebView2ControllerOptions();
        options.IsInPrivateModeEnabled = true;
        await view.EnsureCoreWebView2Async(environment, options);
        if (IsDisposed || view.IsDisposed || view != shell) return;
        var core = view.CoreWebView2;
        core.Settings.AreHostObjectsAllowed = false;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.AreBrowserAcceleratorKeysEnabled = false;
        core.Settings.IsZoomControlEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.IsPasswordAutosaveEnabled = false;
        core.Settings.IsGeneralAutofillEnabled = false;
        core.Settings.IsWebMessageEnabled = true;
        core.NavigationStarting += (_, e) => { if (!DesktopBridge.IsTrustedSource(e.Uri)) e.Cancel = true; };
        core.NewWindowRequested += (_, e) => e.Handled = true;
        core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
        core.DownloadStarting += (_, e) => e.Cancel = true;
        using var stream = typeof(MainForm).Assembly.GetManifestResourceStream("CampusConnect.Desktop.html")
            ?? throw new InvalidOperationException("缺少内置界面。");
        using var reader = new StreamReader(stream);
        var bytes = Encoding.UTF8.GetBytes(await reader.ReadToEndAsync());
        core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += (_, e) => {
            var trusted = DesktopBridge.IsTrustedSource(e.Request.Uri);
            e.Response = environment.CreateWebResourceResponse(
                new MemoryStream(trusted ? bytes : []), trusted ? 200 : 403, trusted ? "OK" : "Forbidden",
                "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff");
        };
        core.WebMessageReceived += async (_, e) => {
            // This bridge belongs ONLY to the embedded application UI, never the school browser.
            if (view != shell || !DesktopBridge.IsTrustedSource(e.Source) || e.WebMessageAsJson.Length > 65536) return;
            await SafeAsync(async () => {
                using var document = JsonDocument.Parse(e.WebMessageAsJson);
                await HandleCommandAsync(document.RootElement);
            });
        };
        core.ProcessFailed += (_, e) => {
            if (view == shell) OnShellProcessFailed(e.ProcessFailedKind);
        };
        core.Navigate(DesktopBridge.Uri);
    }

    private async Task HandleCommandAsync(JsonElement message)
    {
        if (!message.TryGetProperty("command", out var property)) return;
        var command = property.GetString();
        // Background reads leave controls usable. Honor a click after the active
        // read finishes instead of rejecting it as a competing scan/connection.
        if (command is "refresh" or "connect" or "save" ||
            command == "setAutomatic" && message.GetProperty("enabled").GetBoolean()) {
            if (backgroundRefreshing && backgroundRefreshTask is { IsCompleted: false } pending)
                await pending;
            if (IsDisposed || Disposing) return;
        }
        switch (command) {
            case "ready":
                if (uiReady) break;
                var firstReady = !configurationLoaded;
                try { if (firstReady && configurationLoad is not null) (saved, savedPassword) = await configurationLoad; }
                catch (Exception ex) { Record("无法读取配置，请重新填写并保存：" + ex.Message); }
                configurationLoaded = true;
                lastStateJson = null;
                uiReady = true; PushProfile(); PushStartup(); SendState();
                Post(new { kind = "restore", page, snapshot = shellSnapshot });
                if (!firstReady) { UpdatePollingSchedule(); break; }
                if (verificationPath is not null) {
                    var result = await shell.CoreWebView2.ExecuteScriptAsync("JSON.stringify({pageCount:document.querySelectorAll('.nav button').length,title:document.title,passwordMasked:document.getElementById('password').type==='password',startupToggle:!!document.getElementById('startup'),byYe:document.querySelector('.author').textContent})");
                    var snapshot = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(JsonSerializer.Deserialize<string>(result) ?? "{}") ?? [];
                    snapshot["mainWindowVisible"] = JsonSerializer.SerializeToElement(Visible);
                    snapshot["showInTaskbar"] = JsonSerializer.SerializeToElement(ShowInTaskbar);
                    File.WriteAllText(verificationPath, JsonSerializer.Serialize(snapshot));
                    exiting = true; Close(); return;
                }
                UpdatePollingSchedule();
                // Connect immediately from the WLAN cache when the target is already visible.
                await RefreshAsync(scan: false);
                if (!saved.IsWired && currentSsid != saved.Ssid) await RefreshAsync(waitForScan: false); break;
            case "hydrated":
                shellReady?.TrySetResult(true);
                break;
            case "draft":
                if (uiReady && message.TryGetProperty("snapshot", out var snapshotData) && snapshotData.ValueKind == JsonValueKind.Object)
                    shellSnapshot = snapshotData.Clone();
                break;
            case "page":
                var next = message.GetProperty("page").GetString();
                if (next is "dashboard" or "settings" or "portal") {
                    page = next;
                    pageTransitioning = message.TryGetProperty("transitioning", out var transition) && transition.ValueKind == JsonValueKind.True;
                    UpdatePortalVisibility();
                }
                break;
            case "portalBounds":
                var requestedPage = message.GetProperty("page").GetString();
                if (requestedPage != page) break;
                var bounds = DesktopBridge.ScaleBounds(message, ClientSize.Width, ClientSize.Height);
                if (bounds is { } value) portalBounds = new(value.X, value.Y, value.Width, value.Height);
                UpdatePortalVisibility(); break;
            case "refresh": await RefreshAsync(); break;
            case "connect": await ManualConnectAsync(); break;
            case "save": SaveFromMessage(message); break;
            case "setAutomatic":
                if (!message.GetProperty("enabled").GetBoolean()) Pause();
                else SaveFromMessage(message, enable: true);
                break;
            case "openPortal": await OpenPortalAsync(); break;
            case "showCaptcha": await portal.ShowCaptchaAsync(); break;
            case "discoverPortal": await OpenPortalAsync(discover: true); break;
            case "stopPortal": StopAuthentication(); portalStatus = "认证已暂停。"; PushState(); UpdatePortalVisibility(); break;
            case "checkInternet": await CheckInternetAsync(false); break;
            case "adoptAddress":
                var url = portal.Address;
                if (CampusProfile.Origin(url) is null) throw new InvalidOperationException("当前没有可保存的认证网址。");
                Post(new { kind = "address", address = url });
                Record("请确认网址属于学校，点击保存后生效。");
                break;
            case "setStartup":
                try {
                    startup.SetEnabled(message.GetProperty("enabled").GetBoolean());
                    Record(startup.IsEnabled() ? "开机自启已开启，登录 Windows 后在托盘运行。" : "开机自启已关闭。");
                } finally { PushStartup(); }
                break;
            case "location": OpenSettings("ms-settings:privacy-location"); break;
            case "wifiSettings": OpenSettings("ms-settings:network-wifi"); break;
            case "ethernetSettings": OpenSettings("ms-settings:network-ethernet"); break;
            case "broadbandSettings": OpenSettings("ms-settings:network-dialup"); break;
            case "networkConnections": Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "control.exe")) { Arguments = "ncpa.cpl", UseShellExecute = true }); break;
            case "chooseAuthClient":
                using (var picker = new OpenFileDialog { Title = "选择学校认证客户端", Filter = "应用程序 (*.exe)|*.exe", CheckFileExists = true }) {
                    if (picker.ShowDialog(this) == DialogResult.OK) Post(new { kind = "authClient", path = picker.FileName });
                }
                break;
        }
    }

    private void UpdatePortalVisibility()
    {
        if (IsDisposed) return;
        var show = uiReady && page == "portal" && !pageTransitioning && portal.IsActive && portalBounds.Width > 0 && portalBounds.Height > 0;
        if (show) {
            if (portal.View.Bounds != portalBounds) portal.View.Bounds = portalBounds;
            if (!portal.View.Visible) portal.View.BringToFront();
        }
        if (portal.View.Visible != show) {
            portal.View.Visible = show;
            if (show) portal.ResumeView();
        }
    }
    private void Post(object message)
    {
        if (!uiReady || IsDisposed || Disposing) return;
        try {
            if (shell.CoreWebView2 is { } core && DesktopBridge.IsTrustedSource(core.Source))
                core.PostWebMessageAsJson(JsonSerializer.Serialize(message, JsonOptions));
        } catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException) {
            RequestShellRecovery();
        }
    }
    private void PushStartup()
    {
        try { Post(new { kind = "startup", enabled = startup.IsEnabled(), available = true }); }
        catch (Exception ex) { Post(new { kind = "startup", enabled = false, available = false, error = "无法读取启动项：" + ex.Message }); }
    }
    private void PushProfile() => Post(new { kind = "profile", profile = saved, password = savedPassword });
    private void PushState()
    {
        if (!uiReady || IsDisposed || Disposing || !IsHandleCreated || stateQueued) return;
        // Several updates in one command should render a single final snapshot.
        stateQueued = true;
        BeginInvoke((Action)(() => {
            stateQueued = false;
            if (!IsDisposed && !Disposing) SendState();
        }));
    }
    private void SendState()
    {
        var connectionLabel = saved.ConnectionLabel;
        var windowTitle = "校园网助手 · " + connectionLabel;
        if (Text != windowTitle) Text = windowTitle;
        if (tray.Text != windowTitle) tray.Text = windowTitle;
        var connected = saved.MatchesNetwork(currentSsid, saved.IsWired && CampusNetwork.ReadWiredInterface(saved) is not null);
        var title = saved.IsWired ? (connected ? (online == true ? "有线校园网已连接 · 可上网" : online == false ? "有线网络已连接 · 未联网" : "有线网络已连接 · 正在确认上网状态") : "有线网络未连接，请插好网线") : joining ? "正在连接校园网" : permissionNeeded ? "等待 Wi-Fi 访问授权" :
            connected ? (online == true ? "校园网已连接 · 可上网" : online == false ? "Wi-Fi 已连接 · 未联网" : "Wi-Fi 已连接 · 正在确认上网状态") :
            currentSsid is null ? "当前未连接 Wi-Fi" : "已连接 " + currentSsid;
        if (saved.IsWired && saved.UsesSystemAuthentication) title = joining ? "正在连接 · " + saved.ConnectionLabel
            : wiredInterface is null ? "有线网络未连接，请插好网线"
            : online == true && connected ? saved.ConnectionLabel + " · 可上网" : saved.ConnectionLabel + " · 等待认证或联网确认";
        var message = new { kind = "state", state = new {
            target = saved.IsWired ? "有线网络" : saved.Ssid, wiredMode = saved.IsWired, currentSsid, campusConnected = connected, internetOnline = connected && online == true, connectionTitle = title,
            wiredAuth = saved.WiredAuth, connectionLabel = saved.ConnectionLabel, webPortalEnabled = saved.UsesWebPortal,
            ethernetAdapters, broadbandEntries,
            automatic = saved.Automatic, busy = DesktopBridge.ControlsBusy(busy, backgroundRefreshing), permissionNeeded, lastScan, status,
            portalStatus, portalAddress = portal.Address,
            networks = networks.DistinctBy(n => n.Ssid).Select(n => new { n.Ssid, n.Signal, n.Secure }).ToArray()
        }};
        var serialized = JsonSerializer.Serialize(message, JsonOptions);
        if (serialized == lastStateJson) return;
        lastStateJson = serialized;
        Post(message);
    }
    private void Navigate(string target) { page = target; UpdatePortalVisibility(); Post(new { kind = "page", page = target }); }
    private void SaveFromMessage(JsonElement message, bool? enable = null)
    {
        if (busy) { Record("正在扫描或连接，请稍候再保存。"); PushState(); return; }
        var draft = message.GetProperty("profile").Deserialize<CampusProfile>(JsonOptions)
            ?? throw new InvalidOperationException("设置无效。");
        draft = draft with { Ssid = draft.Ssid.Trim(), PortalUrl = draft.PortalUrl.Trim(), Username = draft.Username.Trim(),
            EthernetName = draft.EthernetName.Trim(), BroadbandName = draft.BroadbandName.Trim() };
        if (enable is not null) draft = draft with { Automatic = enable.Value };
        var secret = message.GetProperty("password").GetString() ?? "";
        draft.Validate();
        if (draft.Automatic && draft.UsesWebPortal && (draft.Username.Length == 0 || secret.Length == 0))
            throw new InvalidOperationException("请先填写上网账号和密码，再开启自动连接。");
        LocalStore.Save(draft, secret);
        wiredAttempt?.Cancel();
        generation++; saved = draft; savedPassword = secret; policy.Reset(); recovery.Reset(); online = null;
        UpdatePollingSchedule();
        currentSsid = null; wiredInterface = null; permissionNeeded = false; networks = [];
        StopAuthentication(); UpdatePortalVisibility(); shellSnapshot = null; PushProfile();
        Record(saved.Automatic ? "设置已保存，自动连接已开启。" : "设置已保存。");
        _ = RefreshAsync(scan: false);
    }
    private void Pause()
    {
        wiredAttempt?.Cancel();
        generation++; recovery.Reset(); saved = saved with { Automatic = false }; StopAuthentication(); UpdatePortalVisibility();
        UpdatePollingSchedule();
        try { LocalStore.Save(saved, savedPassword); Record("自动连接已暂停。"); }
        catch (Exception ex) { Record("本次运行已暂停，但保存设置失败：" + ex.Message); }
    }
    private void Record(string message)
    {
        if (IsDisposed) return;
        status = message;
        PushState();
    }
    private async Task SafeAsync(Func<Task> action)
    {
        try { await action(); }
        catch (Exception ex) {
            if (ex.Message.Contains("定位", StringComparison.Ordinal)) permissionNeeded = true;
            Record(ex.Message);
        }
    }
    private async Task RefreshAsync(bool scan = true, bool waitForScan = true, bool background = false)
    {
        if (busy || IsDisposed) return;
        busy = true; backgroundRefreshing = background;
        if (!background) PushState();
        try {
            await SafeAsync(async () => {
                var expected = generation;
                var choices = await Task.Run(() => (
                    Ethernet: CampusNetwork.ReadLinks().Where(n => CampusNetwork.IsWiredInterface(n.Type, System.Net.NetworkInformation.OperationalStatus.Up)).Select(n => n.Name).ToArray(),
                    Broadband: WiredAuthentication.ReadBroadbandEntries().Select(e => e.Name).ToArray()));
                if (IsDisposed || expected != generation) return;
                ethernetAdapters = choices.Ethernet; broadbandEntries = choices.Broadband;
                if (saved.IsWired) {
                    RefreshWiredConnection();
                    if (wiredInterface is not null) await ConnectWiredAsync(manual: false);
                    return;
                }
                if (scan) lastWifiScan = DateTimeOffset.UtcNow;
                var snapshot = await WifiService.ReadSnapshotAsync(saved.Ssid, scan, waitForScan);
                if (IsDisposed || expected != generation) return;
                permissionNeeded = false; networks = snapshot.Networks; lastScan = DateTime.Now.ToString("HH:mm");
                if (currentSsid != snapshot.Current) {
                    currentSsid = snapshot.Current; expected = ++generation; recovery.Reset(); online = null;
                    StopAuthentication(); UpdatePortalVisibility();
                    Record(currentSsid is null ? "Wi-Fi 连接已断开。" : "当前连接：" + currentSsid);
                }
                if (snapshot.Current == saved.Ssid) {
                    _ = SafeAsync(CheckInternetIfDueAsync);
                } else if (policy.ShouldJoin(saved.Automatic, saved.Ssid, snapshot.Current, snapshot.Networks.Select(n => n.Ssid), false, DateTimeOffset.UtcNow)) {
                    await ConnectAsync(snapshot, expected);
                } else if (saved.Automatic) {
                    Record($"正在等待 {saved.Ssid}，每 1 秒检查一次。");
                }
            });
        } finally { backgroundRefreshing = false; busy = false; PushState(); }
    }
    private void RefreshWiredConnection()
    {
        var current = CampusNetwork.ReadPhysicalLink(saved)?.Id;
        permissionNeeded = false; currentSsid = null; networks = []; lastScan = DateTime.Now.ToString("HH:mm");
        if (wiredInterface != current) {
            wiredInterface = current; generation++; recovery.Reset(); online = null;
            StopAuthentication(); UpdatePortalVisibility();
        }
        if (current is null) Record("有线网络未连接，请插好网线并在系统中启用以太网。");
    }
    private async Task ManualConnectAsync()
    {
        if (busy) { Record("正在扫描或连接，请稍候。"); return; }
        busy = true; PushState();
        try {
            policy.Reset();
            if (saved.IsWired) {
                RefreshWiredConnection();
                if (wiredInterface is null) return;
                await ConnectWiredAsync(manual: true);
                return;
            }
            var expected = generation;
            Record("正在寻找已保存的校园 Wi-Fi…");
            var snapshot = await WifiService.ReadSnapshotAsync(saved.Ssid);
            if (expected == generation && !IsDisposed) await ConnectAsync(snapshot, expected, manual: true);
        } finally { busy = false; PushState(); }
    }
    private async Task ConnectWiredAsync(bool manual)
    {
        var expected = generation;
        var active = saved;
        if (active.UsesSystemAuthentication && (manual || policy.ShouldPrepareWired(active.Automatic, online != true, joining, DateTimeOffset.UtcNow))) {
            if (active.WiredAuth != "pppoe" || !await CampusNetwork.IsAvailableAsync(active)) {
                using var cancellation = new CancellationTokenSource();
                wiredAttempt = cancellation;
                joining = true; policy.Begin(DateTimeOffset.UtcNow); PushState();
                try {
                    Record("正在连接 · " + active.ConnectionLabel);
                    var result = await WiredAuthentication.ConnectAsync(active, CampusNetwork.ReadPhysicalLink(active)?.Name ?? "", cancellation.Token);
                    if (expected != generation || IsDisposed) return;
                    Record(result);
                } catch (OperationCanceledException) { return; }
                finally { if (wiredAttempt == cancellation) wiredAttempt = null; joining = false; PushState(); }
            }
        }
        if (expected != generation || IsDisposed) return;
        if (manual && active.UsesWebPortal) await OpenPortalAsync();
        if (manual) await CheckInternetAsync(false);
        else await CheckInternetIfDueAsync();
    }
    private async Task ConnectAsync(WifiSnapshot snapshot, int expected, bool manual = false)
    {
        policy.Begin(DateTimeOffset.UtcNow); joining = true; PushState();
        try { await WifiService.JoinAsync(saved, snapshot); }
        catch (Exception ex) {
            throw new InvalidOperationException(ex.Message + (saved.Automatic
                ? " 将继续自动重试，不限制次数。" : ""), ex);
        } finally { joining = false; PushState(); }
        if (expected != generation || IsDisposed) return;
        currentSsid = saved.Ssid; recovery.Reset(); online = null; permissionNeeded = false;
        Record("已连接校园 Wi-Fi，正在检查上网状态…");
        if (manual && saved.UsesWebPortal) await OpenPortalAsync();
        await CheckInternetAsync(!manual && saved.Automatic);
    }
    private Task CheckInternetIfDueAsync()
        => online is null || DateTimeOffset.UtcNow - lastInternetCheck >= AutoPolicy.InternetCheckInterval
            ? CheckInternetAsync(saved.Automatic) : Task.CompletedTask;

    private void UpdatePollingSchedule()
    {
        if (IsDisposed || Disposing || exiting) return;
        if (!configurationLoaded || !saved.Automatic) { timer.Stop(); return; }
        // Online: only a slower reachability probe. Offline: resume quick network discovery.
        var interval = online == true ? (int)AutoPolicy.InternetCheckInterval.TotalMilliseconds
            : AutoPolicy.NetworkCheckIntervalMilliseconds;
        if (timer.Interval != interval) timer.Interval = interval;
        if (!timer.Enabled) timer.Start();
    }

    private async Task CheckInternetAsync(bool openIfOffline)
    {
        if (checking) return;
        checking = true;
        lastInternetCheck = DateTimeOffset.UtcNow;
        var expected = generation;
        try {
            var activeProfile = saved;
            var connected = await CampusNetwork.IsAvailableAsync(activeProfile);
            if (expected != generation || IsDisposed) return;
            if (!connected) {
                online = false; recovery.Observe(InternetStatus.Unavailable);
                Record(activeProfile.IsWired ? activeProfile.WiredAuth == "pppoe" ? "PPPoE 尚未建立连接，请检查 Windows 宽带连接设置。" : "请先插好网线并启用有线网络。" : "请先连接校园 Wi-Fi。"); return;
            }
            // Start the first login before waiting for external internet probes.
            if (openIfOffline && online is null && !portal.RequiresInteraction &&
                recovery.ShouldAuthenticate(saved.Automatic, saved.UsesWebPortal, DateTimeOffset.UtcNow)) {
                Record("正在立即发起校园网认证…");
                await OpenPortalAsync(showPage: false);
                if (expected != generation || IsDisposed) return;
            }
            var adapter = await CampusNetwork.ReadInterfaceAsync(activeProfile);
            if (expected != generation || IsDisposed) return;
            var result = await Connectivity.CheckAsync(adapter);
            if (expected != generation || IsDisposed) return;
            connected = await CampusNetwork.IsAvailableAsync(activeProfile);
            if (expected != generation || IsDisposed) return;
            if (!connected) {
                online = false; recovery.Observe(InternetStatus.Unavailable); portal.ReportInternetUnavailable();
                Record("校园网络连接已变化，等待重新连接。"); return;
            }
            online = result == InternetStatus.Online;
            recovery.Observe(result);
            if (result == InternetStatus.Online) { portal.ConfirmInternetAccess(); status = ""; }
            else portal.ReportInternetUnavailable();
            if (result != InternetStatus.Online) Record("百度 ping 不通，判定未联网。");
            if (saved.Automatic && saved.AutoSubmit && !portal.RequiresInteraction && !portal.IsAuthenticating && recovery.ShouldAuthenticate(saved.Automatic, saved.UsesWebPortal, DateTimeOffset.UtcNow)) {
                Record("百度 ping 不通，正在重新连接校园网认证…");
                await OpenPortalAsync(showPage: false);
            }
        } catch {
            if (expected == generation) online = false;
            throw;
        } finally { checking = false; UpdatePollingSchedule(); PushState(); }
    }
    private void StopAuthentication()
    {
        portal.Stop();
    }
    private async Task OpenPortalAsync(bool discover = false, bool showPage = true)
    {
        if (saved.UsesSystemAuthentication) { Record("当前使用系统认证，请在网络概览点击立即连接。"); return; }
        if (!saved.UsesWebPortal && !discover) { Record("网页认证已关闭，请在设置中开启并保存。"); return; }
        recovery.Begin(DateTimeOffset.UtcNow);
        if (showPage) Navigate("portal");
        await portal.OpenAsync(saved, savedPassword, discover);
        UpdatePortalVisibility(); PushState();
    }
    private static void OpenSettings(string uri) => Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true });
    private void RestoreWindow() {
        ShowInTaskbar = true; Show(); WindowState = FormWindowState.Normal; Activate();
        RequestShellRecovery(userRequested: true);
    }
}
