import Foundation
import JavaScriptCore

@main struct Tests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() throws {
        var redirectEntry = CampusProfile()
        redirectEntry.portalURL = "http://1.1.1.1"; redirectEntry.username = "fixture-user"
        let redirected = try PortalScript.atCurrentPage(profile: redirectEntry,
            url: URL(string: "https://aaa.school.test:8443/tpl/login_account.html?session=fixture")!)
        expect(redirected.portalURL.hasSuffix(":8443/tpl/login_account.html?session=fixture"), "redirect retains actual port, path and query")
        expect(redirected.username == redirectEntry.username && redirectEntry.portalURL == "http://1.1.1.1", "redirect keeps account and saved entry unchanged")
        let redirectProbe = try PortalScript.loginFormProbe(profile: redirected)
        expect(!redirectProbe.contains("fixture-user"), "landing-page probe never contains saved account")
        expect(PortalFillRetry.shouldRetry(result: "wrong-origin", scriptFailed: false, attempt: 1), "navigation race rebinds to landing page instead of mismatch popup")
        for bad in ["about:blank", "javascript:alert(1)", "file:///tmp/login", "https://user:pass@school.test/"] {
            do { _ = try PortalScript.atCurrentPage(profile: redirectEntry, url: URL(string: bad)!); expect(false, "invalid landing rejected") }
            catch { expect(true, "invalid landing rejected") }
        }
        expect(PortalProblem.isAuthenticationRejected("authentication-rejected:E20027"), "school error code is treated as rejection")
        expect(PortalProblem.authenticationMessage("authentication-rejected:E20027").contains("E20027"), "known format error identifier is retained")
        expect(!PortalProblem.authenticationMessage("authentication-rejected:dummy-password").contains("dummy-password"), "untrusted message is excluded")
        expect(!PortalProblem.authenticationMessage("authentication-rejected:E20027\n").contains("E20027"), "invalid error identifiers are excluded")
        var noticeGate = PortalProblemGate()
        for code in ["service-control-missing", "service-option-missing", "service-selection-failed"] {
            var guideGate = PortalProblemGate()
            let problem = guideGate.report(code, serviceOption: "中国移动\n")
            expect(problem?.settingsField == "serviceOption" && problem?.steps.count == 4, "service failure has a four-step guide and targets operator input")
            expect(problem?.summary.contains("中国移动") == true && problem?.summary.contains("中国移动\n") == false, "only sanitized service name is shown")
            expect(PortalProblem.serviceCode(code) == code, "service reason is preserved")
        }
        expect(PortalProblem.serviceCode("untrusted-code") == "missing-service", "unknown browser diagnostic falls back to generic mismatch")
        expect(PortalFillRetry.shouldRetry(result: "missing-service", scriptFailed: false, attempt: 79), "delayed service options retain bounded retries")
        expect(!PortalFillRetry.shouldRetry(result: "missing-service", scriptFailed: false, attempt: 80), "missing service becomes visible guide after bounded waiting")
        for normal in ["authenticated", "filled", "submitted", "manual-required", "waiting-submit", "captcha-required"] {
            expect(noticeGate.report(normal) == nil, "normal and pending authentication never shows an error popup")
        }
        let serviceProblem = noticeGate.report("missing-service")
        expect(serviceProblem?.advice.contains("请清空设置中的") == true && serviceProblem?.advice.contains("无法自动填写信息") == true, "operator mismatch explains how to clear an unnecessary setting")
        expect(noticeGate.report("missing-service") == nil && noticeGate.report("load-failed") == nil, "one popup per authentication attempt across multiple callbacks")
        noticeGate.reset()
        expect(noticeGate.current == nil, "stop or successful authentication clears a queued error")
        expect(noticeGate.report("load-failed")?.advice.contains("认证地址") == true, "new attempt can report a fresh load error with advice")
        for code in ["wrong-origin", "service-required", "authentication-rejected", "missing-credentials", "missing-submit", "agreement-required", "waiting-ready", "submission-unconfirmed", "missing-fields", "script-failed"] {
            noticeGate.reset()
            let problem = noticeGate.report(code)
            expect(problem != nil && !(problem?.title.isEmpty ?? true) && !(problem?.summary.isEmpty ?? true) && !(problem?.advice.isEmpty ?? true), "terminal failure provides guidance: \(code)")
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--frame-script" {
            var profile = CampusProfile(); profile.portalURL = "http://portal.test"; profile.username = "dummy-user"; profile.autoSubmit = true
            try PortalScript.build(profile: profile, password: "dummy-password").write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
            return
        }
        let localDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("work/storage-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        var storedProfile = CampusProfile()
        storedProfile.ssid = "Fixture-Campus"; storedProfile.portalURL = "http://portal.test"
        storedProfile.username = "test-account"
        storedProfile.serviceOption = "联通接入服务"
        let secrets = Secrets(wifi: "test-wifi", portal: "test-portal")
        try LocalStore.save(profile: storedProfile, secrets: secrets, directory: localDirectory)
        let reloaded = try LocalStore.load(directory: localDirectory)
        expect(reloaded.profile == storedProfile, "local account and settings persist")
        expect(reloaded.credentials[storedProfile.ssid] == secrets, "local passwords persist")
        let legacyFile = localDirectory.appendingPathComponent("configuration.json")
        var legacyJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyFile)) as! [String: Any]
        var legacyProfile = legacyJSON["profile"] as! [String: Any]
        legacyProfile["loginMethod"] = "direct"
        legacyProfile["serviceName"] = "legacy-service"
        legacyJSON["profile"] = legacyProfile
        try JSONSerialization.data(withJSONObject: legacyJSON).write(to: legacyFile)
        let migrated = try LocalStore.load(directory: localDirectory)
        expect(migrated.profile == storedProfile, "legacy direct settings do not change web settings")
        expect(migrated.credentials[storedProfile.ssid] == secrets, "legacy direct passwords preserved")
        let encoded = String(data: try JSONEncoder().encode(migrated.profile), encoding: .utf8)!
        expect(!encoded.contains("loginMethod") && !encoded.contains("serviceName"), "removed authentication options are not persisted")

        let modeDirectory = localDirectory.appendingPathComponent("connection-modes")
        let fresh = try LocalStore.load(directory: modeDirectory)
        expect(!fresh.profile.isWired && fresh.profile.ssid.isEmpty && fresh.profile.portalURL.isEmpty, "fresh config has explicit empty Wi-Fi mode")
        var wifiProfile = CampusProfile()
        wifiProfile.ssid = "Custom-University"; wifiProfile.username = "fixture-wifi-user"
        wifiProfile.portalURL = "https://wifi.test/login"; wifiProfile.serviceOption = "无线服务"
        var wiredProfile = CampusProfile.empty(wired: true)
        wiredProfile.username = "fixture-wired-user"; wiredProfile.portalURL = "https://wired.test/login"
        wiredProfile.ethernetName = "en5"; wiredProfile.wiredAuth = .web
        let wifiSecrets = Secrets(wifi: "fixture-radio-secret", portal: "fixture-wifi-secret")
        let wiredSecrets = Secrets(wifi: "", portal: "fixture-wired-secret")
        try LocalStore.save(profile: wifiProfile, secrets: wifiSecrets, directory: modeDirectory)
        // A real old-format file has no per-mode profile dictionary.
        let modeFile = modeDirectory.appendingPathComponent("configuration.json")
        var modeJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: modeFile)) as! [String: Any]
        modeJSON.removeValue(forKey: "profiles")
        try JSONSerialization.data(withJSONObject: modeJSON).write(to: modeFile)
        try LocalStore.save(profile: wiredProfile, secrets: wiredSecrets, directory: modeDirectory)
        let modeReload = try LocalStore.load(directory: modeDirectory)
        expect(modeReload.profile == wiredProfile, "restart restores saved wired mode")
        expect(modeReload.allProfiles["wifi"] == wifiProfile, "legacy custom Wi-Fi details survive wired save")
        var drafts = ConnectionDrafts(configuration: modeReload)
        expect(drafts.settings(wired: false).profile.ssid == "Custom-University", "Wi-Fi restores custom SSID instead of default")
        expect(drafts.settings(wired: false).secrets == wifiSecrets, "Wi-Fi passwords restored independently")
        expect(drafts.settings(wired: true).secrets == wiredSecrets, "wired password restored independently")
        var wifiDraft = drafts.settings(wired: false)
        wifiDraft.profile.username = "unfinished wireless"; wifiDraft.secrets.portal = "unfinished wifi secret"
        drafts.remember(profile: wifiDraft.profile, secrets: wifiDraft.secrets)
        var wiredDraft = drafts.settings(wired: true)
        wiredDraft.profile.wiredAuth = .pppoe; wiredDraft.profile.broadbandName = "Fixture dial-up"
        drafts.remember(profile: wiredDraft.profile, secrets: wiredDraft.secrets)
        expect(drafts.settings(wired: false) == wifiDraft, "switching back keeps complete unsaved Wi-Fi draft")
        expect(drafts.settings(wired: true) == wiredDraft, "switching back keeps wired protocol draft")
        let onlyWired = ConnectionDrafts(configuration: LocalConfiguration(profile: wiredProfile))
        expect(onlyWired.settings(wired: false).profile.ssid.isEmpty && onlyWired.settings(wired: false).profile.portalURL.isEmpty, "missing Wi-Fi profile never fabricates school defaults")
        let emptyWifi = CampusProfile.empty(wired: false)
        expect(!emptyWifi.isWired, "clearing Wi-Fi name does not switch connection mode")
        do { try emptyWifi.validate(); expect(false, "empty Wi-Fi target saved") } catch { checks += 1 }
        try LocalStore.save(profile: wifiProfile, secrets: wifiSecrets, directory: modeDirectory)
        let finalModeReload = try LocalStore.load(directory: modeDirectory)
        expect(finalModeReload.allProfiles["wired"] == wiredProfile, "saving Wi-Fi preserves wired settings on disk")

        let filePermissions = try FileManager.default.attributesOfItem(atPath: localDirectory.appendingPathComponent("configuration.json").path)[.posixPermissions] as? NSNumber
        expect(filePermissions?.intValue == 0o600, "credential file owner-only permissions")
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: localDirectory.path)[.posixPermissions] as? NSNumber
        expect(directoryPermissions?.intValue == 0o700, "credential directory owner-only permissions")
        storedProfile.portalURL = "http://192.168.0.123/login"
        try LocalStore.save(profile: storedProfile, directory: localDirectory)
        let preserved = try LocalStore.read(storedProfile.ssid, "portal", directory: localDirectory)
        expect(preserved == secrets.portal, "settings updates retain stored passwords")
        let preservedProfile = try LocalStore.load(directory: localDirectory).profile
        expect(!preservedProfile.automatic, "local storage preserves paused automation")
        let oldProfile = try JSONDecoder().decode(CampusProfile.self, from: Data("{}".utf8))
        expect(oldProfile.serviceOption.isEmpty, "old configurations default to blank service")
        expect(PortalFillRetry.shouldRetry(result: "missing-service", scriptFailed: false, attempt: 1), "wait for delayed service options")
        expect(!PortalFillRetry.shouldRetry(result: "missing-service", scriptFailed: false, attempt: 200), "service waiting is bounded")
        var escapingProfile = CampusProfile()
        escapingProfile.portalURL = "http://portal.test"
        escapingProfile.serviceOption = "联通接入服务'\"\n"
        let serviceScript = try PortalScript.build(profile: escapingProfile, password: "dummy")
        let payload = serviceScript.components(separatedBy: "const cfg = ")[1].components(separatedBy: ";")[0]
        let serviceJSON = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
        expect(serviceJSON["serviceOption"] as? String == escapingProfile.serviceOption, "service option JSON escaping")
        for empty in [CampusProfile(), oldProfile, CampusProfile.empty(wired: false), CampusProfile.empty(wired: true)] {
            expect([empty.ssid, empty.portalURL, empty.username, empty.serviceOption, empty.wifiUsername, empty.ethernetName, empty.broadbandName, empty.authenticationClient].allSatisfy(\.isEmpty), "all editable fields and missing legacy values default to blank")
            expect(!empty.automatic, "blank configuration never starts automatic connections")
        }
        expect(Secrets().wifi.isEmpty && Secrets().portal.isEmpty, "new passwords default to blank")
        var profile = CampusProfile()
        profile.ssid = "HNPI-STU"; profile.portalURL = "http://192.168.0.123"
        try profile.validate()
        expect(profile.ssid == "HNPI-STU", "configured target SSID preserved")
        expect(profile.validPortalURL?.host == "192.168.0.123", "configured portal URL preserved")
        profile.portalURL = "javascript:alert(1)"
        expect(profile.validPortalURL == nil, "reject non-web URL")
        profile.portalURL = "https://a:b@example.com"
        expect(profile.validPortalURL == nil, "reject embedded credentials")
        profile.portalURL = "http://192.168.0.123"
        expect(PortalScript.origin(URL(string: "http://example.com:80/login")!) == "http://example.com", "normalize default port")
        expect(PortalScript.origin(URL(string: "https://example.com:8443/login")!) == "https://example.com:8443", "retain distinct port")

        expect(PortalFillRetry.shouldRetry(result: nil, scriptFailed: true, attempt: 0), "first navigation script error retries")
        expect(PortalFillRetry.shouldRetry(result: "waiting-submit", scriptFailed: false, attempt: 80), "late first submit continues beyond old twelve-second window")
        expect(!PortalFillRetry.shouldRetry(result: "submission-unconfirmed", scriptFailed: false, attempt: 0), "unconfirmed handler does not get clicked repeatedly")
        expect(!PortalFillRetry.shouldRetry(result: "manual-required", scriptFailed: false, attempt: 0), "manual challenge is not retried")
        expect(!PortalFillRetry.shouldRetry(result: nil, scriptFailed: true, attempt: 200), "script retries are bounded")

        var wired = CampusProfile()
        wired.ssid = ""; wired.joinMode = .enterprise
        try wired.validate() // Stale Wi-Fi enterprise fields are irrelevant in wired mode.
        expect(wired.isWired, "empty SSID selects wired mode")
        expect(!profile.isWired, "existing SSID remains Wi-Fi mode")
        expect(wired.matchesNetwork(currentSSID: nil, wiredAvailable: true), "wired authentication without Wi-Fi")
        expect(!wired.matchesNetwork(currentSSID: "HNPI-STU", wiredAvailable: false), "Wi-Fi cannot stand in for disconnected Ethernet")
        expect(!profile.matchesNetwork(currentSSID: "Other", wiredAvailable: true), "Ethernet cannot bypass SSID guard")
        expect(profile.matchesNetwork(currentSSID: "HNPI-STU", wiredAvailable: false), "original Wi-Fi authentication allowed")
        try LocalStore.save(profile: wired, secrets: secrets, directory: localDirectory)
        let wiredReloaded = try LocalStore.load(directory: localDirectory)
        expect(wiredReloaded.profile.isWired && wiredReloaded.profile.ssid.isEmpty, "wired config reload")
        expect(wiredReloaded.credentials[""] == secrets, "wired credentials persist under empty SSID")
        expect(wiredReloaded.credentials[storedProfile.ssid] == secrets, "mode change preserves Wi-Fi credentials")
        wired.ssid = "  "
        expect(wired.isWired, "whitespace selects wired mode")
        wired.portalURL = "javascript:alert(1)"
        do { try wired.validate(); expect(false, "invalid wired portal accepted") } catch { checks += 1 }
        let legacyWired = try JSONDecoder().decode(CampusProfile.self, from: Data("{\"ssid\":\"\"}".utf8))
        expect(legacyWired.isWired && legacyWired.wiredAuth == .web, "legacy blank SSID uses wired web authentication")
        for mode in WiredAuth.allCases {
            var system = CampusProfile(); system.ssid = ""; system.wiredAuth = mode
            system.ethernetName = "en5"; system.broadbandName = "Campus PPPoE"
            system.authenticationClient = "/Applications/School Client.app"
            if mode != .web { system.portalURL = "invalid-unused-web-url" }
            try system.validate()
            let decoded = try JSONDecoder().decode(CampusProfile.self, from: JSONEncoder().encode(system))
            expect(decoded == system, "all wired protocol fields survive save/reload")
            expect(system.usesSystemAuthentication == (mode != .web), "system mode detection")
            expect(system.usesWebPortal == (mode == .web), "system authentication never sends webpage credentials")
            expect(!system.connectionLabel.contains("Wi-Fi"), "wired labels have no stale Wi-Fi")
        }
        var invalidWired = CampusProfile(); invalidWired.ssid = ""; invalidWired.wiredAuth = .pppoe
        do { try invalidWired.validate(); expect(false, "PPPoE requires saved service name") } catch { checks += 1 }
        invalidWired.broadbandName = "Campus\nOther"
        do { try invalidWired.validate(); expect(false, "PPPoE rejects control characters") } catch { checks += 1 }
        invalidWired.wiredAuth = .client; invalidWired.authenticationClient = "/Applications/Client.exe"
        do { try invalidWired.validate(); expect(false, "school client must be a Mac app") } catch { checks += 1 }
        do {
            _ = try JSONDecoder().decode(CampusProfile.self, from: Data("{\"wiredAuth\":\"unknown\"}".utf8))
            expect(false, "unknown authentication mode rejected")
        } catch { checks += 1 }
        let noIP = WiredInterface(name: "en5", title: "USB Ethernet", linked: true, hasAddress: false)
        let other = WiredInterface(name: "en6", title: "Other Ethernet", linked: true, hasAddress: true)
        expect(WiredSystem.select(name: "en5", from: [other, noIP]) == noIP, "selected linked adapter usable before DHCP for system authentication")
        expect(WiredSystem.select(name: "missing", from: [other, noIP]) == nil, "missing selected adapter never falls back")
        expect(WiredSystem.select(name: "", from: [noIP, other]) == noIP, "automatic adapter selection does not require IP")
        expect(WiredSystem.select(name: "", from: []) == nil, "no Ethernet never falls back to Wi-Fi")
        invalidWired.ethernetName = "campus-missing-interface-test"
        expect(!WiredSystem.connected(invalidWired), "missing configured system connection cannot be authenticated")
        expect(PortalFillRetry.shouldRetry(result: "waiting-agreement", scriptFailed: false, attempt: 1), "asynchronous checkbox retries")
        expect(!PortalFillRetry.shouldRetry(result: "agreement-required", scriptFailed: false, attempt: 1), "rejected checkbox requires manual action")
        var wiredPolicy = AutoPolicy()
        expect(wiredPolicy.shouldPrepareWired(enabled: true, needed: true, busy: false, now: Date()), "system authentication first attempt immediate")
        let wiredNow = Date(); wiredPolicy.begin(at: wiredNow)
        expect(!wiredPolicy.shouldPrepareWired(enabled: true, needed: true, busy: false, now: wiredNow.addingTimeInterval(59)), "system authentication has cooldown")
        expect(wiredPolicy.shouldPrepareWired(enabled: true, needed: true, busy: false, now: wiredNow.addingTimeInterval(61)), "system authentication retries after cooldown")
        expect(!wiredPolicy.shouldPrepareWired(enabled: false, needed: true, busy: false, now: wiredNow.addingTimeInterval(600)), "pause blocks system authentication")
        expect(!wiredPolicy.shouldPrepareWired(enabled: true, needed: true, busy: true, now: wiredNow.addingTimeInterval(600)), "no concurrent system authentication")
        expect(AutoPolicy.checkInterval == 5, "five second automatic cadence")
        for current in [nil, "Other", "Target"] as [String?] {
            expect(AutoPolicy.backgroundWork(enabled: false, wired: false, target: "Target", current: current) == .stopped, "disabled mode performs no background work")
        }
        expect(AutoPolicy.backgroundWork(enabled: false, wired: true, target: "", current: nil) == .stopped, "wired automatic off remains idle")
        expect(AutoPolicy.backgroundWork(enabled: true, wired: false, target: "Target", current: "Other") == .otherNetwork, "other Wi-Fi skips scans and ping")
        expect(AutoPolicy.backgroundWork(enabled: true, wired: false, target: "Target", current: "Target") == .checkInternet, "target network probes internet")
        expect(AutoPolicy.backgroundWork(enabled: true, wired: false, target: "Target", current: nil) == .findTarget, "disconnected target is rediscovered")
        expect(AutoPolicy.backgroundWork(enabled: true, wired: false, target: "", current: nil) == .stopped, "blank target never starts background work")
        var policy = AutoPolicy()
        let now = Date()
        expect(!policy.shouldJoin(enabled: true, target: "", current: nil, visible: [""], busy: false, now: now), "wired mode never joins Wi-Fi")
        expect(!policy.shouldJoin(enabled: true, target: "HNPI-STU", current: "Home", visible: ["HNPI-STU"], busy: false, now: now), "other network is never switched automatically")
        expect(!policy.shouldJoin(enabled: true, target: "HNPI-STU", current: nil, visible: ["HNPI-STU-fake"], busy: false, now: now), "no substring match")
        expect(!policy.shouldJoin(enabled: false, target: "HNPI-STU", current: nil, visible: ["HNPI-STU"], busy: false, now: now), "pause toggle")
        expect(!policy.shouldJoin(enabled: true, target: "HNPI-STU", current: "HNPI-STU", visible: ["HNPI-STU"], busy: false, now: now), "don't reconnect connected target")
        policy.begin(at: now)
        expect(!policy.shouldJoin(enabled: true, target: "HNPI-STU", current: nil, visible: ["HNPI-STU"], busy: false, now: now.addingTimeInterval(4)), "five second retry cooldown")
        expect(policy.shouldJoin(enabled: true, target: "HNPI-STU", current: nil, visible: ["HNPI-STU"], busy: false, now: now.addingTimeInterval(5)), "retry at five seconds")
        for i in 1...1000 {
            let retryAt = now.addingTimeInterval(Double(5 * i))
            expect(policy.shouldJoin(enabled: true, target: "HNPI-STU", current: nil, visible: ["HNPI-STU"], busy: false, now: retryAt), "Wi-Fi retries without a failure limit")
            policy.begin(at: retryAt)
        }
        policy.reset()
        expect(policy.shouldJoin(enabled: true, target: "HNPI-STU", current: nil, visible: ["HNPI-STU"], busy: false, now: now), "reset allows immediate connection")

        var recovery = PortalRecovery()
        expect(recovery.shouldAuthenticate(enabled: true, portalEnabled: true, now: now), "first authentication starts before probes or timer ticks")
        expect(!recovery.shouldAuthenticate(enabled: false, portalEnabled: true, now: now), "startup respects pause")
        expect(!recovery.shouldAuthenticate(enabled: true, portalEnabled: false, now: now), "startup respects disabled portal")
        recovery.observe(.online)
        expect(!recovery.shouldAuthenticate(enabled: true, portalEnabled: true, now: now), "online does not reauthenticate")
        recovery.observe(.unavailable)
        expect(recovery.shouldAuthenticate(enabled: true, portalEnabled: true, now: now), "same SSID expired authentication recovers")
        recovery.begin(at: now)
        expect(!recovery.shouldAuthenticate(enabled: true, portalEnabled: true, now: now.addingTimeInterval(4)), "no duplicate submissions before five seconds")
        expect(recovery.shouldAuthenticate(enabled: true, portalEnabled: true, now: now.addingTimeInterval(5)), "retry after five seconds")
        recovery.begin(at: now.addingTimeInterval(5))
        expect(!recovery.shouldAuthenticate(enabled: true, portalEnabled: true, now: now.addingTimeInterval(9)), "second retry respects cooldown")
        expect(recovery.shouldAuthenticate(enabled: true, portalEnabled: true, now: now.addingTimeInterval(10)), "five second cooldown expires")
        expect(!recovery.shouldAuthenticate(enabled: false, portalEnabled: true, now: now.addingTimeInterval(1000)), "pause blocks recovery")
        expect(!recovery.shouldAuthenticate(enabled: true, portalEnabled: false, now: now.addingTimeInterval(1000)), "disabled portal blocks recovery")
        recovery.observe(.online)
        expect(recovery.attempts == 0, "internet success resets attempts")
        recovery.observe(.unavailable)
        expect(recovery.shouldAuthenticate(enabled: true, portalEnabled: true, now: now), "first failed ping triggers recovery")
        recovery.observe(.unavailable)
        expect(recovery.shouldAuthenticate(enabled: true, portalEnabled: true, now: now), "repeated failures recover")
        var authenticationTime = now
        for _ in 0..<1000 {
            expect(recovery.shouldAuthenticate(enabled: true, portalEnabled: true, now: authenticationTime), "authentication retries indefinitely")
            recovery.begin(at: authenticationTime)
            recovery.observe(.unavailable)
            authenticationTime = authenticationTime.addingTimeInterval(recovery.retryDelay)
        }
        recovery.reset()
        expect(recovery.shouldAuthenticate(enabled: true, portalEnabled: true, now: now), "new connection resets first authentication delay")
        expect(Connectivity.runPing(executable: "/usr/bin/true", arguments: []) == .online, "successful ping exit is online")
        expect(Connectivity.runPing(executable: "/usr/bin/false", arguments: []) == .unavailable, "failed ping exit is offline")
        expect(Connectivity.runPing(executable: "/missing/campus-ping", arguments: []) == .unavailable, "launch failure is offline")
        let pingStart = Date()
        expect(Connectivity.runPing(executable: "/bin/sleep", arguments: ["10"], timeout: 0.05) == .unavailable, "hung ping times out")
        expect(Date().timeIntervalSince(pingStart) < 3, "timeout stops child promptly")

        profile.username = "test-account'\\\"\n"
        let password = "test'\\\"\n</script>"
        profile.autoSubmit = true
        let script = try PortalScript.build(profile: profile, password: password)
        let context = JSContext()!
        context.evaluateScript("""
          var clicks = 0;
          var window = {};
          var location = {origin:'http://192.168.0.123'};
          var Event = function(name, opts) { this.type = name; };
          class HTMLInputElement {
            constructor(name,type) {this.name=name;this.type=type;this.disabled=false;this.form=null;this._value='';}
            get value(){return this._value;}
            set value(v){this._value=v;}
            getClientRects(){return [1];}
            dispatchEvent(e){}
          }
          var user = new HTMLInputElement('username','text');
          var pass = new HTMLInputElement('password','password');
          var submit = {type:'submit',disabled:false,getClientRects(){return [1]},click(){clicks++}};
          var document = {
            querySelectorAll(s){if(s==='select'||s.startsWith('[role='))return [];if(s==='input[type="checkbox"],[role="checkbox"]')return [];if(s==='input[type="password"]')return [pass]; if(s.startsWith('button'))return [submit];return [user];},
            querySelector(s){if(s==='[')throw Error('selector');if(s==='#username')return user;return null;}
          };
        """)
        expect(context.exception == nil, "mock browser setup")
        expect(context.evaluateScript(script)?.toString() == "submitted", "fill and submit form")
        expect(context.evaluateScript("user.value")?.toString() == profile.username, "preserve account escaping")
        expect(context.evaluateScript("pass.value")?.toString() == password, "preserve password escaping")
        expect(context.evaluateScript(script)?.toString() == "already-submitted", "prevent duplicate submission")
        expect(context.evaluateScript("clicks")?.toInt32() == 1, "one submission only")
        context.evaluateScript("window={};location.origin='http://unrelated.local';user.value='';pass.value=''")
        expect(context.evaluateScript(script)?.toString() == "wrong-origin", "reject unrelated origin")
        expect(context.evaluateScript("pass.value")?.toString() == "", "no credentials on wrong origin")
        context.evaluateScript("location.origin='http://192.168.0.123'")
        let legacySelectors = Data(##"{"username":"kept-account","userSelector":"[","passwordSelector":"#old","submitSelector":"#old-login"}"##.utf8)
        let migratedSelectors = try JSONDecoder().decode(CampusProfile.self, from: legacySelectors)
        let migratedJSON = String(decoding: try JSONEncoder().encode(migratedSelectors), as: UTF8.self)
        expect(migratedSelectors.username == "kept-account", "selector removal preserves account")
        expect(!migratedJSON.contains("userSelector") && !migratedJSON.contains("passwordSelector") && !migratedJSON.contains("submitSelector"), "removed selectors are not persisted")
        profile.autoSubmit = false
        let manualScript = try PortalScript.build(profile: profile, password: password)
        expect(context.evaluateScript(manualScript)?.toString() == "filled", "manual submit mode")
        expect(context.evaluateScript("clicks")?.toInt32() == 1, "manual mode doesn't click")
        profile.autoSubmit = true
        context.evaluateScript("window={};submit.type='button';submit.innerText='连接 Login'")
        let bilingualScript = try PortalScript.build(profile: profile, password: password)
        expect(context.evaluateScript(bilingualScript)?.toString() == "submitted", "recognize campus bilingual login button")
        expect(context.evaluateScript("clicks")?.toInt32() == 2, "click bilingual login once")
        print("PASS: \(checks) checks (profile, connection policy, real JavaScript execution).")
    }
}
