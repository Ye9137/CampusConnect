using CampusConnect;

internal static class PortalRedirectTests
{
    public static CampusProfile LandingProfile(Action<bool, string> expect)
    {
        var saved = new CampusProfile { PortalUrl = "http://1.1.1.1", Username = "fixture-user" };
        var session = new PortalRedirectSession(saved.PortalUrl);
        expect(session.Navigate(saved.PortalUrl) == PortalNavigationDecision.Allowed, "saved entry navigation allowed");
        expect(session.Navigate("http://10.129.1.1/landing") == PortalNavigationDecision.Redirected, "HTTP redirect changes active origin");
        expect(session.Navigate("http://10.129.1.1/srv_portal_pc?ac_id=fixture") == PortalNavigationDecision.Allowed, "script redirect to final login path allowed");
        var landing = PortalScript.AtCurrentPage(saved, session.CurrentUrl);
        expect(saved.PortalUrl == "http://1.1.1.1", "saved entry remains unchanged");
        expect(landing.PortalUrl.EndsWith("?ac_id=fixture"), "in-memory destination keeps school query parameters");
        expect(session.Navigate("https://school-sso.test/login") == PortalNavigationDecision.Redirected, "school SSO can follow a previously detected form");
        return landing;
    }

    public static void Run(Action<bool, string> expect)
    {
        var landing = LandingProfile(expect);
        var rebound = PortalScript.AtCurrentPage(landing, "https://aaa.school.test:8443/tpl/login_account.html?session=fixture");
        expect(rebound.PortalUrl.Contains(":8443/") && rebound.PortalUrl.EndsWith("session=fixture"), "landing retains HTTPS port, path and dynamic school query");
        expect(rebound.Username == landing.Username && landing.PortalUrl != rebound.PortalUrl, "landing retains account without replacing saved entry");
        foreach (var bad in new[] { "about:blank", "javascript:alert(1)", "file:///tmp/login", "https://user:pass@school.test/" }) {
            try { PortalScript.AtCurrentPage(landing, bad); expect(false, "invalid landing rejected"); }
            catch (InvalidOperationException) { expect(true, "invalid landing rejected"); }
        }
        var probe = PortalScript.LoginFormProbe(landing);
        expect(!probe.Contains("fixture-user") && !probe.Contains("fixture-password"), "form probe contains no saved credentials");
        var session = new PortalRedirectSession("https://entry.school.test/");
        for (var i = 0; i < 100; i++) {
            var url = i % 2 == 0 ? "http://login.school.test:8080/login?session=fixture" : "https://entry.school.test/";
            expect(session.Navigate(url) == PortalNavigationDecision.Redirected, "revisits, HTTP downgrade and more than ten redirects all remain allowed");
            expect(session.CurrentUrl == url, "each redirect immediately becomes the active login destination");
        }
        foreach (var url in new[] { "javascript:alert(1)", "file:///tmp/login", "http://user:pass@school.test/" }) {
            expect(session.Navigate(url) == PortalNavigationDecision.Invalid, "non-web or credential-bearing URL is not a login document");
            expect(session.Navigate("http://login.school.test/") != PortalNavigationDecision.Invalid, "invalid URL cannot latch a block on later web navigation");
        }
    }
}
