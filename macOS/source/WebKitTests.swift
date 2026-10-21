import AppKit
import WebKit

// Offline tests use invented credentials and inline pages; no school requests.
@main struct WebKitTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await Runner().run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            fputs("FAIL: native WebKit test timed out\n", stderr); exit(1)
        }
        app.run()
    }
}

@MainActor final class Runner: NSObject, WKNavigationDelegate {
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
    var navigation: CheckedContinuation<Void, Error>?
    var checks = 0
    let fixture = """
    <html><body>
    <input id="username_tip" readonly value="Username"><input id="username" type="text" style="display:none">
    <input id="pwd_tip" readonly value="Password"><input id="pwd" type="password" style="display:none">
    <a id="loginLink" tabindex="-1" onclick="doauthen()"><div style="width:275px;height:54px;background:blue"></div></a>
    <script>
    window.loginCalls=0; window.handlerCalls=0;
    window.AuthInterFace={login(){loginCalls++}};
    function doauthen(){handlerCalls++;AuthInterFace.login()}
    for(const id of ['username','pwd']){
      const input=document.getElementById(id),tip=document.getElementById(id+'_tip');
      tip.onfocus=()=>{input.style.display='';input.focus();tip.style.display='none'};
      input.onblur=()=>{if(!input.value){input.style.display='none';tip.style.display=''}};
    }
    </script></body></html>
    """
    func expect(_ value: Bool, _ message: String) throws {
        checks += 1
        if !value { throw AppError.message(message) }
    }
    func load(html: String? = nil) async throws {
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigation = continuation
            view.loadHTMLString(html ?? fixture, baseURL: URL(string: "http://portal.test/eportal/index.jsp"))
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.navigation?.resume(); self.navigation = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.navigation?.resume(throwing: error); self.navigation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.navigation?.resume(throwing: error); self.navigation = nil
    }
    @discardableResult func js(_ script: String) async throws -> Any {
        try await view.evaluateJavaScript(script) ?? NSNull()
    }
    func fill(submit: Bool = true, origin: String = "http://portal.test", service: String = "") async throws -> String {
        var profile = CampusProfile()
        profile.serviceOption = service
        profile.portalURL = origin; profile.username = "dummy-user"; profile.autoSubmit = submit
        return try await js(PortalScript.build(profile: profile, password: "dummy-password")) as? String ?? "nil"
    }
    func pump(service: String = "") async throws -> String {
        var result = ""
        for _ in 0..<20 {
            result = try await fill(service: service)
            if !["waiting-submit", "waiting-ready", "waiting-agreement"].contains(result) { return result }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return result
    }
    func run() async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        if let entry = ProcessInfo.processInfo.environment["CAMPUS_FRAME_TEST_URL"], let url = URL(string: entry) {
            view.navigationDelegate = self
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                navigation = continuation; view.load(URLRequest(url: url))
            }
            for _ in 0..<50 {
                if (try? await js("!!window.frames[0]?.document.querySelector('#pwd')")) as? Bool == true { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            var profile = CampusProfile(); profile.portalURL = entry; profile.username = "dummy-user"; profile.autoSubmit = true
            let script = try PortalScript.build(profile: profile, password: "dummy-password")
            try expect(try await js(script) as? String == "manual-required", "native frame placeholder blocks submission")
            try expect(try await js("window.frames[0].document.querySelector('#username').value") as? String == "dummy-user", "native frame account filled")
            try expect(try await js("window.frames[0].document.querySelector('#pwd').value") as? String == "dummy-password", "native frame password uses child realm")
            try expect(try await js("window.frames[0].reveals") as? Int == 1, "native frame prompt uses school click")
            try expect(try await js("window.frames[0].loginCalls") as? Int == 0, "native frame never submits missing code")
            try expect(try await js("window.frames[0].document.querySelector('#autocheckbox').checked") as? Bool == false, "native frame remember option stays unchecked")
            try await js("window.frames[0].document.querySelector('#ps').value='aB7Z12';true")
            try expect(try await js(script) as? String == "submitted", "native frame original login button clicked")
            try expect(try await js("window.frames[0].loginCalls") as? Int == 1, "native frame school handler submitted once")
            try expect(try await js(script) as? String == "already-submitted", "native frame deduplicates submission")
        }

        let captchaPage = """
        <form><input name="username"><input type="password">
        <input name="captcha" placeholder="校验码不区分大小写" maxlength="4">
        <button type="submit">登录</button></form>
        <script>window.codes=[];document.querySelector('form').onsubmit=e=>{e.preventDefault();codes.push(document.querySelector('[name=captcha]').value)}</script>
        """
        try await load(html: captchaPage)
        try expect(try await fill() == "manual-required", "empty generic CAPTCHA waits for user")
        try expect(try await js("codes.length") as? Int == 0, "empty CAPTCHA never submits")
        try expect(try await js("document.querySelector('[name=captcha]').value") as? String == "", "CAPTCHA not overwritten by credentials")
        try await js("document.querySelector('[name=captcha]').value='aB7Z'")
        try expect(try await fill() == "submitted", "manual alphanumeric CAPTCHA submits")
        try expect(try await js("JSON.stringify(codes)") as? String == "[\"aB7Z\"]", "CAPTCHA case preserved")
        try expect(try await fill() == "already-submitted", "manual CAPTCHA submission deduplicated")
        try await load(html: captchaPage)
        try expect(try await fill(submit: false) == "filled", "manual mode leaves empty CAPTCHA for user")
        try expect(try await js("codes.length") as? Int == 0, "manual mode never submits CAPTCHA")
        let cmcc = try String(contentsOf: source.appendingPathComponent("../../Windows/tests/fixtures/cmcc-font-radio.html"), encoding: .utf8)
        try await load(html: cmcc)
        try expect(try await fill(service: "中国移动") == "submitted", "FONT-labelled operator submits")
        try expect(try await js("document.querySelector('[name=network]:checked').value") as? String == "@cmcc", "actual operator fragment selects cmcc")
        try expect(try await js("selectionAtSubmit") as? String == "@cmcc", "operator selected before login")
        try expect(try await js("JSON.stringify(operatorEvents)") as? String == "[\"click\",\"input\",\"change\"]", "school radio events preserved")
        try expect(try await fill(service: "中国移动") == "already-submitted", "operator login deduplicated")
        try expect(try await js("clicks") as? Int == 1, "one login for FONT operator")
        try await load(html: cmcc)
        try expect(try await fill(submit: false, service: "中国移动") == "filled", "manual submit still selects operator")
        try expect(try await js("clicks") as? Int == 0, "manual operator selection does not log in")
        try expect(try await fill(submit: false, service: "中国移动") == "filled", "selected radio not clicked repeatedly")
        try expect(try await js("operatorEvents.length") as? Int == 3, "one sequence of radio events")
        let native = """
        <form><input name="username"><input type="password"><button type="button" onclick="window.clicks++">登录</button></form>
        <select id="operator"><option value="">选择运营商</option><option value="cmcc">中国移动</option><option value="custom">校园专线 A</option></select>
        <script>window.clicks=0</script>
        """
        try await load(html: native)
        try expect(try await fill() == "service-required", "placeholder without configured operator requires input")
        try expect(try await js("clicks") as? Int == 0, "placeholder never submits")
        try expect(try await fill(service: "校园专线 A") == "submitted", "custom service outside login form selected")
        try expect(try await js("document.getElementById('operator').value") as? String == "custom", "custom option confirmed")
        let lazy = """
        <form><input name="username"><input type="password"><button type="button" onclick="window.clicks++">登录</button></form>
        <button role="combobox" id="choose" aria-controls="operator-options" aria-expanded="false">选择运营商</button>
        <script>
        window.clicks=0;window.opens=0;
        document.getElementById('choose').onclick=function(){opens++;this.setAttribute('aria-expanded','true')};
        window.populate=function(){document.body.insertAdjacentHTML('beforeend','<ul role="listbox" id="operator-options"><li role="option">校园专线 A</li></ul>');document.querySelector('[role=option]').onclick=function(){document.getElementById('choose').textContent=this.textContent;document.getElementById('operator-options').hidden=true}};
        </script>
        """
        try await load(html: lazy)
        try expect(try await fill(service: "校园专线 A") == "missing-service", "open menu before delayed choices")
        try expect(try await fill(service: "校园专线 A") == "missing-service", "wait without toggling menu")
        try expect(try await js("opens") as? Int == 1, "dynamic menu opens once")
        try await js("populate();true")
        try expect(try await fill(service: "校园专线 A") == "submitted", "late custom choice resumes login")
        try expect(try await js("clicks") as? Int == 1, "dynamic choice logs in once")
        try await load()
        // Simulate a first programmatic click that never reaches the school's handler.
        try await js("document.getElementById('loginLink').click=()=>{}; true")
        let first = try await fill()
        try expect(first != "submitted", "a lost first click must not be reported as submitted")
        let recovered = try await pump()
        try expect(recovered == "submitted", "lost click recovers through the existing page event")
        try expect(try await js("loginCalls") as? Int == 1, "exactly one school login after recovery")
        try expect(try await fill() == "already-submitted", "successful submission is deduplicated")
        try expect(try await js("loginCalls") as? Int == 1, "no repeated credential request")

        try await load()
        try expect(try await fill() == "waiting-submit", "fill and submit occur on separate turns")
        try expect(try await js("loginCalls") as? Int == 0, "first turn only fills and prepares")
        try expect(try await pump() == "submitted", "normal native WebKit submission")
        try expect(try await js("handlerCalls") as? Int == 1, "normal handler invoked once")

        try await load()
        try await js("doauthen=function(){handlerCalls++;setTimeout(()=>AuthInterFace.login(),300)}; true")
        let asyncResult = try await pump()
        try expect(["submitted", "already-submitted"].contains(asyncResult), "wait for asynchronous school handoff")
        try expect(try await js("handlerCalls") as? Int == 1, "asynchronous handler is never clicked twice")

        try await load()
        try await js("doauthen=function(){handlerCalls++;document.body.dataset.validation='manual-required'}; true")
        _ = try await fill(); _ = try await fill()
        try await js("window.__campusSubmitAttempt.startedAt-=10000")
        try expect(try await fill() == "submission-unconfirmed", "page validation does not falsely count as submitted")
        try expect(try await js("handlerCalls") as? Int == 1, "do not repeat a handler that already ran")
        try expect(try await js("loginCalls") as? Int == 0, "validation does not send credentials")

        try await load()
        try await js("window.doauthen=undefined; true")
        try expect(try await fill() == "waiting-ready", "wait for a late login handler")
        try await js("window.doauthen=function(){handlerCalls++;AuthInterFace.login()}; true")
        try expect(try await pump() == "submitted", "late handler can complete first login")

        try await load()
        try await js("doauthen=function(){handlerCalls++;throw Error('fixture not ready')}; true")
        try expect(try await pump() == "submission-unconfirmed", "school handler exception does not report submission")
        try expect(try await js("loginCalls") as? Int == 0, "failed handler sends no request")
        try expect(try await fill() == "submission-unconfirmed", "failed handler is not repeatedly activated")

        try await load()
        try await js("AuthInterFace.login=function(){throw Error('fixture login failed')}; true")
        try expect(try await pump() == "submission-unconfirmed", "synchronous login failure is not reported as submitted")

        try await load()
        try await js("document.body.insertAdjacentHTML('beforeend','<input id=validCode>'); true")
        try expect(try await fill() == "manual-required", "captcha retains manual interaction")
        try expect(try await js("loginCalls") as? Int == 0, "no login with empty captcha")

        try await load()
        try await js("document.getElementById('loginLink').disabled=true")
        try expect(try await fill() == "missing-submit", "disabled button is not activated")
        try await js("document.getElementById('loginLink').disabled=false")
        try expect(try await pump() == "submitted", "button enabling resumes first submission")

        try await load()
        try expect(try await fill(submit:false) == "filled", "manual-only setting is respected")
        try expect(try await js("loginCalls") as? Int == 0, "manual-only never clicks")
        try await load()
        try expect(try await fill(origin:"http://other.test") == "wrong-origin", "origin guard retained")
        try expect(try await js("document.getElementById('pwd').value") as? String == "", "foreign origin receives no password")
        // Real WebKit verifies service selection before the two-stage ePortal submit.
        try await load()
        try await js("""
          document.body.insertAdjacentHTML('beforeend', '<input id="net_access_type" type="hidden"><div id="serviceShowHideTop"><span id="selectDisname">请选择服务</span></div><div id="serviceShowHide" style="display:none"><div id="bch_service_0"><div><div id="_service_0">联通接入服务</div></div></div></div>');
          window.serviceClicks=0;window.menuOpens=0;
          document.getElementById('serviceShowHideTop').onclick=()=>{menuOpens++;document.getElementById('serviceShowHide').style.display='block'};
          document.getElementById('bch_service_0').onclick=()=>{serviceClicks++;document.getElementById('net_access_type').value='unicom';document.getElementById('selectDisname').textContent='联通接入服务';document.getElementById('serviceShowHide').style.display='none'};
          true
        """)
        try expect(try await pump(service:"联通接入服务") == "submitted", "ePortal service selected before submit")
        try expect(try await js("document.getElementById('net_access_type').value") as? String == "unicom", "school service handler updates internal value")
        try expect(try await js("serviceClicks") as? Int == 1, "service handler invoked once")
        try expect(try await js("loginCalls") as? Int == 1, "service selection preserves confirmed one-time login")

        try await load()
        try await js("document.body.insertAdjacentHTML('beforeend','<select id=service><option value=empty>请选择服务</option><option value=unicom>联通接入服务</option></select>');true")
        try expect(try await fill(submit:false,service:"  联通接入服务  ") == "filled", "native select accepts exact trimmed display name")
        try expect(try await js("document.getElementById('service').value") as? String == "unicom", "native service selected")
        try expect(try await js("loginCalls") as? Int == 0, "manual mode does not login after selection")
        try expect(try await fill(service:"不存在") == "missing-service", "wrong service stops login")
        try expect(try await js("loginCalls") as? Int == 0, "missing service never submits default")

        try await load()
        try await js("document.body.insertAdjacentHTML('beforeend','<select id=service><option value=empty>请选择服务</option></select>');true")
        try expect(try await fill(service:"联通接入服务") == "missing-service", "wait for delayed service")
        try await js("document.getElementById('service').add(new Option('联通接入服务','unicom'));true")
        try expect(try await pump(service:"联通接入服务") == "submitted", "delayed option resumes login")

        try await load()
        try expect(try await fill(service:"联通接入服务") == "missing-service", "configured service without control requires attention")
        try expect(try await pump() == "submitted", "blank service supports pages without service selector")
        // A blue focused button with both activation events lost still uses
        // the school's own validation/login function, exactly once.
        try await load()
        try await js("const b=document.getElementById('loginLink');b.click=()=>{};b.dispatchEvent=()=>true;true")
        try expect(try await pump() == "submitted", "lost activation falls back to school handler")
        try expect(try await js("handlerCalls") as? Int == 1, "fallback invokes handler once")
        try expect(try await js("loginCalls") as? Int == 1, "fallback sends one request")
        var statusProfile = CampusProfile()
        statusProfile.portalURL = "http://portal.test"
        let statusScript = try PortalScript.build(profile: statusProfile, password: "", statusOnly: true)
        try expect(try await js(statusScript) as? String == "awaiting-authentication", "request alone is not successful authentication")
        try await load()
        try await js("AuthInterFace.login=function(...args){loginCalls++;window.reply=args.at(-1)};doauthen=function(){handlerCalls++;AuthInterFace.login('dummy',function(r){window.originalResult=r.result;return 42})};true")
        _ = try await pump()
        try expect(try await js(statusScript) as? String == "awaiting-authentication", "wait for response")
        try expect(try await js("reply({result:'success'})") as? Int == 42, "original callback return preserved")
        try expect(try await js(statusScript) as? String == "authenticated", "school response confirms authentication")
        try expect(try await js("originalResult") as? String == "success", "original callback still runs")
        try await load()
        try await js("AuthInterFace.login=function(...args){loginCalls++;window.reply=args.at(-1)};doauthen=function(){handlerCalls++;AuthInterFace.login('dummy',function(r){window.originalResult=r.result})};true")
        _ = try await pump()
        try await js("reply({result:'fail'});true")
        try expect(try await js(statusScript) as? String == "authentication-rejected", "rejection is not success")
        try expect(try await fill() == "authentication-rejected", "rejection never resubmits")
        try expect(try await js("loginCalls") as? Int == 1, "rejection has one request")
        try await load()
        try await js("document.body.insertAdjacentHTML('beforeend', '<label><input id=terms type=checkbox required onclick=\"window.termClicks=(window.termClicks||0)+1\">我已阅读并同意用户协议</label><label><input id=remember type=checkbox>记住密码</label>');true")
        try expect(try await pump() == "submitted", "native WebKit checks terms before login")
        try expect(try await js("document.getElementById('terms').checked") as? Bool == true, "required terms checked")
        try expect(try await js("termClicks") as? Int == 1, "page checkbox event runs once")
        try expect(try await js("document.getElementById('remember').checked") as? Bool == false, "remember password unchanged")
        try expect(try await fill() == "already-submitted", "agreement login deduplicated")
        try expect(try await js("termClicks") as? Int == 1, "no repeated term clicks")
        try await load()
        try await js("document.body.insertAdjacentHTML('beforeend', '<label><input id=terms type=checkbox required disabled>同意协议</label>');true")
        try expect(try await fill() == "agreement-required", "disabled agreement blocks submission")
        try expect(try await js("loginCalls") as? Int == 0, "disabled agreement does not send credentials")
        try await load()
        try await js("document.body.insertAdjacentHTML('beforeend', '<label><input id=terms type=checkbox required>同意协议</label>');document.getElementById('terms').onclick=event=>event.preventDefault();true")
        try expect(try await fill() == "waiting-agreement", "rejected click awaits page confirmation")
        try await js("window.__campusAgreementAttempts.get(document.getElementById('terms')).started-=3000;true")
        try expect(try await fill() == "agreement-required", "rejected agreement becomes manual")
        try expect(try await js("loginCalls") as? Int == 0, "rejected agreement never logs in")
        try await load()
        try await js("document.body.insertAdjacentHTML('beforeend', '<label><input id=terms type=checkbox required>同意协议</label>');document.getElementById('terms').onclick=event=>{event.preventDefault();setTimeout(()=>document.getElementById('terms').checked=true,100)};true")
        try expect(try await fill() == "waiting-agreement", "asynchronous terms wait")
        try expect(try await pump() == "submitted", "asynchronous terms resume login")
        try expect(try await js("loginCalls") as? Int == 1, "asynchronous terms submit once")
        try await load()
        try await js("document.body.insertAdjacentHTML('beforeend', '<span id=terms role=checkbox aria-required=true aria-checked=false tabindex=0>同意协议</span>');document.getElementById('terms').onclick=function(){this.setAttribute('aria-checked','true')};true")
        try expect(try await pump() == "submitted", "ARIA checkbox handled natively")
        try expect(try await js("document.getElementById('terms').getAttribute('aria-checked')") as? String == "true", "ARIA terms confirmed")
        print("PASS: \(checks) native WKWebView checks (first click, handler readiness, asynchronous handoff, deduplication, manual mode, origin and service selection).")
    }
}
