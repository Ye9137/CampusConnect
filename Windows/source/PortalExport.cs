using System.IO.Compression;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Web.WebView2.Core;

namespace CampusConnect;

internal sealed partial class MainForm
{
    private bool exportingPortal;

    private async Task ExportPortalAsync()
    {
        if (exportingPortal) return;
        var browser = portal.View.CoreWebView2;
        if (page != "portal" || !portal.IsActive || browser is null || CampusProfile.Origin(portal.Address) is null) {
            Record("请先在上网认证中打开要导出的网页。");
            return;
        }
        exportingPortal = true;
        PushState();
        using var navigation = new CancellationTokenSource();
        void OnNavigation(object? sender, CoreWebView2NavigationStartingEventArgs e) => navigation.Cancel();
        browser.NavigationStarting += OnNavigation;
        try {
            using var picker = new SaveFileDialog {
                Title = "保存当前网页的前端代码", Filter = "ZIP 压缩包 (*.zip)|*.zip",
                FileName = $"认证页前端-{DateTime.Now:yyyyMMdd-HHmmss}.zip", DefaultExt = "zip", AddExtension = true
            };
            if (picker.ShowDialog(this) != DialogResult.OK) return;
            Record("正在整理页面、控件和代码…");
            var secrets = new[] { savedPassword, saved.Username, backupWifi?.Password, backupWifi?.Profile.Username };
            var result = await PortalExport.SaveAsync(browser, picker.FileName, secrets, navigation.Token);
            var detail = result.Unavailable == 0 ? "已识别的前端资源均已保存" : $"有 {result.Unavailable} 项未收齐，详见 manifest.json";
            Record($"已保存 {result.Files} 个文件，{detail}：{picker.FileName}");
        } catch (OperationCanceledException) {
            Record("导出期间网页已跳转或响应超时，请在目标页面重新打包。");
        } catch (Exception ex) {
            Record("网页代码导出失败：" + ex.Message);
        } finally {
            try { browser.NavigationStarting -= OnNavigation; } catch (InvalidOperationException) { }
            exportingPortal = false;
            PushState();
        }
    }
}

internal static class PortalExport
{
    internal sealed record ExportResult(int Files, int Unavailable);
    private static readonly JsonSerializerOptions Pretty = new() {
        WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };
    private static readonly Lazy<string> Snapshot = new(() => {
        using var stream = typeof(PortalExport).Assembly.GetManifestResourceStream("CampusConnect.PortalExport.js")
            ?? throw new InvalidOperationException("缺少网页导出组件。");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    });

    public static async Task<ExportResult> SaveAsync(CoreWebView2 browser, string destination, string?[] secrets, CancellationToken navigation)
    {
        var token = navigation;
        async Task<JsonElement> Call(string method, object args) {
            token.ThrowIfCancellationRequested();
            var json = await browser.CallDevToolsProtocolMethodAsync(method, JsonSerializer.Serialize(args)).WaitAsync(TimeSpan.FromSeconds(45), token);
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.Clone();
        }

        await Call("Page.enable", new { });
        var tree = (await Call("Page.getResourceTree", new { })).GetProperty("frameTree");
        var capture = await Call("Runtime.evaluate", new { expression = Snapshot.Value, includeCommandLineAPI = true,
            returnByValue = true, timeout = 30000 });
        if (capture.TryGetProperty("exceptionDetails", out _) ||
            !capture.GetProperty("result").TryGetProperty("value", out var value))
            throw new InvalidOperationException("无法读取当前页面结构，可能已跳转或超过页面大小限制。");
        var notes = value.GetProperty("notes").Deserialize<List<string>>()!;
        var resources = new List<object>();
        var known = secrets.Where(s => !string.IsNullOrEmpty(s)).Select(s => s!).Distinct()
            .OrderByDescending(s => s.Length).ToArray();
        string Mask(string text) {
            foreach (var s in known)
                if (s.Length >= 4 || text == s) text = text.Replace(s, "[已隐藏]", StringComparison.Ordinal);
            return text;
        }
        JsonNode? MaskJson(JsonElement element) => element.ValueKind switch {
            JsonValueKind.String => JsonValue.Create(Mask(element.GetString()!)),
            JsonValueKind.Array => new JsonArray(element.EnumerateArray().Select(MaskJson).ToArray()),
            JsonValueKind.Object => new JsonObject(element.EnumerateObject().Select(p =>
                KeyValuePair.Create(p.Name, MaskJson(p.Value)))),
            _ => JsonNode.Parse(element.GetRawText())
        };

        var temp = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(destination))!, $".{Guid.NewGuid():N}.tmp");
        try {
            ExportResult result;
            using (var zip = ZipFile.Open(temp, ZipArchiveMode.Create)) {
                result = await Build(zip);
            }
            token.ThrowIfCancellationRequested();
            File.Move(temp, destination, true);
            return result;
        } finally { File.Delete(temp); }

        async Task<ExportResult> Build(ZipArchive zip)
        {
            int files = 0, unavailable = 0, excluded = 0, saved = 0;
            async Task Write(string path, byte[] bytes) {
                token.ThrowIfCancellationRequested();
                // Keep a single resource in memory and serialize writes to the archive.
                await Task.Run(() => {
                    using var output = zip.CreateEntry(path, CompressionLevel.Fastest).Open();
                    output.Write(bytes);
                }, token);
                files++;
            }
            Task Add(string path, string text) => Write(path, Encoding.UTF8.GetBytes(text));

            var pages = value.GetProperty("pages").EnumerateArray();
            var pageIndex = 0;
            foreach (var page in pages) {
                var prefix = $"pages/{++pageIndex:D3}/";
                await Add(prefix + "page.html.txt", Mask(page.GetProperty("html").GetString()!));
                var styles = new JsonArray();
                foreach (var sheet in page.GetProperty("styles").EnumerateArray()) {
                    var name = prefix + $"styles/{styles.Count + 1:D3}.css";
                    await Add(name, Mask(sheet.GetProperty("css").GetString()!));
                    styles.Add(new JsonObject { ["scope"] = MaskJson(sheet.GetProperty("scope")),
                        ["source"] = MaskJson(sheet.GetProperty("source")), ["file"] = name });
                }
                var index = new JsonObject { ["styles"] = styles };
                foreach (var field in new[] {"context","url","controls","listeners"})
                    index[field] = MaskJson(page.GetProperty(field));
                await Add(prefix + "controls.json", index.ToJsonString(Pretty));
            }
            // Index N in controls.json resolves to handlers/N.js, including delegated listeners.
            var handlerIndex = 0;
            foreach (var handler in value.GetProperty("handlers").EnumerateArray())
                await Add($"handlers/{handlerIndex++}.js", Mask(handler.GetString()!));


            var rootOrigin = CampusProfile.Origin(browser.Source);
            var visited = new HashSet<(string Frame,string Url,string Type)>();
            foreach (var (frame, asset) in FrameAssets(tree, rootOrigin, notes, value.GetProperty("pages"))) {
                var address = asset.GetProperty("url").GetString()!;
                var type = asset.GetProperty("type").GetString()!;
                if (!visited.Add((frame,address,type))) continue;
                var mime = asset.TryGetProperty("mimeType", out var m) ? m.GetString()?.Split(';')[0].ToLowerInvariant() ?? "" : "";
                var format = AssetFormat(type, mime, address);
                var url = Mask(DisplayAddress(address));
                string? file = null;
                string status;
                if (format is null) {
                    status = "未归档：非静态前端资源";
                    excluded++;
                } else {
                    byte[]? bytes = null;
                    try {
                        var reply = await Call("Page.getResourceContent", new { frameId = frame, url = address });
                        var content = reply.GetProperty("content").GetString()!;
                        var encoded = reply.GetProperty("base64Encoded").GetBoolean();
                        if (encoded) bytes = Convert.FromBase64String(content);
                        if (format.Value.Text) {
                            var text = encoded ? Encoding.UTF8.GetString(bytes!) : content;
                            bytes = Encoding.UTF8.GetBytes(Mask(text));
                        }
                        if (bytes == null) throw new FormatException("Missing binary representation");
                        status = "已保存";
                    } catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or ArgumentException
                        or InvalidOperationException or KeyNotFoundException or FormatException or TimeoutException) {
                        token.ThrowIfCancellationRequested();
                        status = ex is TimeoutException ? "浏览器读取超时" : "浏览器未提供该资源";
                        unavailable++;
                    }
                    if (status == "已保存") {
                        file = $"assets/{resources.Count + 1:D3}.{format.Value.Extension}";
                        await Write(file, bytes!);
                        saved++;
                    }
                }
                resources.Add(new { frame, url, type, mime, file, result = status });
            }
            var missing = unavailable + notes.Count;
            await Add("manifest.json", JsonSerializer.Serialize(new { pages = pageIndex, handlers = handlerIndex,
                savedResources = saved, unavailableResources = unavailable, excludedResources = excluded,
                coverageNotes = notes.Count, resources, notes = notes.Select(Mask) }, Pretty));
            await Add("阅读说明.txt", "在 pages 中按页面查看 page.html.txt 和 controls.json。事件编号对应 handlers 下的 JS 文件，styles 收录运行时可读取的样式规则。\r\n" +
                "assets 保存浏览器提供的已加载静态前端资源，含脚本、样式、图片、字体及可读取的媒体等。manifest.json 记录来源、保存结果、未收齐事项和范围外的条目。\r\n" +
                "导出范围是点击时的页面。同源内嵌页、开放的 Shadow DOM 和页面使用的外部资源均参与收集。表单输入、接口响应数据、Cookie 和浏览器存储不在导出范围内。分享前请检查站点内容中的私人信息。");
            return new ExportResult(files, missing);
        }
    }

    private static string DisplayAddress(string address)
    {
        if (address.StartsWith("data:",StringComparison.OrdinalIgnoreCase)) return "data:（内嵌资源）";
        if (address.StartsWith("blob:",StringComparison.OrdinalIgnoreCase)) return "blob:（临时资源）";
        return Uri.TryCreate(address, UriKind.Absolute, out var url) && url.Scheme is "http" or "https"
            ? url.GetComponents(UriComponents.SchemeAndServer | UriComponents.Path, UriFormat.UriEscaped) : "（其他地址）";
    }

    private static (string Extension, bool Text)? AssetFormat(string type, string mime, string address)
    {
        if (type is "XHR" or "Fetch" && mime != "application/wasm" && mime != "text/css" &&
            !mime.EndsWith("javascript",StringComparison.Ordinal) && !mime.EndsWith("ecmascript",StringComparison.Ordinal)) return null;
        if (type == "Wasm" || mime == "application/wasm") return ("wasm",false);
        if (type == "Script" || mime.EndsWith("javascript",StringComparison.Ordinal) || mime.EndsWith("ecmascript",StringComparison.Ordinal)) return ("js",true);
        if (type == "Stylesheet" || mime == "text/css") return ("css",true);
        if (type == "Manifest" || mime == "application/manifest+json") return ("webmanifest",true);
        if (mime == "image/svg+xml") return ("svg",true);
        if (type is not ("Image" or "Font" or "Media") && !mime.StartsWith("image/") && !mime.StartsWith("font/") &&
            !mime.StartsWith("audio/") && !mime.StartsWith("video/")) return null;
        var extension = mime switch {
            "image/jpeg" => "jpg", "image/vnd.microsoft.icon" or "image/x-icon" => "ico",
            "application/font-woff" => "woff", "application/vnd.ms-fontobject" => "eot",
            "audio/mpeg" => "mp3", "audio/ogg" => "ogg", "video/quicktime" => "mov",
            _ => mime.Split('/').Last()
        };
        if (extension is "" or "octet-stream") {
            var uriPath = Uri.TryCreate(address,UriKind.Absolute,out var u) && u.Scheme is "http" or "https" ? u.AbsolutePath : "";
            extension = Path.GetExtension(uriPath).TrimStart('.').ToLowerInvariant();
        }
        if (extension is not ("png" or "jpg" or "gif" or "webp" or "ico" or "avif" or "bmp" or "heic" or "apng"
            or "woff" or "woff2" or "ttf" or "otf" or "eot" or "mp3" or "mp4" or "ogg" or "webm" or "wav"
            or "flac" or "aac" or "mov")) extension = "bin";
        return (extension,false);
    }

    private static IEnumerable<(string Frame, JsonElement Asset)> FrameAssets(JsonElement tree, string? origin, List<string> notes, JsonElement pages)
    {
        var id = tree.GetProperty("frame").GetProperty("id").GetString()!;
        var addresses = new HashSet<string>(StringComparer.Ordinal);
        foreach (var asset in tree.GetProperty("resources").EnumerateArray()) {
            addresses.Add(asset.GetProperty("url").GetString()!);
            yield return (id, asset);
        }
        var documentUrl = tree.GetProperty("frame").GetProperty("url").GetString()!.Split('#')[0];
        foreach (var page in pages.EnumerateArray()) {
            if (page.GetProperty("documentAddress").GetString()!.Split('#')[0] != documentUrl) continue;
            foreach (var reference in page.GetProperty("references").EnumerateArray()) {
                var url = reference[0].GetString()!;
                if (!addresses.Add(url)) continue;
                yield return (id, JsonSerializer.SerializeToElement(new {url, type = reference[1].GetString()}));
            }
        }
        if (!tree.TryGetProperty("childFrames", out var children)) yield break;
        foreach (var child in children.EnumerateArray()) {
            var frame = child.GetProperty("frame");
            if (!frame.TryGetProperty("securityOrigin", out var childOrigin) ||
                !string.Equals(CampusProfile.Origin(childOrigin.GetString()!), origin, StringComparison.OrdinalIgnoreCase)) {
                notes.Add("内嵌页资源不可读取：" + DisplayAddress(frame.GetProperty("url").GetString()!));
                continue;
            }
            foreach (var item in FrameAssets(child, origin, notes, pages)) yield return item;
        }
    }
}
