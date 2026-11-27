namespace CampusConnect;

internal static class DrcomPortal
{
    // The desktop notice installs its jQuery click handler on a timer and then
    // replaces the notice with the login form in the same document.
    internal const string AdvanceRailwayNotice = """
        (() => {
          const notice = document.querySelector('#edit_body.divbg');
          if (!notice?.getClientRects().length || !notice.querySelector('#advertTime') ||
              !notice.querySelector('form[name="f79"] input[type="hidden"][name="DDDDD"]') ||
              !notice.querySelector('form[name="f78"] input[type="hidden"][name="upass"]') ||
              !document.querySelector('script[src*="/eportal/extern/nanjingtiedao/"][src*="/pc_79.js"]') ||
              document.querySelector('input[type="password"]')) return '';
          const text = notice.innerText.replace(/\s+/g, '');
          if (!text.includes('校园网络使用须知') || !text.includes('点击任意位置')) return '';
          if (!window.jQuery?._data?.(notice, 'events')?.click?.length) return 'waiting';
          if (window.__campusOpenedRailwayNotice !== notice) {
            window.__campusOpenedRailwayNotice = notice;
            notice.click();
          }
          return 'opening';
        })()
        """;

    internal static bool IsStatusAddress(string? address)
        => CampusProfile.Origin(address ?? "") is not null && Uri.TryCreate(address, UriKind.Absolute, out var uri)
            && uri.Port == 9002 && (uri.AbsolutePath.Equals("/In0", StringComparison.OrdinalIgnoreCase) || uri.AbsolutePath == "/0");

    internal static bool IsUsageAddress(string? address)
        => CampusProfile.Origin(address ?? "") is not null && Uri.TryCreate(address, UriKind.Absolute, out var uri)
            && uri.AbsolutePath.Equals("/a79.htm", StringComparison.OrdinalIgnoreCase);

    internal static bool IsStatusPopup(string source, string destination)
        => IsStatusAddress(destination) && CampusProfile.Origin(source) is not null
            && new Uri(source).IdnHost.Equals(new Uri(destination).IdnHost, StringComparison.OrdinalIgnoreCase);
}
