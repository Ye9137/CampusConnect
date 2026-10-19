using CampusConnect;
using System.Text;
using System.Text.Json;

internal static class CaptchaResponseTests
{
    internal static async Task RunAsync(Action<bool, string> expect)
    {
        const string png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aR9sAAAAASUVORK5CYII=";
        const string prefix = "data:image/png;base64,";
        static string Payload(object data, object? code = null) => JsonSerializer.Serialize(new { code = code ?? 0, data });
        static async Task<string?> Read(string body) {
            using var input = new MemoryStream(Encoding.UTF8.GetBytes(body));
            return await PortalCaptchaResponse.ReadAsync(input);
        }
        expect(await Read(Payload(new { image = prefix + png, state = "invented-session" })) == prefix + png, "response preserves original PNG bytes");
        expect(await Read(Payload(new { image = png })) == prefix + png, "raw base64 response normalized");
        expect(await Read(Payload(new { image = prefix + png }, 2)) is null, "failed API response rejected");
        expect(await Read(Payload(new { image = prefix + png }, "0")) is null, "non-numeric API result rejected");
        expect(await Read("[]") is null, "non-object response rejected");
        expect(await Read("{\"data\":{}}") is null, "response requires success code");
        expect(await Read(Payload(new[] { "wrong-shape" })) is null, "response data must be object");
        expect(await Read(Payload(new { image = 42 })) is null, "image must be string");
        expect(await Read(Payload(new { image = "not base64" })) is null, "invalid base64 rejected");
        expect(await Read(Payload(new { image = "data:image/svg+xml;base64," + png })) is null, "unsupported image type rejected");
        expect(await Read("{bad json") is null, "malformed response rejected");
        expect(await Read(new string(' ', PortalCaptchaResponse.MaximumBytes + 1)) is null, "oversized response bounded");
        expect(await Read(Payload(new { image = prefix + Convert.ToBase64String(new byte[40]) })) is null, "non-PNG response rejected");
        foreach (var dimension in new[] { 0u, 1025u }) {
            var bytes = Convert.FromBase64String(png);
            System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(16, 4), dimension);
            expect(await Read(Payload(new { image = prefix + Convert.ToBase64String(bytes) })) is null, "invalid PNG dimensions rejected");
        }
        using (var canceled = new CancellationTokenSource()) {
            canceled.Cancel();
            using var input = new MemoryStream(Encoding.UTF8.GetBytes(Payload(new { image = png })));
            try { await PortalCaptchaResponse.ReadAsync(input, canceled.Token); expect(false, "canceled read must stop"); }
            catch (OperationCanceledException) { expect(true, "canceled response read stops"); }
        }
        const string portal = "https://portal.test/sso/#/passport/login";
        expect(PortalCaptchaResponse.IsCandidate(portal, "https://portal.test/sign/captcha?state=invented", "GET", 200), "direct SSO captcha response recognized");
        expect(PortalCaptchaResponse.IsCandidate(portal, "https://portal.test/https/encoded/sign/captcha?captcha=undefined", "GET", 200), "WebVPN SSO captcha response recognized");
        foreach (var url in new[] { "https://evil.test/sign/captcha", "http://portal.test/sign/captcha", "https://portal.test:8443/sign/captcha", "https://portal.test/sign/captcha-extra" })
            expect(!PortalCaptchaResponse.IsCandidate(portal, url, "GET", 200), "untrusted or unrelated response rejected");
        expect(!PortalCaptchaResponse.IsCandidate(portal, "https://portal.test/sign/captcha", "POST", 200), "response observer does not read login submissions");
        expect(!PortalCaptchaResponse.IsCandidate(portal, "https://portal.test/sign/captcha", "GET", 500), "non-success HTTP status rejected");
    }
}
