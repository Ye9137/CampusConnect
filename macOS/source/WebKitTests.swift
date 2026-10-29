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
    func load(html: String? = nil, baseURL: String = "http://portal.test/eportal/index.jsp") async throws {
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigation = continuation
            view.loadHTMLString(html ?? fixture, baseURL: URL(string: baseURL))
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
        // Older SDK async overlays force-unwrap JavaScript undefined results.
        // The callback API preserves nil so statements remain safe to evaluate.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            view.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value ?? NSNull()) }
            }
        }
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
    func addedSchoolChecks() async throws {
        let form = "<form><input name='username'><input type='password'><button type='button' id='submit' onclick='window.clicks++'>➜</button></form><script>window.clicks=0</script>"
        try await load(html: form)
        try expect(try await fill() == "submitted", "陕西国防 #submit original button clicked")
        try expect(try await js("clicks") as? Int == 1, "school button submits once")
        try expect(try await fill() == "already-submitted", "school button deduplicates")
        try await load(html: form)
        try expect(try await fill(submit: false) == "filled", "school manual fill preserves no-submit mode")
        try expect(try await js("clicks") as? Int == 0, "manual fill never clicks")
        try await load(html: form.replacingOccurrences(of: "id='submit'", with: "id='submit' disabled"))
        try expect(try await fill() == "missing-submit", "disabled school button is not clicked")
        let isolated = "<form><button type='button' id='submit' onclick='window.clicks++'>➜</button></form><form><input name='username'><input type='password'></form><script>window.clicks=0</script>"
        try await load(html: isolated)
        try expect(try await fill() == "missing-submit", "other form submit is excluded")
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let jquery = try String(contentsOf: project.appendingPathComponent("Windows/tests/node_modules/jquery/dist/jquery.min.js"), encoding: .utf8)
        let original = try String(contentsOf: project.appendingPathComponent("Windows/tests/fixtures/gportal-login-handler.js"), encoding: .utf8)
        let html = #"""
        <form id="frmReg"><input name="name" id="register_name"><input type="password"></form>
        <form id="frmLogin"><input type="hidden" id="iv" name="iv" value="fixture-iv"><input type="hidden" name="sign" value="fixture-session"><input type="hidden" id="redirectUrl" value="/done"><input id="first_name" name="name" type="text"><input id="first_password" name="password" type="password"><input type="button" id="first_button" value="登&nbsp;录" onclick="javascript:login()"></form>
        """#
        let setup = #"""
        window.requests=0;window.encryptCalls=0;window.reply={status:1,info:'fixture-ok',data:{redirectUrl:'/done'}};window.CryptoJS={AES:{encrypt(){}}};function cryptoEncode(s){encryptCalls++;window.serialized=s;return {data:'fixture-ciphertext'}}function showWait(){}function closeWait(){}function showmessage(){}function offlinepage(){}function resetpage(){}function bindpage(){};$.ajaxTransport('+*',options=>({send(_headers,done){requests++;done(200,'OK',{text:JSON.stringify(reply)},'Content-Type: application/json')},abort(){}}));
        """#
        let page = html + "<script>" + jquery + "</script><script>" + setup + "</script><script>" + original + "</script>"
        let url = "http://portal.test/gportal/web/index"
        var profile = CampusProfile(); profile.portalURL = url; profile.username = "dummy-user"; profile.autoSubmit = true
        let script = try PortalScript.build(profile: profile, password: "dummy-password")
        try await load(html: page, baseURL: url)
        try expect(try await js(script) as? String == "submitted", "Gportal NBSP button uses original login")
        try expect(try await js("requests") as? Int == 1, "original Gportal request observed")
        try expect(try await js("encryptCalls") as? Int == 1, "original Gportal encryption entry retained")
        try expect(try await js("document.getElementById('register_name').value") as? String == "", "Gportal registration remains blank")
        try expect(try await js(script) as? String == "authenticated", "Gportal success observed")
        try await load(html: page, baseURL: url)
        try await js("reply={status:0,info:'fixture-reject',data:{}}; true")
        try expect(try await js(script) as? String == "submitted", "Gportal rejection uses original request")
        try expect(try await js(script) as? String == "authentication-rejected", "Gportal rejection pauses repeat submission")
    }
    func accountPortalChecks() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let html = try String(contentsOf: project.appendingPathComponent("Windows/tests/fixtures/haust-account.html"), encoding: .utf8)
        let jquery = try String(contentsOf: project.appendingPathComponent("Windows/tests/node_modules/jquery/dist/jquery.min.js"), encoding: .utf8)
        let transport = #"""
        <script>
        window.fixtureRequests=[]; window.fixtureReply={code:0,online:{Username:'dummy-user',Name:'',UserMac:'',AddTime:''}};
        $.ajaxTransport('+*',function(options){return {
          send:function(_headers,complete){
            if(options.url.indexOf('/api/config')===0){
              window.fixtureReleaseConfig=()=>complete(200,'OK',{text:JSON.stringify({data:{password_config:{},password_rule_scope:{portal_auth:'1'}}})},'Content-Type: application/json');
              return;
            }
            window.fixtureRequests.push(options.url);
            const reply=options.url==='/api/account/login'?window.fixtureReply:{code:0};
            setTimeout(()=>complete(200,'OK',{text:JSON.stringify(reply)},'Content-Type: application/json'),10);
          },abort:function(){}
        }});
        </script>
        """#
        let page = html.replacingOccurrences(of: "<script src=\"/jquery.js\"></script>", with: "<script>" + jquery + "</script>" + transport)
        let url = "http://portal.test/tpl/stu-ky/login_account.html?ip=10.0.0.8&mac=00:11:22:33:44:55"
        var profile = CampusProfile(); profile.portalURL = url; profile.username = "dummy-user"; profile.autoSubmit = true
        let status = try PortalScript.build(profile: profile, password: "", statusOnly: true)
        func waitStatus() async throws -> String {
            for _ in 0..<40 {
                let value = try await js(status) as? String ?? "nil"
                if value != "awaiting-authentication" { return value }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            return "timeout"
        }
        try await load(html: page, baseURL: url)
        try expect(try await fill() == "waiting-ready", "native account form waits for async password configuration")
        try expect(try await js("fixtureRequests.length") as? Int == 0, "native config wait sends no login request")
        try await js("fixtureReleaseConfig(); true")
        try expect(try await fill() == "submitted", "native account submits through original school functions")
        try expect(try await waitStatus() == "authenticated", "native account observes actual login success")
        try expect(try await js("JSON.stringify(fixtureRequests)") as? String == "[\"/api/account/check\",\"/api/account/login\"]", "native account preserves password check and login order")
        try expect(try await js("JSON.stringify([postData.userIpv4,postData.userMac])") as? String == "[\"10.0.0.8\",\"00:11:22:33:44:55\"]", "native account retains gateway context")
        try await load(html: page, baseURL: url)
        try await js("fixtureReleaseConfig(); fixtureReply={code:1,msg:'dummy-password E20027'}; true")
        try expect(try await fill() == "submitted", "native rejection still uses original login")
        try expect(try await waitStatus() == "authentication-rejected:E20027", "native observes school E20027 without inventing meaning")
        try expect(try await fill() == "authentication-rejected:E20027", "native rejection does not resubmit")
        try expect(try await js("fixtureRequests.length") as? Int == 2, "native rejection leaves school request count unchanged")
        try expect(try await js("JSON.stringify(__campusSubmitAttempt).includes('dummy-password')") as? Bool == false, "native diagnostic omits response text and password")
        try await load(html: page, baseURL: url)
        try expect(try await fill(submit: false) == "filled", "native manual fill does not need async config")
        try expect(try await js("fixtureRequests.length") as? Int == 0, "native manual mode does not send login")
        try await js("fixtureReleaseConfig(); document.getElementById('code').style.display='block'; true")
        try expect(try await fill() == "manual-required", "native account waits for alphanumeric CAPTCHA")
        try expect(try await js("fixtureRequests.length") as? Int == 0, "native empty CAPTCHA never submits")
        try await js("document.getElementById('codeNumber').value='aB7Z'; true")
        try expect(try await fill() == "submitted", "native manually confirmed CAPTCHA uses school login")
        try expect(try await waitStatus() == "authenticated", "native CAPTCHA flow success is observed")
        try expect(try await js("postData.captcha") as? String == "aB7Z", "native CAPTCHA case remains unchanged")
    }
    func xjuChecks() async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let html = try String(contentsOf: source.appendingPathComponent("../../Windows/tests/fixtures/xju-account.html"), encoding: .utf8)
        try await load(html: html)
        try expect(try await fill(service: "中国联通") == "submitted", "XJU original account button submits")
        try expect(try await js("JSON.stringify(received)") as? String == "[\"dummy-user\",\"dummy-password\",\"1-@cucc\",\"\"]", "XJU original handler receives selected route and credentials")
        try expect(try await js("changes") as? Int == 1, "XJU school route change event runs")
        try expect(try await fill(service: "中国联通") == "already-submitted", "XJU submission deduplicates")
        try await load(html: html)
        try expect(try await fill() == "service-required", "XJU route placeholder pauses submission")
        try expect(try await js("clicks") as? Int == 0, "XJU unselected route never clicks")
        try expect(try await fill(submit: false, service: "中国联通") == "filled", "XJU manual mode fills and selects")
        try expect(try await js("clicks") as? Int == 0, "XJU manual mode does not submit")
        try await load(html: html)
        try expect(try await fill(service: "中国移动") == "missing-service", "XJU unmatched route does not submit")
        try await load(html: html)
        try await js("document.querySelector('.panel-captcha').hidden=false; true")
        try expect(try await fill(service: "中国联通") == "manual-required", "XJU visible challenge waits for input")
        try expect(try await js("clicks") as? Int == 0, "XJU empty challenge never submits")
    }
    func run() async throws {
        try await xjuChecks()
        // Exact user-supplied button; the surrounding offline form is synthetic.
        let haustPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Windows/tests/fixtures/haust-login.html")
        let haust = try String(contentsOf: haustPath, encoding: .utf8)
        let destination = "https://aaa.school.test:8443/tpl/stu-ky/login_account.html?session=fixture"
        var entryProfile = CampusProfile()
        entryProfile.portalURL = "http://1.1.1.1"; entryProfile.username = "dummy-user"; entryProfile.autoSubmit = true
        try await load(html: "<p>正在跳转…</p>", baseURL: destination)
        let activeProfile = try PortalScript.atCurrentPage(profile: entryProfile, url: view.url!)
        let landingProbe = try PortalScript.loginFormProbe(profile: activeProfile)
        try expect(try await js(landingProbe) as? Bool == false, "redirect spinner waits without credentials")
        try await load(html: haust, baseURL: destination)
        try expect(try await js(landingProbe) as? Bool == true, "actual cross-origin landing form recognized")
        let landingScript = try PortalScript.build(profile: activeProfile, password: "dummy-password")
        try expect(try await js(landingScript) as? String == "submitted", "different host port and scheme receive scoped filling")
        try expect(try await js("JSON.stringify(observed)") as? String == "[\"dummy-user\",\"dummy-password\"]", "redirected original school handler receives filled values")
        try expect(try await js(landingScript) as? String == "already-submitted", "redirect landing submits once")
        try expect(entryProfile.portalURL == "http://1.1.1.1", "dynamic destination does not overwrite saved address")
        try await load(html: haust)
        try expect(try await fill() == "submitted", "HAUST original button submits")
        try expect(try await js("loginClicks") as? Int == 1, "HAUST checkForm handler called once")
        try expect(try await js("otherClicks") as? Int == 0, "HAUST unrelated submit button not clicked")
        try expect(try await js("JSON.stringify(observed)") as? String == "[\"dummy-user\",\"dummy-password\"]", "HAUST handler receives filled credentials")
        try expect(try await fill() == "already-submitted", "HAUST duplicate submission blocked")
        try expect(try await js("loginClicks") as? Int == 1, "HAUST no second handler call")
        try await load(html: haust)
        try expect(try await fill(submit: false) == "filled", "HAUST manual mode fills only")
        try expect(try await js("loginClicks") as? Int == 0, "HAUST manual mode never clicks")
        for state in ["disabled", "hidden"] {
            try await load(html: haust)
            try await js("document.getElementById('login-account').\(state)=true; true")
            try expect(try await fill() == "missing-submit", "HAUST unavailable button is not clicked")
            try expect(try await js("loginClicks+otherClicks") as? Int == 0, "HAUST unavailable button never falls through")
        }
        try await load(html: haust)
        try await js("window.checkForm=undefined; true")
        try expect(try await fill() == "waiting-ready", "HAUST waits for school handler")
        try expect(try await js("loginClicks+otherClicks") as? Int == 0, "HAUST late handler does not trigger another control")
        try await js("window.checkForm=function(){loginClicks++}; true")
        try expect(try await fill() == "submitted", "HAUST late handler recovers")
        try await load(html: haust)
        try expect(try await fill(origin: "http://foreign.test") == "wrong-origin", "HAUST origin guard remains")
        try expect(try await js("document.querySelector('[name=password]').value") as? String == "", "HAUST wrong origin receives no password")
        let serviceForm = "<form><input name='username'><input type='password'><button type='button' onclick='window.clicks++'>登录</button></form><script>window.clicks=0</script>"
        try await load(html: serviceForm)
        try expect(try await js("void 0") is NSNull, "undefined JavaScript statements bridge safely")
        try expect(try await js("null") is NSNull, "null JavaScript results bridge safely")
        try expect(try await fill(service: "中国移动") == "missing-service", "configured service without controls waits for correction")
        try expect(try await js("window.__campusServiceFailure") as? String == "service-control-missing", "native diagnostic identifies absent service controls")
        try expect(try await js("clicks") as? Int == 0, "absent service never submits")
        try await js("document.body.insertAdjacentHTML('beforeend', '<select><option>选择运营商</option><option>中国联通</option></select>')")
        try expect(try await fill(service: "中国移动") == "missing-service", "unmatched service pauses login")
        try expect(try await js("window.__campusServiceFailure") as? String == "service-option-missing", "native diagnostic identifies unmatched full name")
        try await js("document.querySelector('select').insertAdjacentHTML('beforeend', '<option>中国移动</option>')")
        try expect(try await pump(service: "中国移动") == "submitted", "late matching option recovers without dismissing a required service")
        try expect(try await js("window.__campusServiceFailure == null") as? Bool == true, "stale reason clears after a matching selection")
        try expect(try await js("clicks") as? Int == 1, "late matching option submits once")
        try await load(html: serviceForm)
        try expect(try await pump() == "submitted", "blank optional service works without controls")
        try await load(html: serviceForm + "<label><input type='radio' name='network' onclick='event.preventDefault()'>中国移动</label>")
        try expect(try await fill(service: "中国移动") == "missing-service", "school can reject a radio selection")
        try expect(try await js("window.__campusServiceFailure") as? String == "service-selection-failed", "native diagnostic identifies unconfirmed selection")
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
        try await addedSchoolChecks()
        try await accountPortalChecks()
        print("PASS: \(checks) native WKWebView checks (first click, handler readiness, asynchronous handoff, deduplication, manual mode, origin and service selection).")
    }
}
