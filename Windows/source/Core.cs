using System.Text;
using System.Text.Json;

namespace CampusConnect;

internal sealed record PortalProblem(string Code, string Title, string Summary, string Advice)
{
    public string? SettingsField => Code is "missing-service" or "service-control-missing" or "service-option-missing" or "service-selection-failed" or "service-required" ? "serviceOption" :
        Code is "missing-fields" or "missing-credentials" ? "username" : Code is "load-failed" or "wrong-origin" or "waiting-ready" ? "portalUrl" : null;
    public IReadOnlyList<string> Steps => SettingsField == "serviceOption" ? [
        "查看学校认证网页，确认是否有运营商 / 服务选择框。页面尚未加载完成时，先等待加载。",
        Code == "service-control-missing" ? "如果网页没有需要选择的选项，请打开校园网设置，清空“运营商 / 服务选项”，保持空白。未识别到控件也可能是页面结构暂不支持，请先人工确认。" : "如果网页有选项，展开后核对完整名称。请填写网页显示的完整选项名称，不要填写简称、猜测名称或网页上不存在的内容；网页没有此选项时保持空白。",
        "点击“打开对应设置”定位到运营商输入框，按网页实际情况清空或修改。这里不会自动删除你的填写内容。",
        "点击“保存设置”，再返回“上网认证”点击“立即认证”。若仍无法匹配，可先在学校网页手动选择并登录，再通过左下角入口反馈。"
    ] : [Advice, "打开对应设置，核对认证地址以及账号输入位置。未识别到输入框不代表账号或密码错误；若网页是二维码模式，请先切换到账号密码登录。", "保存修改后返回上网认证，点击“立即认证”重试；也可在学校网页中手动登录。"];
    public static bool IsAuthenticationRejected(string? status) => status == "authentication-rejected" || status?.StartsWith("authentication-rejected:", StringComparison.Ordinal) == true;
    public static string AuthenticationMessage(string? status)
    {
        const string prefix = "authentication-rejected:";
        var code = status?.StartsWith(prefix, StringComparison.Ordinal) == true ? status[prefix.Length..] : "";
        return System.Text.RegularExpressions.Regex.IsMatch(code, @"\AE[0-9]{4,8}\z")
            ? $"学校返回 {code}，已暂停自动重试。请查看学校网页提示后处理；此代码尚无已核实的含义。"
            : "学校返回登录失败，请查看网页提示并检查账号、密码和服务选项。";
    }
    public static string ServiceCode(string? reason) => reason is "service-control-missing" or "service-option-missing" or "service-selection-failed" ? reason : "missing-service";
    public static PortalProblem? From(string code) => code switch {
        "service-control-missing" => new(code, "网页未找到运营商 / 服务选项", "设置中填写了运营商 / 服务选项，但当前认证网页未识别到对应的选择控件，已暂停自动登录。", "网页没有需要选择的选项时，请清空设置中的运营商 / 服务选项；网页确有选项时，先等待加载或手动选择。"),
        "service-option-missing" => new(code, "网页未匹配到填写的服务名称", "当前网页的可识别选项中，未找到与你填写内容完全一致且可选择的服务名称，已暂停自动登录。", "核对网页上的完整名称以及选项是否可用；请勿填写简称或不存在的名称。网页没有运营商选项时保持空白。"),
        "service-selection-failed" => new(code, "网页未确认服务选中", "找到相关服务项，但无法唯一确定选项，或学校网页没有确认选中，已暂停自动登录。", "请在学校网页中手动选择并确认服务项，再检查保存的完整名称；不要反复自动提交。"),
        "load-failed" => new(code, "认证页面无法打开", "认证页面加载失败，已暂停自动重试。", "先确认已连接校园 Wi-Fi 或网线，再核对认证地址。可在系统浏览器中打开学校登录页；地址变化时，在确认属于学校后更新认证地址。"),
        "wrong-origin" => new(code, "请核对认证地址", "当前页面与允许的认证地址不匹配，已停止自动填写。", "确认当前页面属于学校后，使用“使用当前页面地址”更新认证地址，再保存并重新认证。不要将外站地址保存为认证入口。"),
        "missing-service" => new(code, "请修改运营商 / 服务选项", "未找到或未能选中设置中填写的服务选项，无法自动填写信息。", "如果认证网页没有需要选择的选项，请不要填写，否则会导致无法自动填写信息。请清空设置中的“运营商 / 服务选项”；有选项时填写网页显示的完整名称，保存后重新认证。"),
        "service-required" => new(code, "请选择运营商或服务", "认证网页要求选择运营商或服务，当前尚未选中。", "在“运营商 / 服务选项”中填写网页显示的完整名称，例如中国移动，保存后重新认证；也可在学校网页中手动选择后登录。"),
        "authentication-rejected" => new(code, "学校未接受本次登录", "学校页面返回登录失败，已暂停自动重试。", "先查看学校网页的具体提示，再核对上网账号、密码、运营商和验证码。修改后保存设置并重新认证；账号欠费、停用或并发限制请联系学校处理。"),
        "missing-credentials" => new(code, "请补充上网账号和密码", "尚未保存完整的上网认证信息。", "在校园网设置中填写上网账号和上网密码，保存后重新认证。Wi-Fi 密码与上网认证密码可能不同。"),
        "missing-submit" => new(code, "未识别登录按钮", "账号密码已填写，但未找到可用的登录按钮。", "请先在学校网页中手动点击登录。若仍无法登录，请通过左下角反馈入口提供学校名称和失败过程。"),
        "agreement-required" => new(code, "请确认上网协议", "网页必选勾选项或协议尚未确认。", "在认证网页阅读并勾选必需的上网协议或使用承诺，再手动登录。不要勾选与上网无关的选项。"),
        "waiting-ready" => new(code, "学校页面尚未就绪", "等待后仍未取得学校认证所需的页面参数。", "等待学校网页加载完成，再点击立即认证；也可手动登录。若持续出现，请核对认证地址并反馈学校名称和失败过程。"),
        "submission-unconfirmed" => new(code, "尚未确认登录提交", "学校页面未确认本次登录已提交。", "检查网页是否要求验证码、服务选项或协议，补充后手动登录；不要反复提交相同信息。"),
        "missing-fields" => new(code, "未识别认证表单", "等待后仍未找到可自动填写的登录表单。", "确认认证地址确实打开学校登录页。若网页没有运营商选项，请清空“运营商 / 服务选项”；也可在网页中手动登录并通过左下角反馈入口反馈。"),
        "script-failed" => new(code, "自动填写未完成", "学校页面脚本未能完成自动填写，已暂停自动重试。", "等待页面加载完成后点击立即认证，或在网页中手动登录。若仍失败，请核对认证地址和服务选项，并反馈学校名称和失败过程。"),
        _ => null
    };
}

internal sealed class PortalProblemGate
{
    public PortalProblem? Current { get; private set; }
    public PortalProblem? Report(string code, string? serviceOption = null)
    {
        if (Current is not null) return null;
        var problem = PortalProblem.From(code);
        if (problem?.SettingsField == "serviceOption" && !string.IsNullOrWhiteSpace(serviceOption)) {
            var safe = string.Concat(serviceOption.Where(c => !char.IsControl(c))).Trim();
            problem = problem with { Summary = problem.Summary + "\n填写的服务选项：" + safe[..Math.Min(safe.Length, 80)] };
        }
        return Current = problem;
    }
    public void Reset() => Current = null;
}

public sealed record CampusProfile
{
    public string Ssid { get; init; } = "";
    public string? ConnectionMode { get; init; }
    [System.Text.Json.Serialization.JsonIgnore]
    public bool IsWired => ConnectionMode == "wired" || (ConnectionMode is null && string.IsNullOrWhiteSpace(Ssid));
    public bool MatchesNetwork(string? currentSsid, bool wiredAvailable)
        => IsWired ? wiredAvailable : currentSsid == Ssid;
    public string WiredAuth { get; init; } = "web";
    public string EthernetName { get; init; } = "";
    public string BroadbandName { get; init; } = "";
    public string AuthenticationClient { get; init; } = "";
    [System.Text.Json.Serialization.JsonIgnore]
    public bool UsesSystemAuthentication => IsWired && WiredAuth != "web";
    [System.Text.Json.Serialization.JsonIgnore]
    public bool UsesWebPortal => PortalEnabled && !UsesSystemAuthentication;
    [System.Text.Json.Serialization.JsonIgnore]
    public string ConnectionLabel => !IsWired ? "Wi-Fi" : WiredAuth switch {
        "pppoe" => "有线 · PPPoE 拨号", "dot1x" => "有线 · 802.1X", "client" => "有线 · 专用客户端", _ => "有线 · 网页认证"
    };
    public bool UseSavedWifiProfile { get; init; }
    public bool PortalEnabled { get; init; } = true;
    public string PortalUrl { get; init; } = "";
    public string Username { get; init; } = "";
    public string ServiceOption { get; init; } = "";
    public bool AutoSubmit { get; init; } = true;
    public bool Automatic { get; init; }

    public static string? Origin(string address)
    {
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) ||
            (uri.Scheme != "http" && uri.Scheme != "https") ||
            string.IsNullOrEmpty(uri.Host) || !string.IsNullOrEmpty(uri.UserInfo)) return null;
        return uri.GetLeftPart(UriPartial.Authority).ToLowerInvariant();
    }

    public void Validate()
    {
        if (ConnectionMode is not (null or "wired" or "wifi")) throw new InvalidOperationException("请选择有线或 Wi-Fi 网络。 ");
        if (!IsWired && string.IsNullOrWhiteSpace(Ssid)) throw new InvalidOperationException("请填写校园 Wi-Fi 名称。 ");
        if (!IsWired && Encoding.UTF8.GetByteCount(Ssid) > 32)
            throw new InvalidOperationException("Wi-Fi 名称最多为 32 字节；有线模式请留空。");
        if (WiredAuth is not ("web" or "pppoe" or "dot1x" or "client"))
            throw new InvalidOperationException("请选择有效的有线认证方式。");
        if (IsWired && WiredAuth == "pppoe" && (string.IsNullOrWhiteSpace(BroadbandName) || BroadbandName.Any(char.IsControl)))
            throw new InvalidOperationException("请填写或选择 Windows 中已配置的 PPPoE 宽带连接名称。");
        if (IsWired && WiredAuth == "client" && (string.IsNullOrWhiteSpace(AuthenticationClient) || !AuthenticationClient.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("请先选择学校认证客户端的 EXE 文件。");
        if (EthernetName.Any(char.IsControl)) throw new InvalidOperationException("以太网接口名称无效。");
        if (UsesWebPortal && Origin(PortalUrl) is null)
            throw new InvalidOperationException("请输入 http:// 或 https:// 开头的认证地址，不能在地址中包含账号密码。");
    }
}

public enum AutomaticNetworkWork { Stopped, OtherNetwork, FindTarget, CheckInternet }

public sealed class AutoPolicy
{
    public static AutomaticNetworkWork BackgroundWork(bool enabled, bool wired, string target, string? current)
        => !enabled || (!wired && string.IsNullOrWhiteSpace(target)) ? AutomaticNetworkWork.Stopped
            : wired || current == target ? AutomaticNetworkWork.CheckInternet
            : !string.IsNullOrEmpty(current) ? AutomaticNetworkWork.OtherNetwork : AutomaticNetworkWork.FindTarget;
    public const int NetworkCheckIntervalMilliseconds = 5000;
    public static readonly TimeSpan WifiScanInterval = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan InternetCheckInterval = TimeSpan.FromSeconds(5);
    public DateTimeOffset LastAttempt { get; private set; } = DateTimeOffset.MinValue;
    public bool ShouldJoin(bool enabled, string target, string? current, IEnumerable<string> visible, bool busy, DateTimeOffset now)
        => enabled && target.Length > 0 && string.IsNullOrEmpty(current) && visible.Contains(target, StringComparer.Ordinal)
            && !busy && now - LastAttempt >= TimeSpan.FromMilliseconds(NetworkCheckIntervalMilliseconds);
    public bool ShouldPrepareWired(bool enabled, bool needed, bool busy, DateTimeOffset now)
        => enabled && needed && !busy && now - LastAttempt >= TimeSpan.FromSeconds(60);
    public void Begin(DateTimeOffset now) => LastAttempt = now;
    public void Reset() { LastAttempt = DateTimeOffset.MinValue; }
}

// Only transient failures may resume unattended login. School rejections and
// incomplete manual input retain their interaction hold.
public sealed record PortalRetryDecision(bool RequiresInteraction, DateTimeOffset? RetryNotBefore);
public static class PortalRetryPolicy
{
    public static readonly TimeSpan Cooldown = TimeSpan.FromSeconds(5);
    public static PortalRetryDecision AfterFailure(string code, bool automatic, bool autoSubmit, DateTimeOffset now)
    {
        var retry = automatic && autoSubmit && (code is "load-temporary" or "authentication-timeout"
            or "result-check-interrupted" or "authentication-request-failed" or "waiting-ready" or "script-failed");
        return new(!retry, retry ? now + Cooldown : null);
    }
    public static bool IsTemporaryNavigationFailure(int httpStatus, string webError)
        => (httpStatus is 408 or 429 or >= 500 and <= 599) || (httpStatus < 400 && webError is
            "ServerUnreachable" or "Timeout" or "ConnectionAborted" or "ConnectionReset" or "Disconnected"
            or "CannotConnect" or "HostNameNotResolved" or "ErrorHttpInvalidServerResponse");
    public static string ProblemCode(string code) => code switch {
        "load-temporary" => "load-failed",
        "authentication-timeout" or "result-check-interrupted" or "authentication-request-failed" => "submission-unconfirmed",
        _ => code
    };
}

public enum InternetStatus { Online, Unavailable }
public sealed class PortalRecovery
{
    public int Failures { get; private set; }
    public int Attempts { get; private set; }
    public DateTimeOffset LastAttempt { get; private set; } = DateTimeOffset.MinValue;
    public InternetStatus State { get; private set; } = InternetStatus.Unavailable;
    public TimeSpan RetryDelay => TimeSpan.FromSeconds(5);
    public void Observe(InternetStatus result)
    {
        if (result == InternetStatus.Online) Reset();
        else Failures = Math.Min(2, Failures + 1);
        State = result;
    }
    public bool ShouldAuthenticate(bool enabled, bool portalEnabled, DateTimeOffset now,
        bool requiresInteraction = false, bool authenticating = false, DateTimeOffset? retryNotBefore = null)
        => enabled && portalEnabled && !requiresInteraction && !authenticating && (retryNotBefore is null || now >= retryNotBefore) && State != InternetStatus.Online && ((Attempts == 0 && Failures == 0) || Failures >= 1)
            && now - LastAttempt >= RetryDelay;
    public void Begin(DateTimeOffset now) { LastAttempt = now; Attempts = Math.Min(4, Attempts + 1); }
    public void Reset() { Failures = 0; Attempts = 0; LastAttempt = DateTimeOffset.MinValue; State = InternetStatus.Unavailable; }
}

public enum PortalNavigationDecision { Allowed, Redirected, Invalid }

// Track the current HTTP/HTTPS document without restricting redirects by host,
// scheme, count, elapsed time or previously visited URLs. Never persist this URL.
public sealed class PortalRedirectSession(string entryUrl)
{
    public string CurrentUrl { get; private set; } = entryUrl;

    public PortalNavigationDecision Navigate(string url)
    {
        var origin = CampusProfile.Origin(url);
        if (origin is null) return PortalNavigationDecision.Invalid;
        var sameOrigin = origin == CampusProfile.Origin(CurrentUrl);
        CurrentUrl = url;
        return sameOrigin ? PortalNavigationDecision.Allowed : PortalNavigationDecision.Redirected;
    }
}

public static class PortalScript
{
    public static CampusProfile AtCurrentPage(CampusProfile profile, string url)
    {
        if (CampusProfile.Origin(url) is null) throw new InvalidOperationException("当前页面不是有效的 HTTP/HTTPS 认证页。");
        return profile with { PortalUrl = url };
    }
    public static string ServiceFailure(CampusProfile profile) => InContext(profile, "window.__campusServiceFailure || 'missing-service'", "'missing-service'");
    public static string InContext(CampusProfile profile, string script, string fallback = "'missing-fields'")
    {
        using var stream = typeof(PortalScript).Assembly.GetManifestResourceStream("CampusConnect.PortalContext.js")
            ?? throw new InvalidOperationException("缺少框架页认证脚本。");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd()
            .Replace("/*CONTEXT_ORIGIN*/", JsonSerializer.Serialize(CampusProfile.Origin(profile.PortalUrl)), StringComparison.Ordinal)
            .Replace("/*CONTEXT_FALLBACK*/", fallback, StringComparison.Ordinal)
            .Replace("/*CONTEXT_PASSWORD_SELECTOR*/", JsonSerializer.Serialize(""), StringComparison.Ordinal)
            .Replace("/*CONTEXT_SCRIPT*/", script, StringComparison.Ordinal);
    }
    // Inspect loading pages without credentials before filling the landing form.
    public static string LoginFormProbe(CampusProfile profile)
    {
        var config = JsonSerializer.Serialize(new { origin = CampusProfile.Origin(profile.PortalUrl), passwordSelector = "" });
        var script = """
        (() => {
          const cfg = /*PROBE*/;
          if (location.origin !== cfg.origin || document.readyState === 'loading') return false;
          try {
            const inputs = document.querySelectorAll(cfg.passwordSelector || 'input[type="password"]');
            return [...inputs].some(input => input instanceof HTMLInputElement && !input.disabled && !input.readOnly &&
              (input.getClientRects().length > 0 ||
               (input.id === 'pwd' && (document.querySelector('#pwd_tip') || document.querySelector('#passwordIn_1'))?.getClientRects().length > 0) ||
               (input.id === 'password' && input.form?.id === 'login_form' &&
                input.form.querySelector('#user_name[name="username"]') && input.form.querySelector('#login_submit') &&
                input.form.querySelector('input#tx[type="text"]')?.getClientRects().length > 0)));
          } catch (_) { return true; } // Let the normal script report invalid selectors.
        })()
        """.Replace("/*PROBE*/", config, StringComparison.Ordinal);
        return InContext(profile, script, "false");
    }

    public static string BuildCaptchaImage(CampusProfile profile, string image)
    {
        var origin = CampusProfile.Origin(profile.PortalUrl) ?? throw new InvalidOperationException("认证地址无效。");
        var payload = JsonSerializer.Serialize(new { origin, image });
        var script = """
        (() => {
          const response = /*RESPONSE*/;
          if (location.origin !== response.origin) return 'wrong-origin';
          window.__campusCaptchaApiImage = response.image;
          return 'captcha-image-ready';
        })()
        """.Replace("/*RESPONSE*/", payload, StringComparison.Ordinal);
        return InContext(profile, script, "'wrong-origin'");
    }

    public static string BuildCaptchaProbe(CampusProfile profile)
    {
        var origin = CampusProfile.Origin(profile.PortalUrl) ?? throw new InvalidOperationException("认证地址无效。");
        var payload = JsonSerializer.Serialize(new { origin, userSelector="",
            passwordSelector="", submitSelector="", submit=profile.AutoSubmit });
        using var stream = typeof(PortalScript).Assembly.GetManifestResourceStream("CampusConnect.PortalCaptcha.js")
            ?? throw new InvalidOperationException("缺少验证码辅助脚本。");
        using var reader = new StreamReader(stream);
        var script = """
        (() => {
          const cfg = /*CONFIG*/;
          if (location.origin !== cfg.origin) return 'wrong-origin';
          const visible = e => e && !e.disabled && e.getClientRects().length > 0;
          const editable = e => e instanceof HTMLInputElement && !e.disabled && !e.readOnly;
          let user, pass, submit;
          try {
            pass = cfg.passwordSelector ? document.querySelector(cfg.passwordSelector) :
              [...document.querySelectorAll('input[type="password"]')].find(e => visible(e) && editable(e));
            const root = pass?.form || document;
            const users = [...root.querySelectorAll('input')].filter(e => editable(e) && visible(e) && /^(text|tel|email)$/.test(e.type));
            user = cfg.userSelector ? document.querySelector(cfg.userSelector) :
              users.find(e => /user|account|student|phone|login|用户名|学号|账号|手机/i.test([e.name,e.id,e.placeholder,e.autocomplete].join(' '))) || users[0];
            const zportalSubmit = pass?.form?.id === 'login_form' && pass.id === 'password' && user?.id === 'user_name'
              ? pass.form.querySelector('button#login_submit[type="button"]') : null;
            submit = cfg.submitSelector ? document.querySelector(cfg.submitSelector) : zportalSubmit ||
              (document.querySelector('#ps[name="psNum"]') && document.querySelector('#randomimage') &&
                /checkform\s*\(/.test(document.querySelector('#login_btn')?.getAttribute('onclick') || '') ? document.querySelector('#login_btn') : null) ||
              [...root.querySelectorAll('button,input[type="submit"],input[type="button"],a,[role="button"]')]
              .filter(e => e.getClientRects().length > 0).find(e => e.type === 'submit' ||
                /^(登录|登陆|认证|连接|login|signin|connect)$/i.test((e.innerText || e.value || '').replace(/\s+/g,'')));
          } catch (_) { return 'invalid-selector'; }
          if (!editable(user) || !editable(pass) || !visible(user) || !visible(pass) || !user.value || !pass.value) return 'missing-fields';
          /*CAPTCHA*/
          return 'captcha-not-found';
        })()
        """.Replace("/*CONFIG*/", payload, StringComparison.Ordinal).Replace("  /*CAPTCHA*/", reader.ReadToEnd().TrimEnd(), StringComparison.Ordinal);
        return InContext(profile, script, "'wrong-origin'");
    }

    public static string Build(CampusProfile profile, string password, bool statusOnly = false)
    {
        var origin = CampusProfile.Origin(profile.PortalUrl) ?? throw new InvalidOperationException("认证地址无效。");
        var payload = JsonSerializer.Serialize(new {
            origin, username = profile.Username, password, serviceOption = profile.ServiceOption, userSelector = "",
            passwordSelector = "", submitSelector = "", submit = profile.AutoSubmit, confirmSubmit = true, statusOnly
        });
        using var stream = typeof(PortalScript).Assembly.GetManifestResourceStream("CampusConnect.PortalTemplate.js")
            ?? throw new InvalidOperationException("缺少认证脚本。");
        using var reader = new StreamReader(stream);
        using var agreementStream = typeof(PortalScript).Assembly.GetManifestResourceStream("CampusConnect.PortalAgreements.js")
            ?? throw new InvalidOperationException("缺少登录勾选脚本。");
        using var agreementReader = new StreamReader(agreementStream);
        using var captchaStream = typeof(PortalScript).Assembly.GetManifestResourceStream("CampusConnect.PortalCaptcha.js")
            ?? throw new InvalidOperationException("缺少验证码辅助脚本。");
        using var captchaReader = new StreamReader(captchaStream);
        using var accountStream = typeof(PortalScript).Assembly.GetManifestResourceStream("CampusConnect.PortalAccount.js")
            ?? throw new InvalidOperationException("缺少账号认证脚本。");
        using var accountReader = new StreamReader(accountStream);
        var script = reader.ReadToEnd().Replace("/*CAMPUS_CONFIG*/", payload, StringComparison.Ordinal)
            .Replace("  /*CAMPUS_ACCOUNT*/", accountReader.ReadToEnd().TrimEnd(), StringComparison.Ordinal)
            .Replace("  /*CAMPUS_CAPTCHA*/", captchaReader.ReadToEnd().TrimEnd(), StringComparison.Ordinal)
            .Replace("  /*CAMPUS_AGREEMENTS*/", agreementReader.ReadToEnd().TrimEnd(), StringComparison.Ordinal);
        return InContext(profile, script, "'wrong-origin'");
    }
}
