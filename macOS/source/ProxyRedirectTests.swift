import AppKit
import WebKit
import Network

@main struct ProxyRedirectTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let runner = ProxyRedirectRunner()
        Task { @MainActor in await runner.start() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            fputs("FAIL: native proxy redirect timed out\n", stderr); exit(1)
        }
        app.run()
    }
}

@MainActor private final class ProxyRedirectRunner: NSObject, WKNavigationDelegate {
    let proxy = CampusProxy()
    var view: WKWebView!
    func start() async {
        do {
            let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                proxy.start(interfaceType: .loopback) { continuation.resume(with: $0) }
            }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.websiteDataStore.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy:
                .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))]
            view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: config)
            view.navigationDelegate = self
            view.load(URLRequest(url: URL(string: ProcessInfo.processInfo.environment["CAMPUS_PROXY_REDIRECT_URL"]!)!))
        } catch { fail(error) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView.url?.path == "/final" else { return }
        Task { @MainActor in
            do {
                var entry = CampusProfile()
                entry.portalURL = ProcessInfo.processInfo.environment["CAMPUS_PROXY_REDIRECT_URL"]!
                entry.username = "dummy-user"; entry.autoSubmit = true
                let active = try PortalScript.atCurrentPage(profile: entry, url: webView.url!)
                guard try await webView.evaluateJavaScript(PortalScript.loginFormProbe(profile: active)) as? Bool == true else {
                    throw AppError.message("cross-host dependency did not render the login form")
                }
                guard try await webView.evaluateJavaScript(PortalScript.build(profile: active, password: "dummy-password")) as? String == "submitted",
                      try await webView.evaluateJavaScript("JSON.stringify(observed)") as? String == "[\"dummy-user\",\"dummy-password\"]",
                      try await webView.evaluateJavaScript("loginClicks") as? Int == 1 else {
                    throw AppError.message("redirected native login did not fill and submit once")
                }
                print("PASS: native WKWebView + production campus proxy follows 12 HTTP redirects, script redirect and cross-host login dependencies, then fills and submits once.")
                proxy.stop(); exit(0)
            } catch { fail(error) }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { fail(error) }
    }
    private func fail(_ error: Error) {
        fputs("FAIL: \(error)\n", stderr); proxy.stop(); exit(1)
    }
}
