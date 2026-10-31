namespace CampusConnect;

internal static class DrcomPortal
{
    internal static bool IsStatusAddress(string? address)
        => CampusProfile.Origin(address ?? "") is not null && Uri.TryCreate(address, UriKind.Absolute, out var uri)
            && uri.Port == 9002 && (uri.AbsolutePath.Equals("/In0", StringComparison.OrdinalIgnoreCase) || uri.AbsolutePath == "/0");

    internal static bool IsStatusPopup(string source, string destination)
        => IsStatusAddress(destination) && CampusProfile.Origin(source) is not null
            && new Uri(source).IdnHost.Equals(new Uri(destination).IdnHost, StringComparison.OrdinalIgnoreCase);
}
