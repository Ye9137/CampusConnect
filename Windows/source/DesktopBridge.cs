using System.Text.Json;

namespace CampusConnect;

public static class DesktopBridge
{
    // Background polling and automatic reconnects serialize native work without
    // repeatedly disabling the user interface. Explicit user operations still lock.
    public static bool ControlsBusy(bool operationRunning, bool backgroundRefresh) => operationRunning && !backgroundRefresh;

    public const string Uri = "https://campusconnect-ui.invalid/";
    // A school page must never be allowed to issue native commands or read the settings UI.
    public static bool IsTrustedSource(string? source) => string.Equals(source, Uri, StringComparison.Ordinal);

    public static (int X, int Y, int Width, int Height)? ScaleBounds(JsonElement message, int clientWidth, int clientHeight)
    {
        double Get(string key) => message.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) ? number : double.NaN;
        var x = Get("x"); var y = Get("y"); var width = Get("width"); var height = Get("height");
        var viewportWidth = Get("viewportWidth"); var viewportHeight = Get("viewportHeight");
        if (!new[] { x, y, width, height, viewportWidth, viewportHeight }.All(double.IsFinite) ||
            viewportWidth <= 0 || viewportHeight <= 0 || x < 0 || y < 0 || width <= 0 || height <= 0 ||
            x + width > viewportWidth + 1 || y + height > viewportHeight + 1 || clientWidth <= 0 || clientHeight <= 0)
            return null;
        var scaleX = clientWidth / viewportWidth; var scaleY = clientHeight / viewportHeight;
        var left = (int)Math.Round(x * scaleX); var top = (int)Math.Round(y * scaleY);
        var right = Math.Min(clientWidth, (int)Math.Round((x + width) * scaleX));
        var bottom = Math.Min(clientHeight, (int)Math.Round((y + height) * scaleY));
        return (left, top, Math.Max(0, right - left), Math.Max(0, bottom - top));
    }
}
