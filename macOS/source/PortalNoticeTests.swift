import AppKit
import WebKit

@main struct PortalNoticeTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let portal = PortalController()
        var notices: [PortalProblem] = []
        var cleared = 0
        portal.onProblem = { problem in
            if let problem { notices.append(problem) } else { cleared += 1 }
        }
        portal.reportFailure("missing-service", "fixture: service mismatch")
        precondition(portal.requiresInteraction && !portal.loading && !portal.isAuthenticating)
        precondition(notices.count == 1 && notices[0].advice.contains("无法自动填写信息"))
        // A second native callback must not interrupt the user with another dialog.
        portal.reportFailure("load-failed", "fixture: subsequent load error")
        precondition(notices.count == 1)
        portal.confirmInternetAccess()
        precondition(!portal.requiresInteraction && portal.message == "已经连接成功" && cleared == 1)
        portal.stop()
        portal.reportFailure("authentication-rejected", "fixture: rejected login")
        precondition(notices.count == 2 && notices[1].code == "authentication-rejected")
        portal.stop()
        let count = notices.count
        portal.webView(portal.webView, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        portal.webView(portal.webView, didFail: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        precondition(notices.count == count && !portal.loading)
        print("PASS: native PortalController error callback, paused authentication, deduplication, success clearing, retry reset and cancelled navigation.")
    }
}
