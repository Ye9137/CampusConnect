using CampusConnect;
using System.Text.Json;

internal static class PortalRedirectTests
{
    public static CampusProfile LandingProfile(Action<bool, string> expect)
    {
        var now = DateTimeOffset.UtcNow;
        var saved = new CampusProfile { PortalUrl = "http://1.1.1.1", Username = "fixture-user" };
        var session = new PortalRedirectSession(saved.PortalUrl, now);
        expect(session.Navigate(saved.PortalUrl, false, false, now) == PortalNavigationDecision.Allowed, "saved entry navigation allowed");
        expect(session.Navigate("http://10.129.1.1/landing", false, true, now) == PortalNavigationDecision.Redirected, "HTTP redirect changes active origin");
        expect(session.Navigate("http://10.129.1.1/srv_portal_pc?ac_id=fixture", false, false, now) == PortalNavigationDecision.Allowed, "script redirect to final login path allowed");
        expect(!session.Pinned && !session.Blocked, "intermediate pages do not pin redirect chain");
        var landing = saved with { PortalUrl = session.CurrentUrl };
        expect(saved.PortalUrl == "http://1.1.1.1", "saved entry remains unchanged");
        expect(landing.PortalUrl.EndsWith("?ac_id=fixture"), "in-memory destination keeps school query parameters");
        session.Pin();
        expect(session.Navigate("http://10.129.1.1/success", false, true, now.AddMinutes(1)) == PortalNavigationDecision.Allowed, "pinned school success path remains allowed");
        expect(session.Navigate("http://unrelated.test/login", false, true, now) == PortalNavigationDecision.External, "post-fill redirect cannot gain credential access");
        expect(session.Blocked, "external navigation latches blocked state");
        return landing;
    }

    public static void Run(Action<bool, string> expect)
    {
        var now = DateTimeOffset.UtcNow;
        var landing = LandingProfile(expect);
        var probe = PortalScript.LoginFormProbe(landing);
        expect(!probe.Contains("fixture-user") && !probe.Contains("fixture-password"), "form probe contains no saved credentials");
        var loop = new PortalRedirectSession("http://1.1.1.1", now);
        loop.Navigate("http://1.1.1.1", false, false, now);
        loop.Navigate("http://10.129.1.1/login", false, true, now);
        expect(loop.Navigate("http://1.1.1.1/", false, true, now) == PortalNavigationDecision.Loop, "A-B-A redirect loop detected including normalized slash");
        expect(loop.Blocked, "redirect loop stops subsequent automatic navigation");
        var repeated = new PortalRedirectSession("http://1.1.1.1", now);
        for (var i=0; i<10; i++) expect(repeated.Navigate($"http://1.1.1.1/?nonce={i}", false, i>0, now) == PortalNavigationDecision.Allowed, "bounded unique redirects allowed");
        expect(repeated.Navigate("http://1.1.1.1/?nonce=10", false, true, now) == PortalNavigationDecision.Loop, "changing tokens cannot bypass redirect limit");
        var timed = new PortalRedirectSession("http://1.1.1.1", now);
        expect(timed.Navigate("http://10.129.1.1/login", false, true, now.AddSeconds(31)) == PortalNavigationDecision.Expired, "initial redirect window is bounded");
        var click = new PortalRedirectSession("http://1.1.1.1", now);
        expect(click.Navigate("http://other.test/login", true, false, now) == PortalNavigationDecision.External, "user-clicked external page not silently trusted");
        expect(click.CurrentUrl == "http://1.1.1.1", "blocked destination never replaces active URL");
        var server = new PortalRedirectSession("http://1.1.1.1", now);
        expect(server.Navigate("https://school.test/login", true, true, now) == PortalNavigationDecision.Redirected, "HTTP redirect retains original user gesture without being blocked");
        var downgrade = new PortalRedirectSession("https://school.test", now);
        expect(downgrade.Navigate("http://school.test/login", false, true, now) == PortalNavigationDecision.External, "HTTPS entry cannot silently downgrade");
        foreach (var url in new[] {"javascript:alert(1)", "file:///tmp/login", "http://user:pass@school.test/"}) {
            var invalid = new PortalRedirectSession("http://1.1.1.1", now);
            expect(invalid.Navigate(url, false, true, now) == PortalNavigationDecision.Invalid, "invalid redirect rejected");
        }
        var reset = new PortalRedirectSession("http://1.1.1.1", now.AddMinutes(2));
        expect(reset.Navigate("http://10.129.1.1/new", false, true, now.AddMinutes(2)) == PortalNavigationDecision.Redirected, "explicit retry creates fresh attempt state");
    }
}
