using System.Text.Json;

namespace CampusConnect;

internal sealed record CaptchaChallenge(string Ticket, string Image, int Length, bool AutoSubmit, bool NumericOnly = false);

internal static class CaptchaSupport
{
    internal const string ReadScript = "JSON.stringify(window.__campusCaptcha?.read() ?? null)";
    internal static string CommitScript(CaptchaChallenge challenge, string code) =>
        $"window.__campusCaptcha?.commit({JsonSerializer.Serialize(challenge.Ticket)}, {JsonSerializer.Serialize(code)}) ?? 'captcha-stale'";

    internal static byte[] Decode(string image) => PortalCaptchaResponse.DecodePng(image);
    internal static async Task<string> RecognizeAsync(byte[] bytes)
        => (await CaptchaOcr.RecognizeAsync(bytes)).Digits;
    internal static Task<string?> PromptAsync(IWin32Window owner, CaptchaChallenge challenge)
    {
        var bytes = Decode(challenge.Image);
        using var imageStream = new MemoryStream(bytes);
        using var image = System.Drawing.Image.FromStream(imageStream);
        using var dialog = new Form {
            Text = "校园网验证码", ClientSize = new Size(440, 350), StartPosition = FormStartPosition.CenterParent,
            FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false,
            ShowInTaskbar = false, AutoScaleMode = AutoScaleMode.Dpi
        };
        var fontFamily = (SystemFonts.MessageBoxFont ?? SystemFonts.DefaultFont).FontFamily;
        var caption = new Label {Left=24, Top=12, Width=390, Height=22, Text=challenge.NumericOnly ? "数字识别参考（请核对原图）" : "手动输入（支持英文字母和数字）"};
        var reference = new TextBox {Left=24, Top=38, Width=282, ReadOnly=true, ShortcutsEnabled=true,
            PlaceholderText=challenge.NumericOnly ? "正在识别…" : "请根据下方原图输入", AccessibleName="验证码参考", TabIndex=1,
            Font=new Font(fontFamily, challenge.NumericOnly ? 21 : 15, FontStyle.Bold), ForeColor=Color.FromArgb(20, 91, 200)};
        var copy = new Button {Left=320, Top=38, Width=95, Height=40, Text="复制参考", Enabled=false, TabIndex=2};
        var picture = new PictureBox {Left=24, Top=94, Width=390, Height=75, SizeMode=PictureBoxSizeMode.Zoom, Image=image};
        var input = new TextBox {Left=24, Top=190, Width=390, Font=new Font(fontFamily, 20), TabIndex=0,
            MaxLength=challenge.Length > 0 ? challenge.Length : 12, PlaceholderText="输入或粘贴英文字母和数字", AccessibleName="手动验证码", ShortcutsEnabled=true, CharacterCasing=CharacterCasing.Normal};
        var defaultHint = challenge.AutoSubmit && challenge.Length > 0
            ? $"请核对图片。输入 {challenge.Length} 位验证码后自动登录，也可按回车确认。" : "请根据原图输入，保留大小写；输入完成后按回车确认。";
        var hint = new Label {Left=24, Top=238, Width=390, Height=44, Text=defaultHint};
        var ok = new Button {Text=challenge.AutoSubmit ? "登录" : "填入网页", Left=320, Top=300, Width=95, DialogResult=DialogResult.OK, TabIndex=3};
        var cancel = new Button {Text="取消", Left=215, Top=300, Width=95, DialogResult=DialogResult.Cancel, TabIndex=4};
        copy.Click += (_, _) => {
            if (reference.Text.Length == 0) return;
            try {
                Clipboard.SetText(reference.Text);
                copy.Text = "已复制";
                hint.Text = "已复制参考，在下方按 Ctrl+V 粘贴；请核对原图后确认。";
                input.Focus();
            } catch (System.Runtime.InteropServices.ExternalException) {
                hint.Text = "复制未成功，请选中上方参考按 Ctrl+C。";
                reference.Focus(); reference.SelectAll();
            }
        };
        dialog.Controls.AddRange([caption, reference, copy, picture, input, hint, ok, cancel]);
        dialog.AcceptButton = ok; dialog.CancelButton = cancel;
        var expectedLength = challenge.Length;
        ok.Enabled = false;
        using var completion = new System.Windows.Forms.Timer {Interval=450};
        using var recognitionStop = new CancellationTokenSource(TimeSpan.FromSeconds(12));
        var recognitionToken = recognitionStop.Token;
        dialog.FormClosed += (_, _) => recognitionStop.Cancel();
        input.KeyPress += (_, e) => { if (!char.IsControl(e.KeyChar) && !CaptchaInput.Allows(e.KeyChar, challenge.NumericOnly)) e.Handled=true; };
        input.TextChanged += (_, _) => {
            completion.Stop();
            ok.Enabled = CaptchaInput.IsValid(input.Text, expectedLength, challenge.NumericOnly);
            if (ok.Enabled && challenge.AutoSubmit && expectedLength > 0) completion.Start();
        };
        completion.Tick += (_, _) => { completion.Stop(); dialog.DialogResult=DialogResult.OK; dialog.Close(); };
        dialog.Shown += async (_, _) => {
            input.Focus();
            if (!challenge.NumericOnly) return;
            CaptchaRecognition result;
            try { result = await Task.Run(() => CaptchaOcr.RecognizeAsync(bytes, challenge.Length, recognitionToken)).WaitAsync(recognitionToken); }
            catch (OperationCanceledException) { result = new("", "识别超时", "识别用时较长，请先根据原图手动输入。"); }
            catch { result = new("", "识别暂不可用", "当前图片处理失败，请先根据原图手动输入。"); }
            if (dialog.IsDisposed || !dialog.Visible) return;
            var recognized = result.Digits;
            reference.Text = recognized;
            reference.PlaceholderText = result.Placeholder;
            copy.Enabled = recognized.Length > 0;
            if (result.Engine.Length > 0) caption.Text = result.Engine + "（请核对原图）";
            if (recognized.Length == 0) hint.Text = result.Hint;
        };
        if (dialog.ShowDialog(owner) != DialogResult.OK) return Task.FromResult<string?>(null);
        var code = input.Text.Trim();
        return Task.FromResult(CaptchaInput.IsValid(code, expectedLength, challenge.NumericOnly) ? code : null);
    }
}
