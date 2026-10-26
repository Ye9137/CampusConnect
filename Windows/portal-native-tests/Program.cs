using CampusConnect;
using System.Reflection;

internal static class Program
{
    private static int checks;
    private static void Expect(bool condition, string message) { checks++; if (!condition) throw new Exception(message); }
    private static void Set(PortalController portal, string name, object? value)
        => typeof(PortalController).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(portal, value);
    private static void Fail(PortalController portal, string code)
        => typeof(PortalController).GetMethod("Fail", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(portal, [code, "Offline fixture failure."]);
    private static void Interaction(PortalController portal, bool value)
        => typeof(PortalController).GetProperty("RequiresInteraction")!.SetValue(portal, value);
    private static object? Field(PortalController portal, string name)
        => typeof(PortalController).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(portal);
    private static void Follow(PortalController portal, string url)
        => typeof(PortalController).GetMethod("FollowNavigation", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(portal, [url]);
    private static PortalController Create(bool automatic = true, bool submit = true)
    {
        var portal = new PortalController(() => throw new Exception("Offline state tests must not create a browser environment."));
        Set(portal, "profile", new CampusProfile { Automatic = automatic, AutoSubmit = submit, PortalUrl = "http://portal.test/login", Username = "fixture-user" });
        Set(portal, "password", "fixture-secret");
        return portal;
    }
    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        foreach (var submit in new[] { true, false }) {
            var portal = Create(submit: submit);
            try {
                typeof(PortalController).GetProperty("IsActive")!.SetValue(portal, true);
                Set(portal, "redirectSession", new PortalRedirectSession("http://portal.test/login"));
                Set(portal, "continueAfterNavigation", true);
                // A submitted or manually filled first page must not discard the
                // credentials needed by a subsequent SSO login document.
                Set(portal, "finished", true); Interaction(portal, true);
                var notices = 0; portal.Problem += _ => notices++;
                for (var i = 0; i < 100; i++) {
                    var url = i % 2 == 0 ? "https://sso.school.test:8443/login?session=fixture" : "http://portal.test/login";
                    Follow(portal, url);
                    Expect(((CampusProfile)Field(portal, "profile")!).PortalUrl == url, "production controller follows every host, scheme and revisit");
                    Expect((string)Field(portal, "password")! == "fixture-secret", "redirect keeps credentials available for the next document");
                    Expect(!(bool)Field(portal, "finished")! && portal.RequiresInteraction == !submit, "redirect resumes filling while respecting manual submission mode");
                }
                Expect(notices == 0 && portal.CurrentProblem is null, "redirect chain never raises a blocking wizard");
                Fail(portal, "authentication-rejected");
                Follow(portal, "https://sso.school.test/retry");
                Expect(portal.RequiresInteraction && (bool)Field(portal, "finished")! && (string)Field(portal, "password")! == "", "navigation cannot undo a genuine school rejection");
                portal.Stop(clearView: false);
                Follow(portal, "http://portal.test/login");
                Expect(Field(portal, "profile") is null && (string)Field(portal, "password")! == "", "Stop prevents a late redirect from resuming login");
            } finally { portal.View.Dispose(); }
        }
        // Exercise the actual PortalController failure path and the same recovery
        // gate MainForm uses, rather than testing a retry timer in isolation.
        foreach (var code in new[] { "load-temporary", "authentication-timeout", "result-check-interrupted", "authentication-request-failed", "waiting-ready", "script-failed" }) {
            var portal = Create();
            try {
                var notices = 0; var status = "";
                portal.Problem += _ => notices++;
                portal.Status += message => status = message;
                Set(portal, "authenticationDeadline", DateTimeOffset.UtcNow.AddSeconds(30));
                Fail(portal, code);
                Expect(!portal.RequiresInteraction && !portal.IsAuthenticating, code + " releases the retry latch");
                Expect(portal.RetryNotBefore is not null, code + " has a fresh cooldown");
                Expect(notices == 0 && portal.CurrentProblem is null, code + " does not repeat modal notices");
                Expect(status.Contains("自动重试") && !status.Contains("fixture-secret"), code + " reports automatic recovery without credentials");
                Expect((string)typeof(PortalController).GetField("password", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(portal)! == "", code + " clears transient in-memory credentials");
                var recovery = new PortalRecovery();
                recovery.Begin(DateTimeOffset.UtcNow.AddMinutes(-1)); recovery.Observe(InternetStatus.Unavailable);
                bool CanRetry(DateTimeOffset now) => recovery.ShouldAuthenticate(true, true, now,
                    portal.RequiresInteraction, portal.IsAuthenticating, portal.RetryNotBefore);
                var ready = portal.RetryNotBefore!.Value;
                Expect(!CanRetry(ready.AddMilliseconds(-1)), code + " cannot retry before failure cooldown");
                Expect(CanRetry(ready), code + " retries after cooldown even on the same SSID");
                recovery.Observe(InternetStatus.Online);
                Expect(!CanRetry(ready.AddSeconds(20)), code + " never reauthenticates if connectivity already recovered");
                portal.ConfirmInternetAccess();
                Expect(portal.RetryNotBefore is null && !portal.RequiresInteraction, "internet success clears retry hold");
            } finally { portal.View.Dispose(); }
        }
        foreach (var code in new[] { "authentication-rejected", "missing-credentials", "service-required", "missing-service", "agreement-required", "submission-unconfirmed", "wrong-origin", "load-failed", "missing-fields", "missing-submit" }) {
            var portal = Create();
            try {
                Fail(portal, code);
                Expect(portal.RequiresInteraction && portal.RetryNotBefore is null, code + " retains a manual hold");
                var recovery = new PortalRecovery(); recovery.Observe(InternetStatus.Unavailable);
                Expect(!recovery.ShouldAuthenticate(true, true, DateTimeOffset.UtcNow.AddDays(1), portal.RequiresInteraction, portal.IsAuthenticating, portal.RetryNotBefore), code + " never loops on user input or school rejection");
                Expect(portal.CurrentProblem is not null, code + " still offers concrete guidance");
            } finally { portal.View.Dispose(); }
        }
        foreach (var mode in new[] { (automatic: false, submit: true), (automatic: true, submit: false) }) {
            var portal = Create(mode.automatic, mode.submit);
            try {
                Fail(portal, "authentication-timeout");
                Expect(portal.RequiresInteraction && portal.RetryNotBefore is null, "manual mode never silently enables submission");
            } finally { portal.View.Dispose(); }
        }
        foreach (var waitingForUser in new[] { false, true }) {
            var portal = Create();
            try {
                Interaction(portal, true);
                Set(portal, "authenticationDeadline", waitingForUser ? null : DateTimeOffset.UtcNow.AddSeconds(30));
                portal.ResetBrowser();
                Expect(portal.RequiresInteraction == waitingForUser, "browser reset preserves CAPTCHA holds but releases interrupted automatic work");
                Expect((portal.RetryNotBefore is null) == waitingForUser, "browser reset enforces cooldown before unattended retry");
            } finally { portal.View.Dispose(); }
        }
        BrowserRedirectTests.Run(Expect);
        Console.WriteLine($"PASS: {checks} native portal checks (production redirects, recovery, cooldown, manual holds and browser restart).");
    }
}
