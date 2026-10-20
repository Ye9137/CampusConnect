import Foundation
import JavaScriptCore

@main struct Tests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() throws {
        let localDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("work/storage-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        var storedProfile = CampusProfile()
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
        escapingProfile.serviceOption = "联通接入服务'\"\n"
        let serviceScript = try PortalScript.build(profile: escapingProfile, password: "dummy")
        let payload = serviceScript.components(separatedBy: "const cfg = ")[1].components(separatedBy: ";")[0]
        let serviceJSON = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
        expect(serviceJSON["serviceOption"] as? String == escapingProfile.serviceOption, "service option JSON escaping")
        var profile = CampusProfile()
        try profile.validate()
        expect(profile.ssid == "HNPI-STU", "target SSID default")
        expect(profile.validPortalURL?.host == "192.168.0.123", "portal URL default")
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
        expect(!CampusProfile().isWired, "existing SSID remains Wi-Fi mode")
        expect(wired.matchesNetwork(currentSSID: nil, wiredAvailable: true), "wired authentication without Wi-Fi")
        expect(!wired.matchesNetwork(currentSSID: "HNPI-STU", wiredAvailable: false), "Wi-Fi cannot stand in for disconnected Ethernet")
        expect(!CampusProfile().matchesNetwork(currentSSID: "Other", wiredAvailable: true), "Ethernet cannot bypass SSID guard")
        expect(CampusProfile().matchesNetwork(currentSSID: "HNPI-STU", wiredAvailable: false), "original Wi-Fi authentication allowed")
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
        var policy = AutoPolicy()
        let now = Date()
        expect(!policy.shouldJoin(enabled: true, target: "", current: nil, visible: [""], busy: false, now: now), "wired mode never joins Wi-Fi")
        expect(policy.shouldJoin(enabled: true, target: "HNPI-STU", current: "Home", visible: ["HNPI-STU"], busy: false, now: now), "connect visible exact target")
        expect(!policy.shouldJoin(enabled: true, target: "HNPI-STU", current: nil, visible: ["HNPI-STU-fake"], busy: false, now: now), "no substring match")
        expect(!policy.shouldJoin(enabled: false, target: "HNPI-STU", current: nil, visible: ["HNPI-STU"], busy: false, now: now), "pause toggle")
        expect(!policy.shouldJoin(enabled: true, target: "HNPI-STU", current: "HNPI-STU", visible: ["HNPI-STU"], busy: false, now: now), "don't reconnect connected target")
        policy.begin(at: now)
        expect(!policy.shouldJoin(enabled: true, target: "HNPI-STU", current: nil, visible: ["HNPI-STU"], busy: false, now: now.addingTimeInterval(59)), "retry cooldown")
        expect(policy.shouldJoin(enabled: true, target: "HNPI-STU", current: nil, visible: ["HNPI-STU"], busy: false, now: now.addingTimeInterval(61)), "retry after cooldown")
        for i in 1...1000 {
            let retryAt = now.addingTimeInterval(Double(60 * i))
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
        expect(!recovery.shouldAuthenticate(enabled: true, portalEnabled: true, now: now.addingTimeInterval(20)), "no duplicate submissions every heartbeat")
        expect(recovery.shouldAuthenticate(enabled: true, portalEnabled: true, now: now.addingTimeInterval(60)), "retry after cooldown")
        recovery.begin(at: now.addingTimeInterval(60))
        expect(!recovery.shouldAuthenticate(enabled: true, portalEnabled: true, now: now.addingTimeInterval(120)), "second retry backs off")
        expect(recovery.shouldAuthenticate(enabled: true, portalEnabled: true, now: now.addingTimeInterval(180)), "backoff expires")
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
