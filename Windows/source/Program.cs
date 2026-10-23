namespace CampusConnect;

internal static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        var startInTray = args.Contains("--startup", StringComparer.OrdinalIgnoreCase);
        using var instance = new Mutex(true, "Local\\CampusConnect.Windows", out var created);
        if (!created) { if (!startInTray) MessageBox.Show("校园Wi-Fi小助手已在运行，请从系统托盘打开。", "校园Wi-Fi小助手"); return; }
        // The .NET bundle extracts native libraries into its private cache.
        // Tell WebView2 where its loader is instead of relying on Assembly.Location.
        var directories = (AppContext.GetData("NATIVE_DLL_SEARCH_DIRECTORIES") as string ?? "")
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries).Prepend(AppContext.BaseDirectory);
        var loaderDirectory = directories.FirstOrDefault(dir => File.Exists(Path.Combine(dir, "WebView2Loader.dll")));
        if (loaderDirectory is not null)
            Microsoft.Web.WebView2.Core.CoreWebView2Environment.SetLoaderDllFolderPath(loaderDirectory);
        ApplicationConfiguration.Initialize();
        var verificationIndex = Array.IndexOf(args, "--verify-ui");
        var verificationPath = verificationIndex >= 0 && verificationIndex + 1 < args.Length ? args[verificationIndex + 1] : null;
        Application.Run(new MainForm(verificationPath, startInTray));
    }
}
