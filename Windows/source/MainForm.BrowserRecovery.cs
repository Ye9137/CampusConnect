using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace CampusConnect;

internal sealed partial class MainForm
{
    // Drafts exist only in this process; never write recovery passwords to disk or logs.
    private JsonElement? shellSnapshot;
    private TaskCompletionSource<bool>? shellReady;
    private bool configurationLoaded, recoveringShell, recoveryFailed, rebuildBrowserRequested, wasBackgrounded;
    private DateTimeOffset? deactivatedAt;
    private readonly Panel recoveryPanel = new() { Dock = DockStyle.Fill, BackColor = Color.White, Visible = false };
    private readonly Label recoveryLabel = new() { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter };
    private readonly Button recoveryButton = new() { Dock = DockStyle.Bottom, Height = 48, Text = "重新加载界面", Visible = false };

    private void InitializeBrowserRecovery()
    {
        recoveryPanel.Controls.Add(recoveryLabel);
        recoveryPanel.Controls.Add(recoveryButton);
        Controls.Add(recoveryPanel);
        recoveryButton.Click += (_, _) => RequestShellRecovery(userRequested: true);
        VisibleChanged += (_, _) => OnWindowVisibilityChanged();
        Resize += (_, _) => OnWindowVisibilityChanged();
        Deactivate += (_, _) => deactivatedAt = DateTimeOffset.UtcNow;
        Activated += (_, _) => {
            var last = deactivatedAt;
            deactivatedAt = null;
            if (last is { } time && DateTimeOffset.UtcNow - time >= TimeSpan.FromMinutes(1))
                RequestShellRecovery(userRequested: true);
        };
        portal.ProcessFailed += browserExited => {
            if (IsDisposed || Disposing || exiting) return;
            if (browserExited) {
                rebuildBrowserRequested = true;
                shellReady?.TrySetResult(false);
                RequestShellRecovery();
            } else {
                var failedView = portal.View;
                BeginInvoke((Action)(() => {
                    if (IsDisposed || Disposing || failedView != portal.View) return;
                    ResetPortalView();
                    PushState();
                }));
            }
        };
    }

    private void OnWindowVisibilityChanged()
    {
        if (!Visible || WindowState == FormWindowState.Minimized) { wasBackgrounded = true; return; }
        if (!wasBackgrounded) return;
        wasBackgrounded = false;
        RequestShellRecovery(userRequested: true);
    }

    private void OnShellProcessFailed(CoreWebView2ProcessFailedKind kind)
    {
        // GPU/utility/other-frame failures are handled by WebView2 itself.
        if (kind is not (CoreWebView2ProcessFailedKind.BrowserProcessExited or
            CoreWebView2ProcessFailedKind.RenderProcessExited or CoreWebView2ProcessFailedKind.RenderProcessUnresponsive)) return;
        if (kind == CoreWebView2ProcessFailedKind.BrowserProcessExited) rebuildBrowserRequested = true;
        shellReady?.TrySetResult(false);
        RequestShellRecovery();
    }

    private void RequestShellRecovery(bool userRequested = false)
    {
        if (IsDisposed || Disposing || exiting || !configurationLoaded || recoveringShell) return;
        if (!Visible || WindowState == FormWindowState.Minimized) { wasBackgrounded = true; return; }
        if (recoveryFailed && !userRequested) return;
        // Set this before any await: Show/Resize/Activate and tray double-clicks can overlap.
        recoveringShell = true;
        recoveryFailed = false;
        BeginInvoke((Action)(async () => await RecoverShellAsync()));
    }

    private async Task RecoverShellAsync()
    {
        try {
            if (IsDisposed || Disposing || exiting) return;
            recoveryLabel.Text = "正在恢复界面…";
            recoveryButton.Visible = false;
            recoveryPanel.Visible = true;
            recoveryPanel.BringToFront();
            if (uiReady && !rebuildBrowserRequested) {
                try {
                    shell.CoreWebView2?.Resume();
                    var json = await shell.CoreWebView2!.ExecuteScriptAsync("window.campus?.snapshot()")
                        .WaitAsync(TimeSpan.FromSeconds(2));
                    using var document = JsonDocument.Parse(json);
                    if (document.RootElement.ValueKind == JsonValueKind.Object) shellSnapshot = document.RootElement.Clone();
                } catch { /* A hung renderer must not prevent restoring the window. Use its last checkpoint. */ }
            }
            for (var attempt = 0; attempt < 2; attempt++) {
                if (IsDisposed || Disposing || exiting) return;
                uiReady = false;
                pageTransitioning = false;
                portalBounds = Rectangle.Empty;
                UpdatePortalVisibility();
                var ready = shellReady = new(TaskCreationOptions.RunContinuationsAsynchronously);
                try {
                    if (attempt > 0 || rebuildBrowserRequested || shell.CoreWebView2 is null) {
                        if (rebuildBrowserRequested) {
                            rebuildBrowserRequested = false;
                            ResetPortalView();
                            browserEnvironment = null;
                        }
                        var oldView = shell;
                        shell = new WebView2 { Dock = DockStyle.Fill };
                        Controls.Remove(oldView);
                        oldView.Dispose();
                        Controls.Add(shell);
                        recoveryPanel.BringToFront();
                        await InitializeShellAsync().WaitAsync(TimeSpan.FromSeconds(15));
                    } else {
                        shell.CoreWebView2.Resume();
                        shell.CoreWebView2.Reload();
                    }
                    if (!await ready.Task.WaitAsync(TimeSpan.FromSeconds(8))) continue;
                    if (IsDisposed || Disposing || exiting) return;
                    // Force a fresh native paint as well as reloading the HTML compositor.
                    shell.Invalidate(true);
                    shell.Update();
                    recoveryPanel.Visible = false;
                    UpdatePortalVisibility();
                    return;
                } catch (Exception) when (!IsDisposed && !Disposing && !exiting) {
                    // One fresh controller attempt, then a native retry UI instead of a blank window.
                }
            }
            recoveryFailed = true;
            uiReady = false;
            UpdatePortalVisibility();
            recoveryLabel.Text = "界面暂时未能恢复。后台连接任务已保留，请点击下方按钮重试。";
            recoveryButton.Visible = true;
            recoveryPanel.BringToFront();
        } catch (Exception) {
            // Closing a form disposes its native browser while awaits are still completing.
            if (!IsDisposed && !Disposing && !exiting) {
                recoveryFailed = true;
                recoveryLabel.Text = "界面恢复失败，请点击下方按钮重试。";
                recoveryButton.Visible = true;
            }
        } finally {
            shellReady = null;
            recoveringShell = false;
        }
    }

    private void ResetPortalView()
    {
        var oldView = portal.View;
        Controls.Remove(oldView);
        portal.ResetBrowser();
        portal.View.Dock = DockStyle.None;
        portal.View.Visible = false;
        Controls.Add(portal.View);
        portalStatus = saved.Automatic && saved.AutoSubmit && !portal.RequiresInteraction
            ? "认证页面已恢复，将在检查联网状态后继续自动重连。"
            : "认证页面已恢复，请确认验证码或学校提示后点击打开认证页继续。";
        recoveryPanel.BringToFront();
    }
}
