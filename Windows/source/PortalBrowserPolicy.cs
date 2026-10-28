namespace CampusConnect;

internal static class PortalBrowserPolicy
{
    // Campus gateways commonly redirect to HTTP-only endpoints. Disable automatic
    // HTTPS upgrades and the default InPrivate HTTPS-First interstitial only in
    // this application's WebView2 environment. Keep normal certificate validation,
    // HSTS, and a dedicated school profile separate from the application shell.
    public const string ProfileName = "CampusPortalHttp";
    public const string Arguments = "--no-proxy-server --disable-features=HttpsUpgrades,HttpsFirstModeIncognito";
}
