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
        using var owner = new Form();
        owner.Show();
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
        Console.WriteLine($"PASS: {checks} native CAPTCHA dialog checks (WM_CHAR typing, clipboard paste, validation, case, unknown length).");
    }
}

namespace CampusConnect {
    // Response filtering belongs to the core tests; only its origin helper is stubbed here.
    internal static class CampusProfile {
        internal static string Origin(string value) => new Uri(value).GetLeftPart(UriPartial.Authority);
    }
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
