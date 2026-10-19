using System.Text.Json;

namespace CampusConnect;

// Reads a response the school's web page already requested. Never fetches or replays it.
internal static class PortalCaptchaResponse
{
    internal const int MaximumBytes = 1_600_000;

    internal static bool IsCandidate(string portalUrl, string requestUrl, string method, int status)
        => method == "GET" && status == 200 &&
           CampusProfile.Origin(portalUrl) is { } origin && CampusProfile.Origin(requestUrl) == origin &&
           Uri.TryCreate(requestUrl, UriKind.Absolute, out var uri) &&
           uri.AbsolutePath.EndsWith("/sign/captcha", StringComparison.Ordinal);

    internal static async Task<string?> ReadAsync(Stream content, CancellationToken cancellationToken = default)
    {
        using var buffer = new MemoryStream();
        var chunk = new byte[8192];
        while (true) {
            var count = await content.ReadAsync(chunk.AsMemory(0, (int)Math.Min(chunk.Length, MaximumBytes + 1 - buffer.Length)), cancellationToken);
            if (count == 0) break;
            buffer.Write(chunk, 0, count);
            if (buffer.Length > MaximumBytes) return null;
        }
        try {
            using var json = JsonDocument.Parse(buffer.ToArray(), new JsonDocumentOptions { MaxDepth = 8 });
            var root = json.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("code", out var code) ||
                code.ValueKind != JsonValueKind.Number || !code.TryGetInt32(out var value) || value != 0 ||
                !root.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Object ||
                !data.TryGetProperty("image", out var image) || image.ValueKind != JsonValueKind.String) return null;
            var raw = image.GetString()!;
            const string prefix = "data:image/png;base64,";
            var normalized = raw.StartsWith(prefix, StringComparison.Ordinal) ? raw : prefix + raw;
            DecodePng(normalized);
            return normalized;
        } catch (Exception ex) when (ex is JsonException or FormatException or InvalidDataException) { return null; }
    }

    internal static byte[] DecodePng(string image)
    {
        const string prefix = "data:image/png;base64,";
        if (!image.StartsWith(prefix, StringComparison.Ordinal) || image.Length > 1_500_000)
            throw new InvalidDataException("验证码图片不可用，请在学校页面手动输入。");
        var bytes = Convert.FromBase64String(image[prefix.Length..]);
        if (bytes.Length < 33 || !bytes.AsSpan(0, 8).SequenceEqual(new byte[] {137,80,78,71,13,10,26,10}) ||
            !bytes.AsSpan(12, 4).SequenceEqual("IHDR"u8) ||
            System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(16, 4)) is 0 or > 1024 ||
            System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(20, 4)) is 0 or > 512)
            throw new InvalidDataException("验证码图片格式不正确。");
        return bytes;
    }
}
