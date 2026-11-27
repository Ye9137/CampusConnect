using System.IO.Compression;
using System.Text.Json;
using CampusConnect;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

internal static class BrowserExportTests
{
    public static void Run(Action<bool,string> expect)
    {
        var temp = Directory.CreateTempSubdirectory("campus-export-");
        var pages = temp.CreateSubdirectory("pages").FullName;
        File.WriteAllText(Path.Combine(pages,"index.html"), """
            <meta charset=utf-8><link rel="stylesheet" href="site.css?v=QUERY_PRIVATE">
            <input type=password value="FIELD_PRIVATE"><input type=hidden value="HIDDEN_PRIVATE">
            <textarea>TEXT_PRIVATE</textarea><div contenteditable>EDIT_PRIVATE</div>
            <button id="login" onclick="return false"><span>登录</span></button><a href="javascript:manualSubmit()">提交</a><iframe src="frame.html"></iframe>
            <svg viewBox="0 0 8 8"><path id="glyph" d="M0 0L8 8"/><use href="#glyph"/></svg>
            <iframe sandbox srcdoc="<b>FRAME_PRIVATE</b>"></iframe>
            <script src="site.js"></script><script src="large.js"></script><img src="dot.png"><img src="icon.svg">
            """);
        File.WriteAllText(Path.Combine(pages,"frame.html"), "<button id='frame-submit'>确认</button>");
        File.WriteAllText(Path.Combine(pages,"site.js"), """
            document.getElementById('login').addEventListener('click', function analyzeClick(){window.clicked=true});
            document.addEventListener('submit',function delegatedSubmit(event){event.preventDefault()});
            """);
        File.WriteAllText(Path.Combine(pages,"site.css"), "#login{color:blue}");
        var png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j2XkAAAAASUVORK5CYII=");
        File.WriteAllBytes(Path.Combine(pages,"dot.png"),png);
        // Each URL is distinct even though the diagnostic manifest removes query values.
        File.AppendAllText(Path.Combine(pages,"index.html"),string.Concat(
            Enumerable.Range(0,505).Select(i=>$"<img src='dot.png?item={i}'>")));
        File.WriteAllText(Path.Combine(pages,"large.js"),"/*" + new string('x',9*1024*1024) + "*/ /* LARGE_END */");
        File.WriteAllText(Path.Combine(pages,"icon.svg"),"""<svg xmlns="http://www.w3.org/2000/svg"><title>VECTOR_FIXTURE</title></svg>""");
        using var form = new Form { ShowInTaskbar = false };
        using var view = new WebView2();
        form.Controls.Add(view);
        Exception? failure = null;
        form.Shown += async (_, _) => {
            try {
                var env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(temp.FullName,"browser"));
                await view.EnsureCoreWebView2Async(env);
                var core = view.CoreWebView2;
                core.SetVirtualHostNameToFolderMapping("export.test",pages,CoreWebView2HostResourceAccessKind.DenyCors);
                var ready = new TaskCompletionSource<bool>();
                core.NavigationCompleted += (_, e) => ready.TrySetResult(e.IsSuccess);
                core.Navigate("https://export.test/index.html?session=QUERY_PRIVATE");
                expect(await ready.Task.WaitAsync(TimeSpan.FromSeconds(25)), "fixture page loaded");
                await core.ExecuteScriptAsync("""
                    const sheet = new CSSStyleSheet(); sheet.replaceSync(".constructed-fixture { color: red; }");
                    document.adoptedStyleSheets = [sheet];
                    const shadow = document.body.appendChild(document.createElement('section')).attachShadow({mode:'open'});
                    const nested = new CSSStyleSheet(); nested.replaceSync(":host { --shadow-fixture: 1; }"); shadow.adoptedStyleSheets = [nested];
                    """);
                var target = Path.Combine(temp.FullName,"export.zip");
                var result = await PortalExport.SaveAsync(core,target,[],CancellationToken.None);
                using (var zip = ZipFile.OpenRead(target)) {
                    string Read(string path) {
                        using var r = new StreamReader(zip.GetEntry(path)!.Open());
                        return r.ReadToEnd();
                    }
                    var all = string.Join("\n",zip.Entries.Select(e=>Read(e.FullName)));
                    var controls = Read("pages/001/controls.json");
                    expect(controls.Contains("onclick") && controls.Contains("登录") && controls.Contains("manualSubmit"),"button label, inline click and javascript link indexed");
                    expect(Read("pages/002/controls.json").Contains("frame-submit"),"same-origin iframe captured");
                    var sources = zip.Entries.Where(e=>e.FullName.StartsWith("handlers/")).Select(e=>Read(e.FullName)).ToList();
                    expect(sources.Any(x=>x.Contains("analyzeClick")) && sources.Any(x=>x.Contains("delegatedSubmit")), "direct and delegated handler bodies exported");
                    var manifest = JsonDocument.Parse(Read("manifest.json")).RootElement;
                    var resources = manifest.GetProperty("resources").EnumerateArray().ToList();
                    expect(resources.Any(x=>x.GetProperty("file").GetString() is { } f && f.EndsWith(".css") && Read(f).Contains("#login")), "external stylesheet exported: " + manifest);
                    expect(resources.Any(x=>x.GetProperty("file").GetString() is { } f && f.EndsWith(".js") && Read(f).Contains("analyzeClick")), "external script exported: " + manifest);
                    string? Asset(string suffix) => resources.First(r=>r.GetProperty("url").GetString()!.EndsWith(suffix)).GetProperty("file").GetString();
                    using (var source = zip.GetEntry(Asset("dot.png")!)!.Open()) {
                        using var copy = new MemoryStream(); source.CopyTo(copy);
                        expect(png.SequenceEqual(copy.ToArray()), "PNG bytes match original");
                    }
                    expect(resources.Count(r=>r.GetProperty("url").GetString()!.EndsWith("dot.png") && r.GetProperty("file").ValueKind == JsonValueKind.String) == 506, "all 506 distinct PNG URLs archived");
                    expect(result.Unavailable > 0 && manifest.GetProperty("notes").EnumerateArray().Any(), "sandboxed frame identified as a coverage gap");
                    expect(Read("pages/001/page.html.txt").Contains("M0 0L8 8") && Read("pages/001/page.html.txt").Contains("#glyph"),"inline SVG geometry and local reference preserved");
                    expect(Read(Asset("icon.svg")!).Contains("VECTOR_FIXTURE"),"SVG resource archived");
                    expect(Read(Asset("large.js")!).EndsWith("/* LARGE_END */"),"script larger than 8 MiB exported through its final byte");
                    expect(zip.Entries.Where(e=>e.FullName.StartsWith("pages/") && e.FullName.EndsWith(".css")).Any(e=>Read(e.FullName).Contains("constructed-fixture")), "constructed document stylesheet exported");
                    expect(zip.Entries.Where(e=>e.FullName.EndsWith(".css")).Any(e=>Read(e.FullName).Contains("--shadow-fixture")), "constructed shadow stylesheet exported");
                    expect(manifest.GetProperty("savedResources").GetInt32() == resources.Count(r=>r.GetProperty("file").ValueKind == JsonValueKind.String), "manifest counts match saved entries");
                    foreach(var secret in new[]{"FIELD_PRIVATE","HIDDEN_PRIVATE","TEXT_PRIVATE","EDIT_PRIVATE","QUERY_PRIVATE","FRAME_PRIVATE"})
                        expect(!all.Contains(secret), "redacts " + secret);
                }
                var previous = File.ReadAllBytes(target);
                try {
                    await PortalExport.SaveAsync(core,target,[],new CancellationToken(true));
                    throw new Exception("Canceled export unexpectedly succeeded");
                } catch(OperationCanceledException) { }
                expect(previous.SequenceEqual(File.ReadAllBytes(target)), "canceled export preserves destination");
                expect(await core.ExecuteScriptAsync("window.clicked === undefined && document.querySelector('input').value==='FIELD_PRIVATE'") == "true","export leaves original page untouched");
            } catch (Exception ex) { failure = ex; }
            finally { form.Close(); }
        };
        Application.Run(form);
        view.Dispose();
        try { temp.Delete(true); } catch (IOException) { /* WebView2 may still be releasing its profile. */ }
        if (failure is not null) throw new InvalidOperationException("WebView2 export test failed",failure);
    }
}
