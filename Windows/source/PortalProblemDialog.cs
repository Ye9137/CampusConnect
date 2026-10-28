namespace CampusConnect;

internal sealed class PortalProblemDialog : Form
{
    private readonly PortalProblem problem;
    private readonly Label progress = new() { AutoSize = true, Margin = new(0, 12, 0, 12) };
    private readonly Label instruction = new() { Dock = DockStyle.Fill, AutoSize = false, Padding = new(0, 8, 0, 8) };
    private readonly Button previous = new() { Text = "上一步", AutoSize = true };
    private readonly Button next = new() { Text = "下一步", AutoSize = true };
    private int step;

    internal PortalProblemDialog(PortalProblem problem, Func<bool>? isCurrent = null)
    {
        this.problem = problem;
        Shown += (_, _) => { if (isCurrent?.Invoke() == false) Dismiss(); };
        Text = "校园Wi-Fi小助手 · 认证处理向导";
        StartPosition = FormStartPosition.CenterParent;
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new(600, 390);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; MinimizeBox = false; ShowInTaskbar = false;
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new(24), ColumnCount = 1, RowCount = 5 };
        for (var i = 0; i < 5; i++) layout.RowStyles.Add(new(i == 3 ? SizeType.Percent : SizeType.AutoSize, i == 3 ? 100 : 0));
        layout.Controls.Add(new Label { Text = problem.Title, AutoSize = true, MaximumSize = new(540, 0),
            Font = new(Font.FontFamily, 13, FontStyle.Bold), Margin = new(0, 0, 0, 12) }, 0, 0);
        layout.Controls.Add(new Label { Text = "原因：" + problem.Summary, AutoSize = true, MaximumSize = new(540, 0), Margin = new(0) }, 0, 1);
        layout.Controls.Add(progress, 0, 2);
        layout.Controls.Add(instruction, 0, 3);
        var buttons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, WrapContents = true, Margin = new(0, 12, 0, 0) };
        var settings = new Button { Text = "打开对应设置", AutoSize = true };
        var cancel = new Button { Text = "稍后处理", AutoSize = true, DialogResult = DialogResult.Cancel };
        previous.Click += (_, _) => { step = Math.Max(0, step - 1); RefreshStep(); };
        next.Click += (_, _) => {
            if (step < problem.Steps.Count - 1) { step++; RefreshStep(); }
            else { DialogResult = DialogResult.OK; Close(); }
        };
        settings.Click += (_, _) => { DialogResult = DialogResult.OK; Close(); };
        buttons.Controls.AddRange([previous, next, settings, cancel]);
        layout.Controls.Add(buttons, 0, 4);
        Controls.Add(layout);
        CancelButton = cancel;
        AcceptButton = next;
        RefreshStep();
    }
    internal void Dismiss() { DialogResult = DialogResult.Cancel; Close(); }
    private void RefreshStep()
    {
        progress.Text = $"处理向导 · 第 {step + 1} / {problem.Steps.Count} 步";
        instruction.Text = problem.Steps[step];
        previous.Enabled = step > 0;
        next.Text = step == problem.Steps.Count - 1 ? "打开设置" : "下一步";
    }
}
