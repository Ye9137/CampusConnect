import Foundation

struct PortalProblem: Identifiable, Equatable {
    let code: String
    let title: String
    let summary: String
    let advice: String
    var id: String { code }
    var settingsField: String? {
        if ["missing-service", "service-control-missing", "service-option-missing", "service-selection-failed", "service-required"].contains(code) { return "serviceOption" }
        if ["missing-fields", "missing-credentials"].contains(code) { return "username" }
        return ["load-failed", "wrong-origin", "waiting-ready"].contains(code) ? "portalUrl" : nil
    }
    var steps: [String] {
        settingsField == "serviceOption" ? [
            "查看学校认证网页，确认是否有运营商 / 服务选择框。页面尚未加载完成时，先等待加载。",
            code == "service-control-missing" ? "如果网页没有需要选择的选项，请打开校园网设置，清空“运营商 / 服务选项”，保持空白。未识别到控件也可能是页面结构暂不支持，请先人工确认。" : "如果网页有选项，展开后核对完整名称。请填写网页显示的完整选项名称，不要填写简称、猜测名称或网页上不存在的内容；网页没有此选项时保持空白。",
            "点击“打开对应设置”定位到运营商输入框，按网页实际情况清空或修改。这里不会自动删除你的填写内容。",
            "点击“保存设置”，再返回“上网认证”点击“立即认证”。若仍无法匹配，可先在学校网页手动选择并登录，再通过左下角入口反馈。"
        ] : [advice, "打开对应设置，核对认证地址以及账号输入位置。未识别到输入框不代表账号或密码错误；若网页是二维码模式，请先切换到账号密码登录。", "保存修改后返回上网认证，点击“立即认证”重试；也可在学校网页中手动登录。"]
    }
    static func isAuthenticationRejected(_ status: String?) -> Bool {
        status == "authentication-rejected" || status?.hasPrefix("authentication-rejected:") == true
    }
    static func authenticationMessage(_ status: String?) -> String {
        let prefix = "authentication-rejected:"
        let code = status?.hasPrefix(prefix) == true ? String(status!.dropFirst(prefix.count)) : ""
        if code.range(of: "^E[0-9]{4,8}$", options: .regularExpression) != nil && !code.contains("\n") {
            return "学校返回 \(code)，已暂停自动重试。请查看学校网页提示后处理；此代码尚无已核实的含义。"
        }
        return "学校返回登录失败，请查看网页提示并检查账号、密码和服务选项。"
    }
    static func serviceCode(_ reason: String?) -> String {
        ["service-control-missing", "service-option-missing", "service-selection-failed"].contains(reason ?? "") ? reason! : "missing-service"
    }

    static func from(_ code: String) -> PortalProblem? {
        let content: (String, String, String)
        switch code {
        case "service-control-missing": content = ("网页未找到运营商 / 服务选项", "设置中填写了运营商 / 服务选项，但当前认证网页未识别到对应的选择控件，已暂停自动登录。", "网页没有需要选择的选项时，请清空设置中的运营商 / 服务选项；网页确有选项时，先等待加载或手动选择。")
        case "service-option-missing": content = ("网页未匹配到填写的服务名称", "当前网页的可识别选项中，未找到与你填写内容完全一致且可选择的服务名称，已暂停自动登录。", "核对网页上的完整名称以及选项是否可用；请勿填写简称或不存在的名称。网页没有运营商选项时保持空白。")
        case "service-selection-failed": content = ("网页未确认服务选中", "找到相关服务项，但无法唯一确定选项，或学校网页没有确认选中，已暂停自动登录。", "请在学校网页中手动选择并确认服务项，再检查保存的完整名称；不要反复自动提交。")
        case "load-failed": content = ("认证页面无法打开", "认证页面加载失败，已暂停自动重试。", "先确认已连接校园 Wi-Fi 或网线，再核对认证地址。可在系统浏览器中打开学校登录页；地址变化时，在确认属于学校后更新认证地址。")
        case "wrong-origin": content = ("请核对认证地址", "当前页面与允许的认证地址不匹配，已停止自动填写。", "确认当前页面属于学校后，使用“使用当前页面地址”更新认证地址，再保存并重新认证。不要将外站地址保存为认证入口。")
        case "missing-service": content = ("请修改运营商 / 服务选项", "未找到或未能选中设置中填写的服务选项，无法自动填写信息。", "如果认证网页没有需要选择的选项，请不要填写，否则会导致无法自动填写信息。请清空设置中的“运营商 / 服务选项”；有选项时填写网页显示的完整名称，保存后重新认证。")
        case "service-required": content = ("请选择运营商或服务", "认证网页要求选择运营商或服务，当前尚未选中。", "在“运营商 / 服务选项”中填写网页显示的完整名称，例如中国移动，保存后重新认证；也可在学校网页中手动选择后登录。")
        case "authentication-rejected": content = ("学校未接受本次登录", "学校页面返回登录失败，已暂停自动重试。", "先查看学校网页的具体提示，再核对上网账号、密码、运营商和验证码。修改后保存设置并重新认证；账号欠费、停用或并发限制请联系学校处理。")
        case "missing-credentials": content = ("请补充上网账号和密码", "尚未保存完整的上网认证信息。", "在校园网设置中填写上网账号和上网密码，保存后重新认证。Wi-Fi 密码与上网认证密码可能不同。")
        case "missing-submit": content = ("未识别登录按钮", "账号密码已填写，但未找到可用的登录按钮。", "请先在学校网页中手动点击登录。若仍无法登录，请通过左下角反馈入口提供学校名称和失败过程。")
        case "agreement-required": content = ("请确认上网协议", "网页必选勾选项或协议尚未确认。", "在认证网页阅读并勾选必需的上网协议或使用承诺，再手动登录。不要勾选与上网无关的选项。")
        case "waiting-ready": content = ("学校页面尚未就绪", "等待后仍未取得学校认证所需的页面参数。", "等待学校网页加载完成，再点击立即认证；也可手动登录。若持续出现，请核对认证地址并反馈学校名称和失败过程。")
        case "submission-unconfirmed": content = ("尚未确认登录提交", "学校页面未确认本次登录已提交。", "检查网页是否要求验证码、服务选项或协议，补充后手动登录；不要反复提交相同信息。")
        case "missing-fields": content = ("未识别认证表单", "等待后仍未找到可自动填写的登录表单。", "确认认证地址确实打开学校登录页。若网页没有运营商选项，请清空“运营商 / 服务选项”；也可在网页中手动登录并通过左下角反馈入口反馈。")
        case "script-failed": content = ("自动填写未完成", "学校页面脚本未能完成自动填写，已暂停自动重试。", "等待页面加载完成后点击立即认证，或在网页中手动登录。若仍失败，请核对认证地址和服务选项，并反馈学校名称和失败过程。")
        default: return nil
        }
        return PortalProblem(code: code, title: content.0, summary: content.1, advice: content.2)
    }
}

struct PortalProblemGate {
    private(set) var current: PortalProblem?
    mutating func report(_ code: String, serviceOption: String? = nil) -> PortalProblem? {
        guard current == nil, var problem = PortalProblem.from(code) else { return nil }
        if problem.settingsField == "serviceOption", let value = serviceOption, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let safe = String(value.components(separatedBy: .controlCharacters).joined().prefix(80))
            problem = PortalProblem(code: problem.code, title: problem.title, summary: problem.summary + "\n填写的服务选项：" + safe, advice: problem.advice)
        }
        current = problem
        return problem
    }
    mutating func reset() { current = nil }
}

enum JoinMode: String, Codable, CaseIterable, Identifiable {
    case open, personal, enterprise
    var id: String { rawValue }
    var title: String {
        switch self { case .open: return "开放网络"; case .personal: return "Wi-Fi 密码"; case .enterprise: return "企业账号（802.1X）" }
    }
}

enum WiredAuth: String, Codable, CaseIterable, Identifiable {
    case web, pppoe, dot1x, client
    var id: String { rawValue }
    var title: String {
        switch self {
        case .web: return "网页认证"
        case .pppoe: return "PPPoE 宽带拨号"
        case .dot1x: return "802.1X 系统认证"
        case .client: return "学校专用客户端"
        }
    }
}

struct CampusProfile: Codable, Equatable {
    var ssid = ""
    var connectionMode: String?
    var wiredAuth: WiredAuth = .web
    var ethernetName = ""
    var broadbandName = ""
    var authenticationClient = ""
    var isWired: Bool { connectionMode == "wired" || (connectionMode == nil && ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    var usesSystemAuthentication: Bool { isWired && wiredAuth != .web }
    var usesWebPortal: Bool { portalEnabled && !usesSystemAuthentication }
    var connectionLabel: String { isWired ? "有线 · \(wiredAuth.title)" : "Wi-Fi" }
    func matchesNetwork(currentSSID: String?, wiredAvailable: Bool) -> Bool {
        isWired ? wiredAvailable : currentSSID == ssid
    }
    var joinMode: JoinMode = .open
    var wifiUsername = ""
    var portalEnabled = true
    var portalURL = ""
    var username = ""
    var serviceOption = ""
    var autoSubmit = true
    var automatic = false

    enum CodingKeys: String, CodingKey {
        case ssid, connectionMode, joinMode, wifiUsername, portalEnabled, portalURL, username
        case serviceOption, autoSubmit, automatic
        case wiredAuth, ethernetName, broadbandName, authenticationClient
    }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ssid = try values.decodeIfPresent(String.self, forKey: .ssid) ?? ""
        connectionMode = try values.decodeIfPresent(String.self, forKey: .connectionMode)
        wiredAuth = try values.decodeIfPresent(WiredAuth.self, forKey: .wiredAuth) ?? .web
        ethernetName = try values.decodeIfPresent(String.self, forKey: .ethernetName) ?? ""
        broadbandName = try values.decodeIfPresent(String.self, forKey: .broadbandName) ?? ""
        authenticationClient = try values.decodeIfPresent(String.self, forKey: .authenticationClient) ?? ""
        joinMode = try values.decodeIfPresent(JoinMode.self, forKey: .joinMode) ?? .open
        wifiUsername = try values.decodeIfPresent(String.self, forKey: .wifiUsername) ?? ""
        portalEnabled = try values.decodeIfPresent(Bool.self, forKey: .portalEnabled) ?? true
        portalURL = try values.decodeIfPresent(String.self, forKey: .portalURL) ?? ""
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        serviceOption = try values.decodeIfPresent(String.self, forKey: .serviceOption) ?? ""
        autoSubmit = try values.decodeIfPresent(Bool.self, forKey: .autoSubmit) ?? true
        automatic = try values.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
    }

    static func empty(wired: Bool) -> CampusProfile {
        var result = CampusProfile()
        result.connectionMode = wired ? "wired" : "wifi"; result.ssid = ""; result.portalURL = ""
        return result
    }

    var validPortalURL: URL? {
        guard let url = URL(string: portalURL), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    func validate() throws {
        guard connectionMode == nil || ["wifi", "wired"].contains(connectionMode!) else { throw AppError.message("请选择有线或 Wi-Fi 网络。") }
        guard isWired || !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("请填写校园 Wi-Fi 名称。") }
        guard isWired || ssid.utf8.count <= 32 else { throw AppError.message("Wi-Fi 名称最多为 32 字节；有线模式请留空。") }
        if !isWired && joinMode == .enterprise && wifiUsername.isEmpty { throw AppError.message("企业认证需要 Wi-Fi 用户名。") }
        if ethernetName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { throw AppError.message("以太网接口名称无效。") }
        if isWired && wiredAuth == .pppoe && (broadbandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || broadbandName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)) {
            throw AppError.message("请填写 macOS 中已配置的 PPPoE 服务名称。")
        }
        if isWired && wiredAuth == .client && (!authenticationClient.hasPrefix("/") || !authenticationClient.hasSuffix(".app")) {
            throw AppError.message("请选择已安装的学校认证客户端 .app 应用。")
        }
        if usesWebPortal && !portalURL.isEmpty && validPortalURL == nil { throw AppError.message("认证地址需要以 http:// 或 https:// 开头。") }
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

struct Secrets: Codable, Equatable {
    var wifi = ""
    var portal = ""
}

struct LocalConfiguration: Codable {
    var profile: CampusProfile
    var credentials: [String: Secrets] = [:]
    var profiles: [String: CampusProfile] = [:]
    enum CodingKeys: String, CodingKey { case profile, credentials, profiles }
    init(profile: CampusProfile) { self.profile = profile }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profile = try values.decode(CampusProfile.self, forKey: .profile)
        credentials = try values.decodeIfPresent([String: Secrets].self, forKey: .credentials) ?? [:]
        profiles = try values.decodeIfPresent([String: CampusProfile].self, forKey: .profiles) ?? [:]
    }
    var allProfiles: [String: CampusProfile] {
        var result = profiles
        result[profile.isWired ? "wired" : "wifi"] = profile
        return result
    }
}

struct ConnectionSettings: Equatable {
    var profile: CampusProfile
    var secrets: Secrets
}

struct ConnectionDrafts {
    private var entries: [String: ConnectionSettings] = [:]
    init(configuration: LocalConfiguration) {
        for (key, profile) in configuration.allProfiles {
            entries[key] = ConnectionSettings(profile: profile, secrets: configuration.credentials[profile.ssid] ?? Secrets())
        }
    }
    mutating func remember(profile: CampusProfile, secrets: Secrets) {
        entries[profile.isWired ? "wired" : "wifi"] = ConnectionSettings(profile: profile, secrets: secrets)
    }
    func settings(wired: Bool) -> ConnectionSettings {
        let key = wired ? "wired" : "wifi"
        var entry = entries[key] ?? ConnectionSettings(profile: .empty(wired: wired), secrets: Secrets())
        entry.profile.connectionMode = key
        return entry
    }
}

enum LocalStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CampusConnect", isDirectory: true)
    }
    static func load(directory: URL = directory) throws -> LocalConfiguration {
        let file = directory.appendingPathComponent("configuration.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            let legacy = UserDefaults.standard.data(forKey: "campus.profile")
                .flatMap { try? JSONDecoder().decode(CampusProfile.self, from: $0) } ?? CampusProfile.empty(wired: false)
            return LocalConfiguration(profile: legacy)
        }
        return try JSONDecoder().decode(LocalConfiguration.self, from: Data(contentsOf: file))
    }
    static func read(_ ssid: String, _ kind: String, directory: URL = directory) throws -> String {
        let secrets = try load(directory: directory).credentials[ssid] ?? Secrets()
        return kind == "wifi" ? secrets.wifi : secrets.portal
    }
    static func save(profile: CampusProfile, secrets: Secrets? = nil, directory: URL = directory) throws {
        var configuration = try load(directory: directory)
        configuration.profiles = configuration.allProfiles
        configuration.profiles[profile.isWired ? "wired" : "wifi"] = profile
        configuration.profile = profile
        if let secrets { configuration.credentials[profile.ssid] = secrets }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent("configuration.json")
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

enum AutomaticNetworkWork { case stopped, otherNetwork, findTarget, checkInternet }

struct AutoPolicy {
    static let checkInterval: TimeInterval = 5
    static func backgroundWork(enabled: Bool, wired: Bool, target: String, current: String?) -> AutomaticNetworkWork {
        if !enabled || (!wired && target.isEmpty) { return .stopped }
        if wired || current == target { return .checkInternet }
        return current == nil || current?.isEmpty == true ? .findTarget : .otherNetwork
    }
    var lastAttempt = Date.distantPast
    func shouldJoin(enabled: Bool, target: String, current: String?, visible: [String], busy: Bool, now: Date) -> Bool {
        enabled && !target.isEmpty && (current == nil || current?.isEmpty == true) && visible.contains(target) && !busy && now.timeIntervalSince(lastAttempt) >= Self.checkInterval
    }
    func shouldPrepareWired(enabled: Bool, needed: Bool, busy: Bool, now: Date) -> Bool {
        enabled && needed && !busy && now.timeIntervalSince(lastAttempt) >= 60
    }
    mutating func begin(at date: Date) { lastAttempt = date }
    mutating func reset() { lastAttempt = .distantPast }
}

enum InternetStatus: String { case online, unavailable }
struct PortalRecovery {
    private(set) var failures = 0
    private(set) var attempts = 0
    private(set) var lastAttempt = Date.distantPast
    private(set) var state: InternetStatus = .unavailable
    var retryDelay: TimeInterval { AutoPolicy.checkInterval }
    mutating func observe(_ result: InternetStatus) {
        if result == .online { reset(); state = .online }
        else { state = result; failures = min(2, failures + 1) }
    }
    func shouldAuthenticate(enabled: Bool, portalEnabled: Bool, now: Date) -> Bool {
        enabled && portalEnabled && state != .online && ((attempts == 0 && failures == 0) || failures >= 1)
            && now.timeIntervalSince(lastAttempt) >= retryDelay
    }
    mutating func begin(at now: Date) { lastAttempt = now; attempts = min(4, attempts + 1) }
    mutating func reset() { self = PortalRecovery() }
}

enum PortalFillRetry {
    static let maxAttempts = 200
    static let delay: TimeInterval = 0.15
    static func shouldRetry(result: String?, scriptFailed: Bool, attempt: Int) -> Bool {
        if !scriptFailed && result == "missing-service" { return attempt < 80 }
        return attempt < maxAttempts && (scriptFailed || ["waiting-ready", "waiting-submit", "waiting-agreement", "wrong-origin", "missing-fields", "missing-submit", "missing-service"].contains(result ?? ""))
    }
}

enum PortalScript {
    static func atCurrentPage(profile: CampusProfile, url: URL) throws -> CampusProfile {
        guard origin(url) != nil, url.user == nil, url.password == nil else {
            throw AppError.message("当前页面不是有效的 HTTP/HTTPS 认证页。")
        }
        var result = profile
        result.portalURL = url.absoluteString
        return result
    }
    static func loginFormProbe(profile: CampusProfile) throws -> String {
        try inContext(#"""
        (() => {
          if (document.readyState === 'loading') return false;
          return [...document.querySelectorAll('input[type="password"]')].some(input =>
            input instanceof HTMLInputElement && !input.disabled && !input.readOnly &&
            (input.getClientRects().length > 0 || (input.id === 'pwd' &&
              (document.querySelector('#pwd_tip') || document.querySelector('#passwordIn_1'))?.getClientRects().length > 0)));
        })()
        """#, profile: profile)
    }
    static func serviceFailure(profile: CampusProfile) throws -> String {
        try inContext("window.__campusServiceFailure || 'missing-service'", profile: profile)
    }
    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host?.lowercased() else { return nil }
        let port = url.port
        let defaultPort = scheme == "https" ? 443 : 80
        let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(formattedHost)\(port != nil && port != defaultPort ? ":\(port!)" : "")"
    }
    static func inContext(_ script: String, profile: CampusProfile) throws -> String {
        guard let url = profile.validPortalURL, let allowedOrigin = origin(url) else { throw AppError.message("认证地址无效。") }
        func json(_ value: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
        }
        return try contextScript.replacingOccurrences(of: "/*CONTEXT_ORIGIN*/", with: json(allowedOrigin))
            .replacingOccurrences(of: "/*CONTEXT_FALLBACK*/", with: "'missing-fields'")
            .replacingOccurrences(of: "/*CONTEXT_PASSWORD_SELECTOR*/", with: json(""))
            .replacingOccurrences(of: "/*CONTEXT_SCRIPT*/", with: script)
    }
    static let contextScript = #"""
    ((run) => {
      const origin = /*CONTEXT_ORIGIN*/;
      const fallback = /*CONTEXT_FALLBACK*/;
      if (location.origin !== origin) return typeof fallback === 'boolean' ? false : 'wrong-origin';
      const selector = /*CONTEXT_PASSWORD_SELECTOR*/ || 'input[type="password"]';
      const candidates = [], leaves = [];
      let count = 0, exhausted = false;
      const visit = (target, depth) => {
        if (depth > 8 || ++count > 64) { exhausted = true; return; }
        try {
          if (target.location.origin !== origin) return;
          const doc = target.document;
          // Prefer a form on this document over embedded ancillary content.
          // Hidden password controls are intentional on older CMCC portals.
          if (doc.querySelector(selector)) { candidates.push(target); return; }
          let children = 0;
          for (const frame of doc.querySelectorAll('frame,iframe')) {
            const style = target.getComputedStyle(frame);
            if (![...frame.getClientRects()].some(rect => rect.width > 0 && rect.height > 0) || style.display === 'none' ||
                style.visibility === 'hidden' || style.visibility === 'collapse') continue;
            children++;
            visit(frame.contentWindow, depth + 1);
          }
          if (!children) leaves.push(target);
        } catch (_) { /* Cross-origin and sandboxed frames never receive credentials. */ }
      };
      const direct = () => run(window, document, location, HTMLInputElement, globalThis.HTMLSelectElement,
        globalThis.HTMLOptGroupElement, globalThis.Event, globalThis.FocusEvent, globalThis.MouseEvent, globalThis.getComputedStyle);
      let hasFrames;
      try { hasFrames = !!document.querySelector('frame,iframe'); document.querySelector(selector); }
      catch (_) { return direct(); }
      if (!hasFrames) return direct();
      visit(window, 0);
      const target = candidates.length === 1 ? candidates[0] :
        candidates.length === 0 && leaves.length === 1 ? leaves[0] : null;
      if (!target || exhausted) return fallback;
      return run(target, target.document, target.location, target.HTMLInputElement,
        target.HTMLSelectElement, target.HTMLOptGroupElement, target.Event,
        target.FocusEvent, target.MouseEvent, target.getComputedStyle.bind(target));
    })(function(window, document, location, HTMLInputElement, HTMLSelectElement,
        HTMLOptGroupElement, Event, FocusEvent, MouseEvent, getComputedStyle) {
      return /*CONTEXT_SCRIPT*/;
    })
    """#
    static func build(profile: CampusProfile, password: String, statusOnly: Bool = false) throws -> String {
        guard let url = profile.validPortalURL, let origin = origin(url) else { throw AppError.message("请先保存认证地址。") }
        let payload: [String: Any] = ["origin": origin, "username": profile.username, "password": password,
                                    "serviceOption": profile.serviceOption, "userSelector": "", "passwordSelector": "",
                                    "submitSelector": "", "submit": profile.autoSubmit, "confirmSubmit": true, "statusOnly": statusOnly]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        // Credentials are supplied to the current page only after native SSID + origin checks.
        let script = """
        (() => {
          const cfg = \(json);
          if (location.origin !== cfg.origin) return 'wrong-origin';
          const outcome = window.__campusSubmitAttempt?.result;
          const successPage = location.pathname === '/eportal/success.jsp' &&
            !!new URLSearchParams(location.search).get('userIndex');
          if (successPage || outcome === 'success') return 'authenticated';
          if (outcome === 'fail') return 'authentication-rejected' + (window.__campusSubmitAttempt?.failureCode ? ':' + window.__campusSubmitAttempt.failureCode : '');
          if (outcome === 'request-error') return 'submission-unconfirmed';
          if (cfg.statusOnly) return window.__campusSubmitted ? 'awaiting-authentication' : 'not-submitted';
          const pending = cfg.confirmSubmit && window.__campusSubmitAttempt;
          if (pending && pending.failed) return 'submission-unconfirmed';
          if (window.__campusSubmitted) return 'already-submitted';
          if (pending && pending.handlerStarted) {
            if (pending.failed || Date.now() - pending.startedAt >= 8000) return 'submission-unconfirmed';
            return 'waiting-submit';
          }
          if (document.readyState === 'loading') return 'waiting-ready';
          const ready = window.__campusReady;
          if (ready && (ready.failed || !ready.pageInfo || !ready.getServices)) return 'waiting-ready';
          const visible = e => e && !e.disabled && e.getClientRects().length > 0;
          const editable = e => e instanceof HTMLInputElement && !e.disabled && !e.readOnly;
          let user, pass, submit, portalUser, portalPass, portalButton, accountButton, gportalForm, gportalUser, gportalPass, gportalButton;
          const tipFor = input => input === portalUser ? document.querySelector('#username_tip') :
            input === portalPass ? document.querySelector('#pwd_tip') || document.querySelector('#passwordIn_1') : null;
          const available = input => editable(input) && (visible(input) ||
            (portalButton && visible(tipFor(input))));
          try {
            // Ruijie ePortal displays readonly tips over hidden real inputs. Its login
            // control is an image-only anchor, so text/button heuristics cannot find it.
            portalUser = document.querySelector('#username');
            portalPass = document.querySelector('#pwd');
            portalButton = document.querySelector('#loginLink');
            if (!editable(portalUser) || portalUser.type !== 'text' ||
                !editable(portalPass) || portalPass.type !== 'password' || !portalButton) {
              portalUser = portalPass = portalButton = null;
            }
            // Inspected CMCC union page: use its original prompt and checkform handler.
            if (!portalButton) {
              const button = document.querySelector('#login_btn');
              const prompt = document.querySelector('#passwordIn_1');
              const account = document.querySelector('#username');
              const secret = document.querySelector('#pwd');
              if (editable(account) && account.type === 'text' && editable(secret) && secret.type === 'password' &&
                  editable(prompt) && prompt.type === 'text' && /checkform\\s*\\(/.test(button?.getAttribute('onclick') || '') &&
                  typeof window.checkform === 'function' && typeof window.hidePassword === 'function') {
                portalUser = account; portalPass = secret; portalButton = button;
              }
            }
            // Unknown ePortal variants retain full-load behavior; only inspected initialization is accelerated.
            if (portalButton && !ready && document.readyState !== 'complete') return 'waiting-ready';
            // Inspected Gportal page contains login, registration, reset and binding
            // forms together. Never let another password form receive login credentials.
            gportalForm = /^\\/gportal(?:\\/|$)/.test(location.pathname) ? document.querySelector('form#frmLogin') : null;
            if (gportalForm) {
              gportalUser = gportalForm.querySelector('input#first_name[type="text"]');
              gportalPass = gportalForm.querySelector('input#first_password[type="password"]');
              if (!editable(gportalUser) || !editable(gportalPass) || gportalUser.form !== gportalForm || gportalPass.form !== gportalForm)
                return 'missing-fields';
              const button = gportalForm.querySelector('input#first_button[type="button"]');
              gportalButton = button && /^\\s*(?:javascript\\s*:\\s*)?login\\s*\\(\\s*\\)\\s*;?\\s*$/.test(button.getAttribute('onclick') || '') ? button : null;
            }
            pass = cfg.passwordSelector ? document.querySelector(cfg.passwordSelector) :
              gportalForm ? gportalPass : portalPass || [...document.querySelectorAll('input[type="password"]')].find(e => editable(e) && visible(e));
            const root = pass && pass.form ? pass.form : document;
            user = cfg.userSelector ? document.querySelector(cfg.userSelector) : gportalForm ? gportalUser : portalUser ||
              [...root.querySelectorAll('input:not([type="password"]):not([type="hidden"]):not([type="checkbox"]):not([type="radio"]):not([type="submit"]):not([type="button"])')]
              .filter(e => editable(e) && visible(e)).find(e => /user|account|student|phone|login|学号|账号|手机/i.test([e.name,e.id,e.placeholder,e.autocomplete].join(' ')));
            if (!user && !cfg.userSelector) user = [...root.querySelectorAll('input[type="text"],input[type="tel"],input[type="email"],input:not([type])')].find(e => editable(e) && visible(e));
            // User-inspected HAUST account button; preserve its own checkForm handler.
            const accountCandidate = root.querySelector('button#login-account[type="button"]');
            accountButton = accountCandidate &&
              /^\\s*checkForm\\s*\\(\\s*\\)\\s*;?\\s*$/.test(accountCandidate.getAttribute('onclick') || '') &&
              (accountCandidate.textContent || '').trim() === '立即登录' ? accountCandidate : null;
            // User-confirmed 陕西国防工业职业技术学院 login control. Keep the
            // original click handler, scoped to the selected credential form.
            const idButtons = [...root.querySelectorAll('[id="submit"]')].filter(e =>
              visible(e) && !e.closest('[hidden],[inert],[aria-disabled="true"]') &&
              !['hidden','collapse'].includes(getComputedStyle(e).visibility) &&
              (!e.form || e.form === pass.form) &&
              e.matches('button:not([type="reset"]),input[type="submit"],input[type="button"],a,[role="button"],[onclick]') && e.type !== 'reset');
            const idSubmit = idButtons.length === 1 ? idButtons[0] : null;
            submit = cfg.submitSelector ? document.querySelector(cfg.submitSelector) : gportalForm ? gportalButton : portalButton || accountButton || idSubmit ||
              [...root.querySelectorAll('button,input[type="submit"],input[type="button"],a,[role="button"]')].filter(visible)
                .find(e => e !== accountCandidate && e.id !== 'submit' && (e.type === 'submit' || /^(立即登录|立即登陆|登录|登陆|认证|连接|login|log in|sign in|connect)(\\s*(login|登录|登陆))?$/i.test((e.innerText || e.value || '').trim())));
          } catch (_) { return 'invalid-selector'; }
          if (!available(user) || !available(pass)) return 'missing-fields';
          /*CAMPUS_ACCOUNT*/
          /*CAMPUS_GPORTAL*/
          const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
          for (const [input, value] of [[user,cfg.username],[pass,cfg.password]]) {
            if (input === portalPass && portalButton?.id === 'login_btn' && visible(tipFor(input))) tipFor(input).click();
            if (!visible(input)) {
              const tip = tipFor(input);
              if (visible(tip)) {
                tip.focus();
                // Background WebViews may not deliver native focus. Invoke the school's
                // own reveal handlers without taking OS focus or changing its DOM styles.
                if (!visible(input) && visible(tip)) tip.dispatchEvent(new FocusEvent('focus'));
                if (!visible(input) && visible(tip)) tip.dispatchEvent(new FocusEvent('focusin', {bubbles:true}));
                if (!visible(input) && visible(tip)) tip.click();
              }
            }
            if (!editable(input) || !visible(input)) return 'missing-fields';
            if (!cfg.confirmSubmit || input.value !== value) {
              setter.call(input, value);
              input.dispatchEvent(new Event('input', {bubbles:true}));
              input.dispatchEvent(new Event('change', {bubbles:true}));
            }
          }
          window.__campusServiceFailure = null;
          const serviceMissing = reason => { window.__campusServiceFailure = reason; return 'missing-service'; };
          const serviceName = (cfg.serviceOption || '').trim();
          // Some portals place the operator dropdown outside the credentials form.
          // Include unassociated controls, but never select a service in another form.
          const serviceSelects = [...document.querySelectorAll('select')]
            .filter(select => visible(select) && !select.multiple && (!select.form || select.form === pass.form));
          const servicePlaceholder = text => /^(请)?选择((运营商|服务)(选项)?|选项)[：:….。]*$/.test((text || '').replace(/\\s/g, ''));
          const serviceText = control => (control instanceof HTMLInputElement ? control.value || control.placeholder : control.textContent || '').trim();
          const serviceDescriptor = control => [control.id, control.getAttribute('name'), control.getAttribute('aria-label'),
            control.getAttribute('aria-controls'), ...(control.getAttribute('aria-labelledby') || '').split(/\\s+/)
              .map(id => document.getElementById(id)?.textContent || '')].join(' ');
          const serviceOpeners = [...document.querySelectorAll('[role="combobox"],[aria-haspopup],[aria-controls],button,[role="button"]')]
            .filter(control => !(control instanceof HTMLSelectElement) && visible(control) &&
              control.getAttribute('aria-disabled') !== 'true' && (!control.closest('form') || control.closest('form') === pass.form) &&
              (servicePlaceholder(serviceText(control)) || window.__campusCustomServiceMenus?.has(control) ||
                (control.matches('[role="combobox"],[aria-haspopup]') &&
                  (serviceText(control) === serviceName || /运营商|服务|operator|carrier|service/i.test(serviceDescriptor(control))))));
          if (!serviceName && (serviceSelects.some(select => servicePlaceholder(select.selectedOptions[0]?.textContent)) ||
              serviceOpeners.some(control => servicePlaceholder(serviceText(control))))) {
            return 'service-required';
          }
          if (serviceName) {
            const normalized = text => (text || '').trim();
            const serviceValue = document.querySelector('#net_access_type');
            const serviceLabel = document.querySelector('#selectDisname');
            if (portalButton && serviceValue && serviceLabel && !(serviceValue instanceof HTMLSelectElement)) {
              // Use the school's existing menu click handlers, including domain/operator updates.
              // Opening the menu can lazily fetch services for the account just filled above.
              if (normalized(serviceLabel.textContent) !== serviceName || !serviceValue.value) {
                const opener = document.querySelector('#serviceShowHideTop');
                const opened = window.__campusServiceMenus ||= new WeakMap();
                if (visible(opener) && opened.get(opener) !== cfg.username) {
                  opened.set(opener, cfg.username);
                  opener.click();
                }
                const choices = [...document.querySelectorAll('#serviceShowHide [id^="bch_service_"]')]
                  .filter(row => visible(row) && row.getAttribute('aria-disabled') !== 'true' &&
                    normalized((row.querySelector('[id^="_service_"]') || row).textContent) === serviceName);
                if (choices.length !== 1) return serviceMissing(choices.length === 0 ? 'service-option-missing' : 'service-selection-failed');
                choices[0].click();
                if (normalized(serviceLabel.textContent) !== serviceName || !serviceValue.value) return serviceMissing('service-selection-failed');
              }
            } else {
              // Operator choices can also be horizontal native or accessible radios,
              // including controls placed above and outside the credentials form.
              const radios = [...document.querySelectorAll('input[type="radio"],[role="radio"]')];
              const radioChoices = radios.filter(control => {
                if (!(control instanceof HTMLInputElement) && control.querySelector('input[type="radio"]')) return false;
                const form = control.form || control.closest('form');
                if (form && form !== pass.form) return false;
                if (control.matches(':disabled') || control.closest('[aria-disabled="true"]')) return false;
                const labels = [...(control.labels || [])];
                const wrapper = control.closest('label,[role="radio"]');
                if (wrapper && !labels.includes(wrapper)) labels.push(wrapper);
                for (const id of (control.getAttribute('aria-labelledby') || '').split(/\\s+/).filter(Boolean)) {
                  const label = document.getElementById(id);
                  if (label) labels.push(label);
                }
                if (!visible(control) && !labels.some(visible)) return false;
                const names = [control.getAttribute('aria-label'), ...labels.map(label => label.textContent)];
                if (control.getAttribute('role') === 'radio') names.push(control.textContent);
                // Older pages use bare text or FONT/SPAN text after each input.
                // Localization comments and indentation can sit between the two.
                let sibling = control.nextSibling;
                while (sibling && (sibling.nodeType === 8 ||
                    (sibling.nodeType === 3 && !normalized(sibling.textContent)))) sibling = sibling.nextSibling;
                if (sibling?.nodeType === 3) names.push(sibling.textContent);
                if (sibling?.nodeType === 1 && sibling.matches('font,span,label') &&
                    !sibling.querySelector('input,button,[role="radio"]')) names.push(sibling.textContent);
                return names.some(name => normalized(name) === serviceName);
              });
              const choices = serviceSelects
                .flatMap(select => [...select.options].filter(option => !option.disabled &&
                  !(option.parentElement instanceof HTMLOptGroupElement && option.parentElement.disabled) &&
                  normalized(option.textContent) === serviceName).map(option => ({select, option})));
              if (choices.length + radioChoices.length > 1) return serviceMissing('service-selection-failed');
              if (radioChoices.length === 1) {
                const radio = radioChoices[0];
                const checked = () => radio instanceof HTMLInputElement ? radio.checked : radio.getAttribute('aria-checked') === 'true';
                if (!checked()) {
                  const previous = window.__campusServiceRadioAttempt;
                  if (!previous || previous.control !== radio || previous.username !== cfg.username || previous.serviceName !== serviceName) {
                    window.__campusServiceRadioAttempt = {control:radio, username:cfg.username, serviceName};
                    // Click through the school's handler; setting checked alone skips
                    // account-domain updates and other operator-specific page logic.
                    radio.click();
                  }
                }
                if (!radio.isConnected || !checked() || radio.matches(':disabled') ||
                    radio.closest('[aria-disabled="true"]')) return serviceMissing('service-selection-failed');
              } else if (choices.length === 1) {
                const {select, option} = choices[0];
                if (select.selectedIndex !== option.index) {
                  select.selectedIndex = option.index;
                  select.dispatchEvent(new Event('input', {bubbles:true}));
                  select.dispatchEvent(new Event('change', {bubbles:true}));
                }
                if (select.selectedOptions[0] !== option || select.disabled) return serviceMissing('service-selection-failed');
              } else {
                // Custom portals may create their choices only after opening the menu.
                // Match the configured visible name, without a fixed carrier/value list.
                if (serviceOpeners.length !== 1) {
                  const visibleRadios = radios.some(control => (!control.form || control.form === pass.form) &&
                    (visible(control) || [...(control.labels || [])].some(visible)));
                  return serviceMissing(serviceOpeners.length > 1 ? 'service-selection-failed' :
                    serviceSelects.length || visibleRadios ? 'service-option-missing' : 'service-control-missing');
                }
                const opener = serviceOpeners[0];
                if (serviceText(opener) !== serviceName) {
                  const opened = window.__campusCustomServiceMenus ||= new WeakMap();
                  const previous = opened.get(opener);
                  if ((!previous || previous.username !== cfg.username || previous.serviceName !== serviceName) &&
                      opener.getAttribute('aria-expanded') !== 'true') {
                    opened.set(opener, {username:cfg.username, serviceName});
                    opener.click();
                  }
                  const popupIds = (opener.getAttribute('aria-controls') || opener.getAttribute('aria-owns') || '').split(/\\s+/).filter(Boolean);
                  const popups = popupIds.length ? popupIds.map(id => document.getElementById(id)).filter(Boolean) :
                    [...document.querySelectorAll('[role="listbox"],[role="menu"]')];
                  const options = [...new Set(popups.filter(visible).flatMap(popup =>
                    [...popup.querySelectorAll('[role="option"],[role="menuitem"],[role="menuitemradio"],li,button')]))]
                    .filter(option => visible(option) && !option.closest('[aria-disabled="true"],[disabled]') &&
                      normalized(option.textContent) === serviceName);
                  if (options.length !== 1) return serviceMissing(options.length === 0 ? 'service-option-missing' : 'service-selection-failed');
                  options[0].click();
                  if (serviceText(opener) !== serviceName && options[0].getAttribute('aria-selected') !== 'true' &&
                      options[0].getAttribute('aria-checked') !== 'true') return serviceMissing('service-selection-failed');
                }
              }
            }
          }
          /*CAMPUS_AGREEMENTS*/
          // School handlers can reject/reset a value; never report success or submit it.
          if (!editable(user) || !editable(pass) || !visible(user) || !visible(pass) ||
              user.value !== cfg.username || pass.value !== cfg.password) return 'missing-fields';
          const unionCode = document.querySelector('#ps[name="psNum"]');
          if (portalButton?.id === 'login_btn' && unionCode && visible(unionCode) &&
              (!unionCode.value.trim() || unionCode.value.trim() === '请输入验证码')) return 'manual-required';
          if (!cfg.submit) return 'filled';
          if (gportalForm) {
            const agreement = document.querySelector('#serverAgreement');
            const protocol = document.querySelector('#login-protocol');
            if (protocol && typeof window.jQuery !== 'function') return 'waiting-ready';
            if ((agreement && !agreement.checked) || (protocol && window.jQuery(protocol).data('selected') != 2))
              return 'agreement-required';
          }
          if (!visible(submit)) return 'missing-submit';
          if (submit === accountButton && typeof window.checkForm !== 'function') return 'waiting-ready';
          if (portalButton && /doauthen/.test(submit.getAttribute('onclick') || '') &&
              typeof window.doauthen !== 'function') return 'waiting-ready';
          // Leave visible CAPTCHA fields to the school page so letters and case are preserved.
          const captchaFields = [...document.querySelectorAll('input')].filter(input =>
            input !== user && input !== pass && (!input.form || input.form === pass.form) &&
            visible(input) && !input.readOnly && /^(text|tel|number|search)$/.test(input.type) &&
            /captcha|valid[_-]?code|verify[_-]?code|check[_-]?code|验证码/i.test(
              [input.id,input.name,input.placeholder,input.getAttribute('aria-label'),input.getAttribute('formcontrolname'),
                ...[...(input.labels || [])].map(label => label.textContent)].join(' ')));
          if (captchaFields.some(input => !input.value.trim() || (input.form?.id === 'login_form' &&
              input.id === 'valid_code' && input.name === 'validCode' && input.value.trim() === '验证码'))) return 'manual-required';
          // Captchas and extra operator fields need the user's input; don't burn a login attempt.
          if (portalButton && ['#validCode','#operatorUserId','#operatorPwd'].some(selector => {
            const input = document.querySelector(selector);
            return visible(input) && !input.value.trim();
          })) return 'manual-required';
          // WKWebView can finish filling before the page handles its first activation.
          // Observe only the known school's own login flow; never call its API ourselves.
          if (cfg.confirmSubmit && submit === portalButton && /doauthen/.test(submit.getAttribute('onclick') || '')) {
            if (typeof window.AuthInterFace?.login !== 'function') return 'waiting-ready';
            const state = window.__campusSubmitAttempt ||= {clicks:0, prepared:false, handlerStarted:false, failed:false};
            const observe = (owner, key, flag) => {
              if (owner[key] === state[key]) return;
              const original = owner[key];
              const wrapped = function(...args) {
                if (flag === 'login') {
                  window.__campusSubmitted = true;
                  // Observe the school's response without replacing its request or callback.
                  const last = args.length - 1;
                  if (typeof args[last] === 'function') {
                    const callback = args[last];
                    args[last] = function(result, ...rest) {
                      if (result?.result === 'success') state.result = 'success';
                      else if (result?.result === 'fail') state.result = 'fail';
                      return callback.call(this, result, ...rest);
                    };
                  }
                }
                else { state.handlerStarted = true; state.startedAt = Date.now(); }
                try { return original.apply(this, args); }
                catch (error) { state.failed = true; throw error; }
              };
              state[key] = wrapped; owner[key] = wrapped;
            };
            observe(window, 'doauthen', 'handler');
            observe(window.AuthInterFace, 'login', 'login');
            if (!state.prepared || state.button !== submit || state.user !== user || state.pass !== pass) {
              state.prepared = true; state.button = submit; state.user = user; state.pass = pass;
              if (document.activeElement === user || document.activeElement === pass) document.activeElement.blur();
              submit.focus();
              // Let blur/change handlers and layout finish before rechecking the values.
              return 'waiting-submit';
            }
            if (state.clicks >= 2) {
              // Both click events were lost: invoke the same page handler once. All
              // school validation/encryption/service logic remains in that handler.
              try { window.doauthen.call(submit); } catch (_) { state.failed = true; }
              if (state.failed) return 'submission-unconfirmed';
              return window.__campusSubmitted ? 'submitted' : 'waiting-submit';
            }
            state.clicks++;
            try {
              if (state.clicks === 1) submit.click();
              else submit.dispatchEvent(new MouseEvent('click', {bubbles:true, cancelable:true, view:window}));
            } catch (_) { state.failed = true; }
            if (state.failed) return 'submission-unconfirmed';
            if (window.__campusSubmitted) return 'submitted';
            // A second activation is allowed only if the school's handler never ran.
            return 'waiting-submit';
          }
          window.__campusSubmitted = true;
          submit.click();
          if (gportalForm && window.__campusSubmitAttempt?.gportalObserved && !window.__campusSubmitAttempt.gportalRequestStarted) {
            window.__campusSubmitAttempt.failed = true;
            return 'submission-unconfirmed';
          }
          if (submit === accountButton && window.__campusSubmitAttempt?.accountObserved && !window.__campusSubmitAttempt.accountRequestStarted) {
            window.__campusSubmitAttempt.failed = true;
            return 'submission-unconfirmed';
          }
          return 'submitted';
        })()
        """.replacingOccurrences(of: "  /*CAMPUS_AGREEMENTS*/", with: agreementScript)
            .replacingOccurrences(of: "  /*CAMPUS_ACCOUNT*/", with: accountScript)
            .replacingOccurrences(of: "  /*CAMPUS_GPORTAL*/", with: gportalScript)
        return try inContext(script, profile: profile)
    }
    static let gportalScript = #"""
      // Supplied Gportal template: the input label is "登 录" (NBSP). Select its
      // exact form/control and let the school's original login()/AES path submit.
      const gportalStatus = (() => {
        if (!gportalForm || !gportalButton || !cfg.submit) return null;
        const jq = window.jQuery;
        const iv = gportalForm.querySelector('input#iv[name="iv"]');
        if (typeof window.login !== 'function' || typeof window.cryptoEncode !== 'function' ||
            typeof window.CryptoJS?.AES?.encrypt !== 'function' || !iv?.value ||
            typeof jq?.fn?.on !== 'function') return 'waiting-ready';
        const state = window.__campusSubmitAttempt ||= {};
        if (state.gportalObserved) return null;
        const requests = new WeakSet();
        const expectedOrigin = cfg.origin;
        jq(document).on('ajaxSend.campusGportal', (_event, xhr, settings) => {
          if (!window.__campusSubmitted || String(settings.type).toUpperCase() !== 'POST') return;
          let url;
          try { url = new URL(settings.url, location.href); } catch (_) { return; }
          if (url.origin !== expectedOrigin || url.pathname !== '/gportal/web/authLogin') return;
          requests.add(xhr); state.gportalRequestStarted = true; state.result = null;
        });
        jq(document).on('ajaxComplete.campusGportal', (_event, xhr) => {
          if (!requests.has(xhr)) return;
          requests.delete(xhr);
          if (xhr.status < 200 || xhr.status >= 300) {
            state.result = xhr.status === 0 || [408,429].includes(xhr.status) || xhr.status >= 500 ? 'request-error' : 'fail';
            return;
          }
          let result = xhr.responseJSON;
          if (!result) { try { result = JSON.parse(xhr.responseText); } catch (_) { return; } }
          if (typeof result?.status === 'number') state.result = result.status === 1 ? 'success' : 'fail';
        });
        state.gportalObserved = true;
        return null;
      })();
      if (gportalStatus) return gportalStatus;
    """#
    static let accountScript = #"""
      // The supplied account portal loads its password rules asynchronously.
      // Observe its original jQuery requests; never replace validation or submit APIs.
      const accountStatus = (() => {
        if (!cfg.submit || !accountButton || user.id !== 'username' || pass.id !== 'password' || pass.form?.id !== 'my-form') return null;
        const jq = window.jQuery;
        if (typeof passwordRuleScope !== 'object' || passwordRuleScope === null ||
            !['0','1',0,1].includes(passwordRuleScope.portal_auth) ||
            (passwordRuleScope.portal_auth == '1' && (typeof passwordConfig !== 'object' || passwordConfig === null)) ||
            typeof postData !== 'object' || postData === null || typeof host_url !== 'string' ||
            typeof window.doAuthCheck !== 'function' || typeof window.doPortalLogin !== 'function' ||
            typeof jq?.fn?.on !== 'function') return 'waiting-ready';
        const params = new URLSearchParams(location.search);
        if (((params.get('wlanuserip') || params.get('ip')) && !postData.userIpv4) ||
            (params.get('mac') && !postData.userMac)) return 'waiting-ready';
        const state = window.__campusSubmitAttempt ||= {};
        if (state.accountObserved) return null;
        const endpoint = value => {
          if (typeof value !== 'string' || !value) return null;
          try { const url = new URL(value, location.href); url.hash = ''; return url.href; } catch (_) { return null; }
        };
        const stages = new Map();
        for (const [stage, value] of [['password-check', host_url + '/account/check'], ['portal-login', host_url + '/account/login'],
            ['auth-sync', window.dxzAuthApiUrl], ['auth-check', window.dxzCheckApiUrl]]) {
          const url = endpoint(value);
          if (url) stages.set(url, stage);
        }
        const requests = new WeakMap();
        jq(document).on('ajaxSend.campusAccount', (_event, xhr, settings) => {
          if (!window.__campusSubmitted || String(settings.type).toUpperCase() !== 'POST') return;
          const stage = stages.get(endpoint(settings.url));
          if (!stage) return;
          requests.set(xhr, stage); state.accountRequestStarted = true;
          state.result = null; state.failureCode = ''; state.accountStage = stage;
        });
        jq(document).on('ajaxComplete.campusAccount', (_event, xhr) => {
          const stage = requests.get(xhr);
          if (!stage) return;
          requests.delete(xhr);
          if (xhr.status < 200 || xhr.status >= 300) {
            // Optional prechecks deliberately fall through on network errors.
            if (stage === 'password-check' || stage === 'portal-login') state.result = 'request-error';
            return;
          }
          let result = xhr.responseJSON;
          if (!result) { try { result = JSON.parse(xhr.responseText); } catch (_) { return; } }
          if (!result || typeof result !== 'object') return;
          if (stage === 'portal-login' && result.code === 0) { state.result = 'success'; return; }
          if (stage === 'portal-login' && result.code === 2) { state.result = 'captcha'; return; }
          const rejected = stage === 'portal-login' ? result.code === 1 || (result.code !== 0 && result.code !== 2 && !!result.msg) :
            stage === 'password-check' ? result.code === 1 : result.code !== 1 && result.code !== -1 && !!result.msg;
          if (rejected) {
            state.result = 'fail'; state.accountStage = stage;
            // Retain only a bounded error identifier, never response text or credentials.
            state.failureCode = typeof result.msg === 'string' ? result.msg.match(/\bE[0-9]{4,8}\b/)?.[0] || '' : '';
          }
        });
        state.accountObserved = true;
        return null;
      })();
      if (accountStatus) return accountStatus;
    """#
    static let agreementScript = #"""
      // Activate required login checkboxes through school handlers.
      // The caller has already checked network/origin and identified the login inputs.
      {
        const root = pass.form || document;
        const attempted = window.__campusAgreementAttempts ||= new WeakMap();
        const candidates = [...root.querySelectorAll('input[type="checkbox"],[role="checkbox"]')]
          .filter(box => box instanceof HTMLInputElement ? box.type === 'checkbox' : box.getAttribute?.('role') === 'checkbox');
        for (const box of candidates) {
          if (box.form && box.form !== pass.form) continue;
          const labels = [...(box.labels || [])];
          const wrapper = box.closest('label,[role=checkbox],.checkbox,.agreement,.protocol');
          if (wrapper && !labels.includes(wrapper)) labels.push(wrapper);
          for (const id of (box.getAttribute('aria-labelledby') || '').split(/\s+/)) {
            const label = document.getElementById(id);
            if (label) labels.push(label);
          }
          const text = [box.getAttribute('aria-label'), ...labels.map(label => label.textContent),
            box.getAttribute('role') === 'checkbox' ? box.textContent : '', box.id, box.name].join(' ');
          if (/记住|自动登录|保持登录|订阅|推广|广告|促销|营销|优惠|newsletter|marketing|remember|stay\s+signed/i.test(text)) continue;
          const agreement = /同意|已阅读|阅读并|服务(?:使用)?协议|用户协议|隐私政策|使用条款|\bagree\b|\baccept\b|\bterms\b|\bprivacy\b/i.test(text);
          if (!box.required && box.getAttribute('aria-required') !== 'true' && !agreement) continue;
          if (!visible(box) && !labels.some(visible)) continue;
          const checked = () => box instanceof HTMLInputElement ? box.checked : box.getAttribute('aria-checked') === 'true';
          if (checked()) continue;
          if (box.disabled || box.getAttribute('aria-disabled') === 'true') return 'agreement-required';
          const previous = attempted.get(box);
          if (previous) return Date.now() - previous.started < 2000 ? 'waiting-agreement' : 'agreement-required';
          attempted.set(box, { started: Date.now() });
          box.click();
          if (!checked()) return 'waiting-agreement';
        }
      }
    """#
}
