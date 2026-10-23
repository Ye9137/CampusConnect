using System.Runtime.InteropServices;
using CampusConnect;

internal static class Program
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessage(IntPtr handle, uint message, IntPtr wParam, IntPtr lParam);
    private static int checks;
    private static void Expect(bool value, string description) {
        checks++; if (!value) throw new Exception(description);
    }
    [STAThread]
    private static void Main() {
        ApplicationConfiguration.Initialize();
        var directory = Path.Combine(Path.GetTempPath(), "CampusConnect-mode-test-" + Guid.NewGuid().ToString("N"));
        try {
            var fresh = LocalStore.LoadFrom(directory);
            Expect(fresh.Profile.ConnectionMode == "wifi" && fresh.Profile.Ssid == "" && fresh.Password == "", "fresh storage has no fabricated school target");
            Expect(new[] { fresh.Profile.PortalUrl, fresh.Profile.Username, fresh.Profile.ServiceOption, fresh.Profile.EthernetName, fresh.Profile.BroadbandName, fresh.Profile.AuthenticationClient }.All(string.IsNullOrEmpty), "fresh storage leaves all editable fields blank");
            var wifi = new CampusProfile { Ssid = "Custom-Campus", Username = "fixture-wifi-user", PortalUrl = "https://wifi.test/login", ServiceOption = "无线服务" };
            var wired = new CampusProfile { ConnectionMode = "wired", Ssid = "", Username = "fixture-wired-user", PortalUrl = "https://wired.test/login", EthernetName = "Ethernet fixture" };
            LocalStore.SaveTo(directory, wifi, "fixture-wifi-secret");
            // Reproduce a pre-upgrade file containing only the active profile and DPAPI password.
            var file = Path.Combine(directory, "configuration.json");
            var legacy = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(file))!;
            legacy.AsObject().Remove("Profiles"); File.WriteAllText(file, legacy.ToJsonString());
            LocalStore.SaveTo(directory, wired, "fixture-wired-secret");
            var entries = LocalStore.LoadProfilesFrom(directory);
            Expect(entries["wifi"].Profile == wifi && entries["wifi"].Password == "fixture-wifi-secret", "real DPAPI migration retains Wi-Fi profile and password");
            Expect(entries["wired"].Profile == wired && entries["wired"].Password == "fixture-wired-secret", "real storage restores distinct wired settings");
            Expect(LocalStore.LoadFrom(directory).Profile == wired, "restart uses last saved active mode");
            var raw = File.ReadAllText(file);
            Expect(!raw.Contains("fixture-wifi-secret") && !raw.Contains("fixture-wired-secret"), "both secrets remain protected on disk");
            LocalStore.SaveTo(directory, wifi with { Automatic = false }, "fixture-wifi-updated");
            Expect(LocalStore.LoadProfilesFrom(directory)["wired"].Password == "fixture-wired-secret", "saving or pausing Wi-Fi retains wired secret");
            Expect(LocalStore.LoadFrom(directory).Profile.Ssid == "Custom-Campus", "restart restores custom SSID instead of HNPI default");
        } finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
        using var owner = new Form();
        owner.Show();
        using (var guide = new PortalProblemDialog(PortalProblem.From("service-control-missing")!)) {
            IEnumerable<Control> Descendants(Control root) => root.Controls.Cast<Control>().SelectMany(child => new[] { child }.Concat(Descendants(child)));
            Exception? failure = null;
            using var guideTimer = new System.Windows.Forms.Timer { Interval = 100 };
            guideTimer.Tick += (_, _) => {
                guideTimer.Stop();
                try {
                    var controls = Descendants(guide).ToArray();
                    var previous = controls.OfType<Button>().Single(b => b.Text == "上一步");
                    var next = controls.OfType<Button>().Single(b => b.Text == "下一步");
                    Expect(!previous.Enabled, "native guide begins at first step");
                    next.PerformClick();
                    Expect(previous.Enabled && controls.OfType<Label>().Any(l => l.Text.Contains("第 2 / 4 步")), "native guide moves forward");
                    previous.PerformClick();
                    Expect(!previous.Enabled && controls.OfType<Label>().Any(l => l.Text.Contains("第 1 / 4 步")), "native guide moves backward without losing reason");
                    controls.OfType<Button>().Single(b => b.Text == "打开对应设置").PerformClick();
                } catch (Exception ex) { failure = ex; guide.Close(); }
            };
            guideTimer.Start();
            var result = guide.ShowDialog(owner);
            if (failure is not null) throw failure;
            Expect(result == DialogResult.OK, "native guide returns explicit settings action");
        }
        using var bitmap = new Bitmap(120, 40);
        using var buffer = new MemoryStream();
        bitmap.Save(buffer, System.Drawing.Imaging.ImageFormat.Png);
        var image = "data:image/png;base64," + Convert.ToBase64String(buffer.ToArray());
        foreach (var (length, paste) in new[] { (4, false), (4, true), (0, true) }) {
            Exception? failure = null;
            using var timer = new System.Windows.Forms.Timer { Interval = 80 };
            timer.Tick += (_, _) => {
                var dialog = Application.OpenForms.Cast<Form>().FirstOrDefault(f => f.Text == "校园网验证码");
                if (dialog is null) return;
                timer.Stop();
                try {
                    var input = dialog.Controls.OfType<TextBox>().Single(t => t.AccessibleName == "手动验证码");
                    var ok = dialog.Controls.OfType<Button>().Single(b => b.Text == "登录");
                    Expect(!ok.Enabled, "empty CAPTCHA disables login");
                    input.Focus();
                    Clipboard.SetText("a-7"); input.Paste();
                    Expect(!ok.Enabled, "invalid pasted characters disable login");
                    input.Clear();
                    if (paste) { Clipboard.SetText("aB7Z"); input.Paste(); }
                    else {
                        SendMessage(input.Handle, 0x102, (IntPtr)'+', IntPtr.Zero);
                        Expect(input.Text == "", "invalid typed characters blocked");
                        foreach (var character in "aB7Z") SendMessage(input.Handle, 0x102, (IntPtr)character, IntPtr.Zero);
                    }
                    Expect(input.Text == "aB7Z", "typing/paste preserves mixed case");
                    Expect(ok.Enabled, "alphanumeric CAPTCHA enables login");
                    ok.PerformClick();
                } catch (Exception ex) { failure = ex; dialog.Close(); }
            };
            timer.Start();
            var value = CaptchaSupport.PromptAsync(owner, new("fixture-ticket", image, length, true)).GetAwaiter().GetResult();
            if (failure is not null) throw failure;
            Expect(value == "aB7Z", "native dialog returns complete manual code");
        }
        owner.Close();
        Expect(CaptchaOcr.Calls == 0, "unspecified format never invokes digit recognizer");
        Console.WriteLine($"PASS: {checks} native CAPTCHA and protected configuration checks (typing, paste, case, legacy migration, separate profiles, DPAPI).");
    }
}

namespace CampusConnect {
    // The dialog test exercises actual UI and manual entry without running a model.
    internal sealed record CaptchaRecognition(string Digits, string Placeholder, string Hint, string Engine = "");
    internal static class CaptchaOcr {
        internal static int Calls;
        internal static Task<CaptchaRecognition> RecognizeAsync(byte[] bytes, int expectedLength = 0, CancellationToken cancellationToken = default) {
            Calls++;
            return Task.FromResult(new CaptchaRecognition("", "", ""));
        }
    }
}
