import AppKit
import SwiftUI
import WebKit
import Network

final class PortalController: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var message = "连接校园网后，在这里完成上网认证。"
    @Published var address = ""
    @Published var loading = false
    var requiresInteraction = false
    var isAuthenticating: Bool { authenticationDeadline != nil || (!submitted && !filled && !requiresInteraction && fillingGeneration == generation) }
    var onSubmission: (() -> Void)?
    var onAuthentication: (() -> Void)?
    private var profile: CampusProfile?
    private var password = ""
    private var generation = 0
    private var submitted = false
    private var filled = false
    private var fillingGeneration: Int?
    private var preparing = false
    private var authenticationDeadline: Date?
    private var observingGeneration: Int?
    private var authenticationConfirmed = false
    private var internetConfirmed = false
    private let fillWiFi = WiFiService()
    private let campusProxy = CampusProxy()

    override init() {
        let config = WKWebViewConfiguration()
        // An isolated browser session keeps campus authentication separate from Safari.
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func open(profile: CampusProfile, password: String, discoveryHost: String? = nil) {
        generation += 1
        let expected = generation
        preparing = true
        webView.stopLoading()
        fillWiFi.readConnection(profile: profile) { [weak self] connected in
            guard let self, expected == self.generation else { return }
            guard connected else {
                self.preparing = false; self.message = profile.isWired ? "请先插好网线并启用有线网络，再打开认证页。" : "请先连接 \(profile.ssid)，再打开认证页。"; return
            }
            self.load(profile: profile, password: password, discoveryHost: discoveryHost)
        }
    }
    private func load(profile: CampusProfile, password: String, discoveryHost: String?) {
        requiresInteraction = !profile.autoSubmit
        submitted = false; filled = false; authenticationDeadline = nil; authenticationConfirmed = false; internetConfirmed = false
        self.profile = profile; self.password = password
        let url = profile.validPortalURL ?? URL(string: "http://captive.apple.com/hotspot-detect.html")!
        webView.configuration.userContentController.removeAllUserScripts()
        if let origin = PortalScript.origin(url),
           let resource = Bundle.main.url(forResource: "PortalBootstrap", withExtension: "js"),
           let bootstrap = try? String(contentsOf: resource, encoding: .utf8),
           let json = try? JSONSerialization.data(withJSONObject: origin, options: [.fragmentsAllowed]) {
            let script = bootstrap.replacingOccurrences(of: "/*CAMPUS_ORIGIN*/", with: String(decoding: json, as: UTF8.self))
            webView.configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        loading = true
        message = profile.validPortalURL == nil ? "正在探测认证页…" : "正在打开校园网认证页…"
        let expected = generation
        guard let host = url.host else { message = "认证地址无效。"; return }
        let extra = discoveryHost.map { Set([$0]) } ?? []
        let selectedName = profile.isWired ? WiredSystem.selected(profile, from: WiredSystem.interfaces())?.name : nil
        let selectedInterface = WiredNetwork.shared.interfaces.first { $0.name == selectedName }
        if profile.isWired && selectedInterface == nil {
            preparing = false; loading = false; message = "所选以太网接口尚未就绪，请等待获取地址后重试。"; return
        }
        campusProxy.start(host: host, additionalHosts: extra, interfaceType: profile.isWired ? .wiredEthernet : .wifi, requiredInterface: selectedInterface) { [weak self] result in
            guard let self, expected == self.generation else { return }
            switch result {
            case .success(let port):
                self.webView.configuration.websiteDataStore.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))]
                self.preparing = false
                self.webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
            case .failure(let error): self.loading = false; self.message = "校园直连初始化失败：\(error.localizedDescription)"
            }
        }
    }

    func stop() {
        generation += 1
        profile = nil; password = ""; submitted = false; filled = false; requiresInteraction = false; authenticationDeadline = nil; authenticationConfirmed = false; internetConfirmed = false
        webView.stopLoading(); loading = false
        campusProxy.stop()
        message = "认证已暂停。"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        generation += 1; loading = true
        if authenticationDeadline != nil { observeAuthentication() }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { startFilling() }
    private func startFilling() {
        guard !preparing, fillingGeneration != generation, !submitted, !filled else { return }
        fillingGeneration = generation
        attemptFill(generation: generation, attempt: 0)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        address = webView.url?.absoluteString ?? ""
        guard !preparing, let profile else { return }
        guard let allowed = profile.validPortalURL else {
            message = "请确认下方页面是学校认证页，再使用当前地址保存配置。"; return
        }
        if authenticationDeadline != nil { observeAuthentication(); return }
        // Also recognize a successful manual login after automatic filling stopped.
        if let current = webView.url, PortalScript.origin(current) == PortalScript.origin(allowed),
           current.path == "/eportal/success.jsp",
           URLComponents(url: current, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "userIndex" && !($0.value ?? "").isEmpty }) == true {
            let expected = generation
            fillWiFi.readConnection(profile: profile) { [weak self] connected in
                guard let self, expected == self.generation, connected else { return }
                self.confirmAuthentication()
            }
            return
        }
        if !submitted { startFilling() }
    }

    func confirmInternetAccess() {
        internetConfirmed = true; requiresInteraction = false
        authenticationDeadline = nil; submitted = true; filled = true; password = ""
        message = "已经连接成功"
    }
    func reportInternetUnavailable() { internetConfirmed = false; message = "未连接网络" }
    private func confirmAuthentication() {
        guard !authenticationConfirmed else { return }
        authenticationConfirmed = true; authenticationDeadline = nil
        submitted = true; filled = true; password = ""; requiresInteraction = false
        if !internetConfirmed { message = "学校已确认登录成功，正在检查实际联网状态。" }
        onAuthentication?()
    }
    private func observeAuthentication() {
        guard authenticationDeadline != nil, observingGeneration != generation else { return }
        observingGeneration = generation
        pollAuthentication(expected: generation)
    }
    private func pollAuthentication(expected: Int) {
        guard expected == generation, let profile, let deadline = authenticationDeadline else { return }
        fillWiFi.readConnection(profile: profile) { [weak self] connected in
            guard let self, expected == self.generation else { return }
            guard connected else { self.stop(); self.message = "校园网已断开，停止登录校验。"; return }
            let next: (String?) -> Void = { [weak self] status in
                guard let self, expected == self.generation, self.authenticationDeadline != nil else { return }
                if status == "authenticated" { self.confirmAuthentication(); return }
                if status == "authentication-rejected" {
                    self.authenticationDeadline = nil; self.requiresInteraction = true
                    self.message = "学校返回登录失败，请查看网页提示并检查账号、密码和服务选项。"; return
                }
                if Date() >= deadline {
                    self.authenticationDeadline = nil; self.requiresInteraction = true
                    self.message = "30 秒内未确认已登录页面或学校成功结果，正在复查联网状态；仍未联网时请查看网页提示后重试。"
                    self.onSubmission?(); return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.pollAuthentication(expected: expected) }
            }
            guard let current = self.webView.url, let allowed = profile.validPortalURL,
                  PortalScript.origin(current) == PortalScript.origin(allowed),
                  let script = try? PortalScript.build(profile: profile, password: "", statusOnly: true) else { next(nil); return }
            self.webView.evaluateJavaScript(script) { result, _ in next(result as? String) }
        }
    }

    private func attemptFill(generation expected: Int, attempt: Int) {
        guard expected == generation, !submitted, !filled, let profile else { return }
        fillWiFi.readConnection(profile: profile) { [weak self] connected in
            guard let self, expected == self.generation, !self.submitted, !self.filled else { return }
            guard connected else { self.message = "校园网已断开，暂停填写。"; return }
            self.evaluateFill(profile: profile, expected: expected, attempt: attempt)
        }
    }
    private func evaluateFill(profile: CampusProfile, expected: Int, attempt: Int) {
        guard let allowed = profile.validPortalURL, let current = webView.url,
              PortalScript.origin(allowed) == PortalScript.origin(current) else {
            message = "页面地址与保存的认证地址不同，请确认后更新地址。"; return
        }
        guard !profile.username.isEmpty, !password.isEmpty else {
            message = "请在校园网设置中保存学号 / 账号和密码。"; return
        }
        do {
            let script = try PortalScript.build(profile: profile, password: password)
            webView.evaluateJavaScript(script) { [weak self] result, error in
                guard let self, expected == self.generation else { return }
                let status = result as? String
                if PortalFillRetry.shouldRetry(result: status, scriptFailed: error != nil, attempt: attempt) {
                    self.message = status == "waiting-agreement" ? "正在等待网页确认必选框和协议项…" : status == "waiting-submit" ? "账号密码已填写，正在等待学校页面处理登录…" : "正在等待认证页面就绪…"
                    DispatchQueue.main.asyncAfter(deadline: .now() + PortalFillRetry.delay) { [weak self] in
                        self?.attemptFill(generation: expected, attempt: attempt + 1)
                    }
                    return
                }
                if error != nil {
                    self.requiresInteraction = true; self.filled = true; self.password = ""
                    self.message = "页面脚本暂未就绪，请点击立即认证重试，或在页面手动登录。"; return
                }
                switch status {
                case "authenticated": self.confirmAuthentication()
                case "authentication-rejected":
                    self.requiresInteraction = true; self.filled = true; self.password = ""
                    self.message = "学校返回登录失败，请查看网页提示并检查账号、密码和服务选项。"
                case "submitted", "already-submitted":
                    self.submitted = true; self.password = ""; self.requiresInteraction = true
                    self.authenticationDeadline = Date().addingTimeInterval(30)
                    self.message = "已触发登录，正在核验学校返回结果和已登录页面…"
                    self.onSubmission?(); self.observeAuthentication()
                case "filled": self.requiresInteraction = true; self.filled = true; self.password = ""; self.message = "账号密码已填写，请在页面点击登录。"
                case "missing-submit": self.requiresInteraction = true; self.filled = true; self.password = ""; self.message = "账号密码已填写，未识别登录按钮，请在网页中手动点击登录。"
                case "missing-service": self.requiresInteraction = true; self.filled = true; self.password = ""; self.message = "未找到或未能选中填写的服务选项，请检查完整名称或在网页中手动选择。网页没有选项时，请清空设置中的服务选项。"
                case "service-required": self.requiresInteraction = true; self.filled = true; self.password = ""; self.message = "认证页尚未选择运营商或服务。请在设置的“运营商 / 服务选项”中填写网页上的完整名称（如中国移动），保存后重新认证；也可在网页中手动选择并登录。"
                case "waiting-agreement", "agreement-required": self.requiresInteraction = true; self.filled = true; self.password = ""; self.message = "网页必选框或协议项无法自动确认，请在页面手动勾选后登录。"
                case "manual-required": self.requiresInteraction = true; self.filled = true; self.password = ""; self.message = "请在学校网页中手动输入验证码（支持英文字母和数字），核对后点击登录；如需运营商信息也请补充。"
                case "waiting-submit", "submission-unconfirmed":
                    self.requiresInteraction = true; self.filled = true; self.password = ""
                    self.message = "学校页面尚未确认提交，请查看页面提示；可点击立即认证重试或手动登录。"
                case "waiting-ready": self.requiresInteraction = true; self.filled = true; self.password = ""; self.message = "学校认证参数尚未就绪，请检查页面后重试。"
                case "invalid-selector": self.requiresInteraction = true; self.message = "认证页面暂时无法识别，请在网页中手动登录。"
                case "wrong-origin": self.requiresInteraction = true; self.message = "认证地址不匹配，已暂停填写。"
                default: self.requiresInteraction = true; self.message = "未识别登录表单，请在网页中手动登录。"
                }
            }
        } catch { message = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        loading = false; message = "认证页打不开：\(error.localizedDescription)"
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false; message = "页面加载失败：\(error.localizedDescription)"
    }
}

struct PortalWebView: NSViewRepresentable {
    let controller: PortalController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
