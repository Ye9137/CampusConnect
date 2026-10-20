import AppKit
import SwiftUI
import CoreLocation
import ServiceManagement
import CoreServices
import UniformTypeIdentifiers
import SystemConfiguration

enum Page: String, CaseIterable {
    case dashboard = "网络概览", settings = "校园网设置", portal = "上网认证"
    static func atSidebarPosition(_ y: CGFloat) -> Page? {
        guard y.isFinite, y >= 0, y < 149 else { return nil }
        let index = Int(y / 52)
        guard y - CGFloat(index) * 52 < 45 else { return nil }
        return allCases[index]
    }
    var icon: String {
        switch self { case .dashboard: return "wifi"; case .settings: return "slider.horizontal.3"; case .portal: return "globe" }
    }
}

@MainActor final class AppModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var draft: CampusProfile
    @Published var wifiPassword = ""
    @Published var portalPassword = ""
    @Published var page = Page.dashboard
    @Published var showingFeedback = false
    @Published var currentSSID: String?
    @Published var wiredConnected = false
    @Published var wiredLink = false
    @Published var ethernetInterfaces: [WiredInterface] = []
    @Published var broadbandServices: [String] = []
    @Published var networks: [VisibleNetwork] = []
    @Published var scanning = false
    @Published var joining = false
    @Published var powered = true
    @Published var authorized = false
    @Published var permissionText = "读取 Wi-Fi 名称需要定位权限"
    @Published var status = "准备就绪"
    @Published var internet: Bool?
    @Published var authenticated = false
    @Published var lastScan: Date?
    @Published var automatic = false
    @Published var navigationForward = true
    @Published var launchAtLogin = false
    @Published var startupNeedsApproval = false
    @Published var startupMessage = "登录 Mac 后自动运行，开关立即生效。"
    let portal = PortalController()
    private let wifi = WiFiService()
    private let wiredAuthentication = WiredAuthentication()
    private var lastDraftSSID = "HNPI-STU"
    private let location = CLLocationManager()
    private var saved: CampusProfile
    private var policy = AutoPolicy()
    private var timer: Timer?
    private var connectionGeneration = 0
    private var recovery = PortalRecovery()
    private var checkingInternet = false

    init(preview: Bool = false) {
        let loaded = preview ? CampusProfile() : ((try? LocalStore.load())?.profile ?? CampusProfile())
        saved = loaded; draft = loaded; automatic = loaded.automatic
        super.init()
        lastDraftSSID = loaded.isWired ? "HNPI-STU" : loaded.ssid
        if preview { return }
        refreshWiredOptions()
        refreshStartup()
        WiredNetwork.shared.onChange = { [weak self] in
            guard let self, self.saved.isWired else { return }
            self.refresh(scan: false)
        }
        location.delegate = self
        authorized = isAuthorized
        updatePermission()
        do {
            wifiPassword = try LocalStore.read(loaded.ssid, "wifi")
            portalPassword = try LocalStore.read(loaded.ssid, "portal")
        } catch { record(error.localizedDescription) }
        portal.onSubmission = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.verifyInternet() }
        }
        portal.onAuthentication = { [weak self] in
            self?.authenticated = true
            self?.record("学校认证页已确认登录成功。")
            self?.verifyInternet()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh(scan: false) }
        }
        NotificationCenter.default.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.connectionGeneration += 1; self?.policy.reset(); self?.recovery.reset(); self?.stopAuthentication(); self?.internet = nil; self?.refresh(scan: false) }
        }
        record("已载入 \(loaded.isWired ? "有线网络" : loaded.ssid) 配置。")
        DispatchQueue.main.async { [weak self] in self?.refresh(scan: false) }
    }

    var isAuthorized: Bool {
        location.authorizationStatus == .authorizedAlways
    }
    var wiredMode: Bool { saved.isWired }
    var campusConnected: Bool { saved.matchesNetwork(currentSSID: currentSSID, wiredAvailable: wiredConnected) }
    var target: String { saved.isWired ? saved.connectionLabel : saved.ssid }
    var usesSystemAuthentication: Bool { saved.usesSystemAuthentication }
    var webPortalEnabled: Bool { saved.usesWebPortal }
    var connectionLabel: String { saved.connectionLabel }
    var systemAuthenticationHelp: String {
        switch saved.wiredAuth {
        case .pppoe: return "使用 macOS 已保存的 PPPoE 服务拨号，账号密码和网卡由该系统服务管理。"
        case .dot1x: return "使用 macOS 网络设置中的 802.1X 描述文件；请启用系统自动连接，需要时在系统设置中点按「连接」。"
        case .client: return "打开已选择的学校 macOS 客户端，账号、验证码和学校专有认证在该客户端中完成。"
        case .web: return "插好网线并获取地址后，使用学校网页完成认证。"
        }
    }
    var changed: Bool { draft != saved }
    var connectionTitle: String {
        if joining { return "正在连接校园网" }
        if saved.isWired {
            guard wiredLink else { return "有线网络未连接，请插好网线或检查所选接口" }
            if !wiredConnected { return saved.usesSystemAuthentication ? "\(saved.connectionLabel) · 等待系统认证" : "有线链路已接入 · 等待获取网络地址" }
            return internet == true ? "有线校园网已连接 · 可上网" : internet == false ? "有线网络已连接 · 未联网" : "有线网络已连接 · 正在确认上网状态"
        }
        if !authorized { return "等待 Wi-Fi 访问授权" }
        if !powered { return "Wi-Fi 已关闭" }
        if campusConnected { return internet == true ? "校园网已连接 · 可上网" : internet == false ? "Wi-Fi 已连接 · 未联网" : "Wi-Fi 已连接 · 正在确认上网状态" }
        return currentSSID == nil ? "当前未连接 Wi-Fi" : "已连接 \(currentSSID!)"
    }

    func record(_ text: String) {
        status = text
    }
    func requestPermission() {
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!) }
    }
    private func updatePermission() {
        authorized = isAuthorized
        switch location.authorizationStatus {
        case .authorizedAlways: permissionText = "已获得 Wi-Fi 名称访问权限"
        case .denied, .restricted: permissionText = "请在系统设置中允许本应用使用定位服务"
        default: permissionText = "读取 Wi-Fi 名称需要定位权限"
        }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.updatePermission()
            if self.saved.isWired || self.authorized { self.refresh(scan: false) }
            else { self.currentSSID = nil; self.networks = []; self.stopAuthentication() }
        }
    }

    func refresh(scan: Bool = true) {
        guard !scanning, !joining else { return }
        if saved.isWired {
            refreshWiredConnection()
            if wiredConnected { verifyInternet(openIfOffline: automatic) }
            else if saved.usesSystemAuthentication && wiredLink && policy.shouldPrepareWired(enabled: automatic, needed: true, busy: joining, now: Date()) { prepareWired(manual: false) }
            return
        }
        guard authorized else { status = permissionText; return }
        scanning = true
        let expected = connectionGeneration
        wifi.scan(preferred: scan ? nil : saved.ssid) { [weak self] result in
            guard let self else { return }
            self.scanning = false
            guard expected == self.connectionGeneration else { self.refresh(scan: false); return }
            switch result {
            case .failure(let error): self.record("扫描失败：\(error.localizedDescription)")
            case .success(let snapshot):
                let before = self.currentSSID
                self.currentSSID = snapshot.current
                self.networks = snapshot.networks
                self.powered = snapshot.powered
                self.lastScan = Date()
                if before != snapshot.current {
                    self.connectionGeneration += 1; self.recovery.reset(); self.internet = nil; self.authenticated = false
                    self.stopAuthentication()
                    self.record(snapshot.current.map { "当前连接：\($0)" } ?? "Wi-Fi 连接已断开。")
                }
                if !snapshot.powered { self.status = "请先在系统菜单中打开 Wi-Fi。"; return }
                if snapshot.hiddenCount > 0 && snapshot.networks.isEmpty { self.status = "未能读取网络名称，请检查系统定位服务。" }
                if self.campusConnected {
                    self.verifyInternet(openIfOffline: self.automatic)
                } else if self.policy.shouldJoin(enabled: self.automatic, target: self.saved.ssid, current: snapshot.current,
                      visible: snapshot.networks.map(\.ssid), busy: self.joining, now: Date()) {
                    self.connect()
                } else if self.automatic {
                    self.status = "正在等待 \(self.saved.ssid)，每 20 秒检查一次。"
                }
            }
        }
    }

    @discardableResult func save(enable: Bool) -> Bool {
        guard !joining else { return false }
        do {
            var profile = draft
            profile.ssid = profile.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.portalURL = profile.portalURL.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.serviceOption = profile.serviceOption.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.ethernetName = profile.ethernetName.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.broadbandName = profile.broadbandName.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.automatic = enable
            try profile.validate()
            if !profile.isWired && profile.joinMode != .open && wifiPassword.isEmpty { throw AppError.message("请填写 Wi-Fi 密码。") }
            if profile.usesWebPortal && (profile.username.isEmpty || portalPassword.isEmpty) { throw AppError.message("请填写上网认证账号和密码。") }
            try LocalStore.save(profile: profile, secrets: Secrets(wifi: wifiPassword, portal: portalPassword))
            saved = profile; draft = profile; automatic = enable
            currentSSID = nil; wiredConnected = false; wiredLink = false; networks = []
            policy.reset(); recovery.reset(); connectionGeneration += 1; internet = nil; authenticated = false
            stopAuthentication()
            record(enable ? "设置已保存，自动连接已开启。" : "设置已保存。")
            refresh(scan: false)
            return true
        } catch { record(error.localizedDescription); return false }
    }

    func setAutomatic(_ enabled: Bool) {
        if enabled { _ = save(enable: true) }
        else {
            automatic = false; saved.automatic = false; draft.automatic = false
            connectionGeneration += 1; recovery.reset()
            stopAuthentication()
            do { try LocalStore.save(profile: saved); record("自动连接已暂停。") }
            catch { record("自动连接已暂停，但本地设置保存失败：\(error.localizedDescription)") }
        }
    }

    func refreshWiredOptions() {
        ethernetInterfaces = WiredSystem.interfaces()
        broadbandServices = WiredSystem.pppoeServices().compactMap { SCNetworkServiceGetName($0) as String? }.sorted()
    }
    func setDraftWired(_ wired: Bool) {
        if wired {
            if !draft.isWired { lastDraftSSID = draft.ssid }
            draft.ssid = ""
        } else if draft.isWired { draft.ssid = lastDraftSSID }
    }
    func chooseAuthenticationClient() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "选择客户端"
        if panel.runModal() == .OK, let url = panel.url { draft.authenticationClient = url.path }
    }
    private func refreshWiredConnection() {
        refreshWiredOptions()
        let linked = WiredSystem.selected(saved, from: ethernetInterfaces)?.linked == true
        let connected = WiredSystem.connected(saved)
        currentSSID = nil; networks = []; lastScan = Date()
        if wiredConnected != connected || wiredLink != linked {
            wiredConnected = connected; wiredLink = linked; connectionGeneration += 1; recovery.reset()
            internet = nil; authenticated = false; stopAuthentication()
        }
        if !linked { record("有线网络未连接，请插好网线并检查所选以太网接口。") }
        else if !connected { record(saved.usesSystemAuthentication ? "有线链路已接入，等待系统认证和分配地址。" : "有线链路已接入，等待分配网络地址。") }
    }
    private func prepareWired(manual: Bool) {
        guard saved.usesSystemAuthentication, wiredLink, !joining else { return }
        joining = true; policy.begin(at: Date())
        let expected = connectionGeneration
        record("正在准备 \(saved.connectionLabel)…")
        wiredAuthentication.prepare(saved, manual: manual) { [weak self] result in
            guard let self, expected == self.connectionGeneration else { return }
            self.joining = false
            switch result {
            case .success(let message): self.record(message)
            case .failure(let error): self.record(error.localizedDescription)
            }
            if WiredSystem.connected(self.saved) { self.verifyInternet() }
        }
    }
    func connect(manual: Bool = false) {
        guard !joining, !scanning else { return }
        if saved.isWired {
            refreshWiredConnection()
            if saved.usesSystemAuthentication {
                if wiredConnected && internet == true { verifyInternet() }
                else if wiredLink { prepareWired(manual: manual) }
            } else if wiredConnected { verifyInternet(openIfOffline: automatic, manual: manual) }
            return
        }
        guard authorized else { return }
        if manual { policy.reset() }
        if campusConnected { openPortal(); return }
        do {
            let secret = try LocalStore.read(saved.ssid, "wifi")
            joining = true
            policy.begin(at: Date())
            record("正在连接 \(saved.ssid)…")
            wifi.connect(profile: saved, password: secret) { [weak self] result in
                guard let self else { return }
                self.joining = false
                switch result {
                case .success(let ssid):
                    self.currentSSID = ssid; self.recovery.reset(); self.internet = nil; self.connectionGeneration += 1
                    self.record("已连接 \(ssid)。")
                    if self.automatic || manual { self.verifyInternet(openIfOffline: self.automatic, manual: manual) }
                case .failure(let error):
                    self.record("连接失败：\(error.localizedDescription)\(self.automatic ? " 将继续自动重试，不限制次数。" : "")")
                }
            }
        } catch { record(error.localizedDescription) }
    }

    func verifyInternet(openIfOffline: Bool = false, manual: Bool = false) {
        guard !checkingInternet, campusConnected else { return }
        checkingInternet = true
        let expected = connectionGeneration
        let expectedSSID = saved.ssid
        // Launch the first login immediately; internet verification runs afterwards.
        if manual && saved.usesWebPortal {
            openPortal()
        } else if openIfOffline && internet == nil && !portal.requiresInteraction &&
            recovery.shouldAuthenticate(enabled: automatic, portalEnabled: saved.usesWebPortal, now: Date()) {
            record("正在立即发起校园网认证…")
            openPortal(showPage: false)
        }
        Connectivity.check { [weak self] result in
            guard let self else { return }
            self.wifi.readConnection(profile: self.saved) { [weak self] connected in
                guard let self else { return }
                self.checkingInternet = false
                guard expected == self.connectionGeneration, self.saved.ssid == expectedSSID, connected else { return }
                self.internet = result == .online
                self.recovery.observe(result)
                if result == .online { self.portal.confirmInternetAccess(); self.status = "" }
                else {
                    self.authenticated = false
                    self.portal.reportInternetUnavailable()
                    self.record("百度 ping 不通，判定未联网。")
                    if self.automatic && self.saved.usesSystemAuthentication && self.policy.shouldPrepareWired(enabled: true, needed: true, busy: self.joining, now: Date()) {
                        self.prepareWired(manual: false)
                    } else if self.automatic && self.saved.autoSubmit && !self.portal.isAuthenticating &&
                        self.recovery.shouldAuthenticate(enabled: self.automatic, portalEnabled: self.saved.usesWebPortal, now: Date()) {
                        self.record("百度 ping 不通，正在重新连接校园网认证…")
                        self.openPortal(showPage: false)
                    }
                }
            }
        }
    }
    func stopAuthentication() {
        wiredAuthentication.cancel(); joining = false
        portal.stop()
    }
    func openPortal(discover: Bool = false, showPage: Bool = true) {
        guard saved.usesWebPortal else { record("当前使用系统认证，请通过当前连接方式完成认证。"); return }
        guard campusConnected else { record(saved.isWired ? "请先插好网线并启用有线网络。" : "请先连接 \(saved.ssid)。"); return }
        do {
            var profile = saved
            if discover { profile.portalURL = "" }
            let password = discover ? "" : try LocalStore.read(profile.ssid, "portal")
            recovery.begin(at: Date())
            if showPage { selectPage(.portal) }
            portal.open(profile: profile, password: password, discoveryHost: discover ? saved.validPortalURL?.host : nil)
        } catch { record(error.localizedDescription) }
    }
    func adoptAddress() {
        guard let url = URL(string: portal.address), url.host != "captive.apple.com", PortalScript.origin(url) != nil else {
            record("尚未发现有效的校园网认证地址。"); return
        }
        draft.portalURL = portal.address
        selectPage(.settings)
        record("认证地址已填入设置，保存后生效。")
    }
    func choose(_ network: VisibleNetwork) {
        draft.ssid = network.ssid
        draft.joinMode = network.security == "开放" ? .open : network.security == "企业认证" ? .enterprise : .personal
        do {
            wifiPassword = try LocalStore.read(network.ssid, "wifi")
            portalPassword = try LocalStore.read(network.ssid, "portal")
        } catch { record(error.localizedDescription) }
        selectPage(.settings)
    }
    func selectPage(_ next: Page) {
        guard page != next else { return }
        navigationForward = Page.allCases.firstIndex(of: next)! > Page.allCases.firstIndex(of: page)!
        NSApplication.shared.keyWindow?.makeFirstResponder(nil)
        page = next
    }
    func refreshStartup() {
        let state = SMAppService.mainApp.status
        launchAtLogin = state == .enabled || state == .requiresApproval
        startupNeedsApproval = state == .requiresApproval
        startupMessage = startupNeedsApproval ? "请在系统设置的登录项中允许本应用。" :
            launchAtLogin ? "已开启：登录 Mac 后在菜单栏运行。" : "登录 Mac 后在菜单栏运行，开关立即生效。"
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            refreshStartup()
        } catch {
            refreshStartup()
            startupMessage = "无法更新登录自启：\(error.localizedDescription)"
        }
    }

}

struct RootView: View {
    @ObservedObject var model: AppModel
    private let accent = Color(red: 0.04, green: 0.48, blue: 0.52)
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 11) {
                    Image(systemName: "network").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 48, height: 48).background(accent, in: RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("校园网络").font(.system(size: 19, weight: .bold))
                        Text("CAMPUS CONNECT").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                    }
                }.padding(.top, 26)
                VStack(spacing: 7) {
                    ForEach(Page.allCases, id: \.self) { page in
                        Button { model.selectPage(page) } label: {
                            HStack(spacing: 12) { Image(systemName: page == .dashboard && model.wiredMode ? "network" : page.icon).frame(width: 20); Text(page.rawValue); Spacer() }
                                .font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                                .padding(.horizontal, 14)
                                .foregroundStyle(model.page == page ? accent : Color.primary)
                                .frame(height: 45).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .background(alignment: .top) {
                    RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.1)).frame(height: 45)
                        .offset(y: CGFloat(Page.allCases.firstIndex(of: model.page)!) * 52)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let point) = phase,
                       let page = Page.atSidebarPosition(point.y) { model.selectPage(page) }
                }
                .transaction { $0.animation = nil }
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("By Ye")
                        Text("MIT 开源项目")
                    }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 6)
                    Button { model.showingFeedback.toggle() } label: {
                        HStack(spacing: 5) {
                            Text("如果遇到问题请点击：").foregroundStyle(.secondary)
                            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 16)).foregroundStyle(accent)
                        }.font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("查看问题反馈方式")
                    .popover(isPresented: $model.showingFeedback, arrowEdge: .bottom) {
                        (Text("使用中如有任何问题，请关注抖音 ") + Text("3325725312q").fontWeight(.semibold) + Text("，进群反馈。\n\n如果使用正常，也欢迎关注我的抖音，并发送你的大学名称，帮助更多小伙伴使用小助手。"))
                            .font(.system(size: 12)).lineSpacing(4).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true).padding(16).frame(width: 270)
                    }
                    Label("本地运行", systemImage: "lock.shield").font(.system(size: 12, weight: .semibold))
                    Text("账号密码保存在本机配置文件\n关闭窗口后仍可在菜单栏运行")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                }.padding(.bottom, 24)
            }.padding(.horizontal, 18).frame(width: 220).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.page.rawValue).font(.system(size: 26, weight: .bold))
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.scanning || model.joining { ProgressView().controlSize(.small) }
                    Button { model.refresh() } label: { Label("刷新网络", systemImage: "arrow.clockwise") }
                        .disabled(model.scanning || model.joining)
                }.padding(26)
                Divider()
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        ForEach(Page.allCases, id: \.self) { page in
                            Group {
                                switch page {
                                case .dashboard: dashboard
                                case .settings: settings
                                case .portal: PortalPage(model: model, portal: model.portal)
                                }
                            }
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .background(Color(nsColor: .textBackgroundColor))
                            .offset(x: CGFloat(Page.allCases.firstIndex(of: page)! - Page.allCases.firstIndex(of: model.page)!) * geometry.size.width)
                            .allowsHitTesting(page == model.page)
                            .accessibilityHidden(page != model.page)
                        }
                    }
                    .animation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.28), value: model.page)
                }.clipped()
                Divider()
                HStack {
                    if !model.status.isEmpty {
                        Circle().fill(model.campusConnected && model.internet == true ? accent : Color.secondary).frame(width: 6, height: 6)
                        Text(model.status).font(.system(size: 11)).lineLimit(2)
                    }
                    Spacer()
                    Text("v2.0.3 · macOS").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(.horizontal, 24).padding(.vertical, 12)
            }.background(Color(nsColor: .textBackgroundColor))
        }.frame(minWidth: 980, minHeight: 700).tint(accent).textSelection(.disabled)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshStartup() }
    }
    var subtitle: String {
        switch model.page {
        case .dashboard: return "当前连接方式：\(model.connectionLabel)。"
        case .settings: return "设置目标网络、账号和上网认证方式。"
        case .portal: return model.usesSystemAuthentication ? "通过系统或学校客户端完成认证。" : "在校园网内打开登录页并填写已保存的凭据。"
        }
    }
    func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }
    var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                card {
                    HStack(alignment: .top, spacing: 18) {
                        Image(systemName: model.wiredMode ? "network" : model.campusConnected ? "wifi.circle.fill" : "wifi.circle")
                            .font(.system(size: 54)).foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.connectionTitle).font(.system(size: 22, weight: .semibold))
                            Text("目标校园网  \(model.target)").font(.system(size: 13)).foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                Button("立即连接") { model.connect(manual: true) }.buttonStyle(.borderedProminent)
                                    .disabled((!model.wiredMode && !model.authorized) || model.scanning || model.joining)
                                Button("修改配置") { model.selectPage(.settings) }
                            }.padding(.top, 4)
                        }
                        Spacer()
                    }
                }
                card {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("自动连接与认证").font(.system(size: 15, weight: .semibold))
                            Text(model.wiredMode ? model.systemAuthenticationHelp : "发现 \(model.target) 后连接，并使用已保存账号登录。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("自动连接", isOn: Binding(get: { model.automatic }, set: { model.setAutomatic($0) })).labelsHidden().toggleStyle(.switch)
                    }
                }
                if !model.wiredMode && !model.authorized {
                    card {
                        HStack {
                            Image(systemName: "location.circle").font(.system(size: 25)).foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("允许读取附近 Wi-Fi").font(.system(size: 14, weight: .semibold))
                                Text(model.permissionText).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("授权定位") { model.requestPermission() }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(model.wiredMode ? "有线模式" : "附近网络").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        if let date = model.lastScan { Text("更新于 \(date.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    if model.networks.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: model.wiredMode ? "network" : "antenna.radiowaves.left.and.right").font(.system(size: 28)).foregroundStyle(.secondary)
                            Text(model.wiredMode ? model.systemAuthenticationHelp : model.authorized ? "点击刷新扫描附近网络" : "授权定位后显示真实网络列表").font(.system(size: 13)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 28)
                    } else {
                        ForEach(model.networks) { network in
                            HStack(spacing: 12) {
                                Image(systemName: "wifi").foregroundStyle(network.ssid == model.target ? accent : .secondary).frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(network.ssid).font(.system(size: 13, weight: .medium))
                                        if network.ssid == model.target { Text("校园网").font(.system(size: 10, weight: .semibold)).foregroundStyle(accent).padding(.horizontal, 6).padding(.vertical, 3).background(accent.opacity(0.1), in: Capsule()) }
                                    }
                                    Text("\(network.security) · \(network.signal) dBm").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if network.ssid == model.currentSSID { Text("已连接").font(.system(size: 11)).foregroundStyle(accent) }
                                Button("设为目标") { model.choose(network) }.controlSize(.small).disabled(model.joining)
                            }.padding(.vertical, 9)
                            Divider()
                        }
                    }
                }
            }.padding(26)
        }
    }
    func field(_ title: String, text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium))
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }
    var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                card {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("登录时自动启动").font(.system(size: 15, weight: .semibold))
                            Text(model.startupMessage).font(.system(size: 12)).foregroundStyle(.secondary)
                            if model.startupNeedsApproval {
                                Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                            }
                        }
                        Spacer()
                        Toggle("登录时自动启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
                card {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("校园网络", systemImage: "network").font(.system(size: 16, weight: .semibold))
                        Picker("连接方式", selection: Binding(get: { model.draft.isWired }, set: { model.setDraftWired($0) })) {
                            Text("Wi-Fi 无线网络").tag(false)
                            Text("有线网络（以太网）").tag(true)
                        }.pickerStyle(.segmented)
                        if model.draft.isWired {
                            Picker("有线认证方式", selection: $model.draft.wiredAuth) {
                                ForEach(WiredAuth.allCases) { Text($0.title).tag($0) }
                            }
                            if model.draft.wiredAuth != .pppoe {
                                field("以太网接口（可留空自动选择）", text: $model.draft.ethernetName, prompt: "例如 en5")
                                Text(model.ethernetInterfaces.isEmpty ? "尚未检测到以太网接口，请接入网卡。" : "可用接口：" + model.ethernetInterfaces.map(\.title).joined(separator: "、"))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            if model.draft.wiredAuth == .pppoe {
                                field("已保存的 PPPoE 服务名称", text: $model.draft.broadbandName, prompt: "与 macOS 网络设置中的名称完全一致")
                                Text(model.broadbandServices.isEmpty ? "请先在系统网络设置中创建 PPPoE 服务并保存凭据。" : "已有 PPPoE 服务：" + model.broadbandServices.joined(separator: "、"))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            if model.draft.wiredAuth == .dot1x {
                                Text("先按学校要求安装 802.1X 描述文件、配置证书和凭据，并在系统网络设置中启用自动连接；手动认证时在系统设置中点按「连接」。")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            if model.draft.wiredAuth == .client {
                                field("学校认证客户端", text: $model.draft.authenticationClient, prompt: "选择已安装的 .app")
                                Button("选择客户端…") { model.chooseAuthenticationClient() }
                            }
                            if model.draft.wiredAuth != .web {
                                Button("打开 macOS 网络设置") { NSWorkspace.shared.open(WiredAuthentication.networkSettings) }
                            }
                        } else {
                            field("Wi-Fi 名称", text: $model.draft.ssid, prompt: "输入校园 Wi-Fi 名称")
                            Picker("Wi-Fi 安全方式", selection: $model.draft.joinMode) {
                                ForEach(JoinMode.allCases) { Text($0.title).tag($0) }
                            }.pickerStyle(.segmented)
                            if model.draft.joinMode == .enterprise { field("Wi-Fi 企业认证用户名", text: $model.draft.wifiUsername) }
                            if model.draft.joinMode != .open {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("Wi-Fi 连接密码").font(.system(size: 12, weight: .medium))
                                    SecureField("输入连接密码", text: $model.wifiPassword).textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                        Text(model.draft.isWired ? "有线模式无需填写 Wi-Fi 名称或授予定位权限。修改后保存，实际连接才会使用所选方式。" : "Wi-Fi 名称精确匹配；学号和密码在下方网页认证中填写。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if !model.draft.usesSystemAuthentication {
                card {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("连接后进行上网认证", isOn: $model.draft.portalEnabled).font(.system(size: 15, weight: .semibold))
                        if model.draft.portalEnabled {
                            field("认证页面地址", text: $model.draft.portalURL, prompt: "http://192.168.0.123")
                            HStack(alignment: .top, spacing: 16) {
                                field("学号 / 上网账号", text: $model.draft.username, prompt: "输入账号")
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("上网密码").font(.system(size: 12, weight: .medium))
                                    SecureField("输入上网密码", text: $model.portalPassword).textFieldStyle(.roundedBorder)
                                }
                            }
                            field("运营商 / 服务选项", text: $model.draft.serviceOption, prompt: "例如：中国移动 或 联通接入服务")
                            Text("填写认证网页中的完整选项名称，例如中国移动、中国联通、中国电信或联通接入服务。网页需要选择运营商时请填写，保存后重新认证；网页没有此选项时留空。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Toggle("自动填写后点击登录", isOn: $model.draft.autoSubmit)
                        }
                    }
                }
                }
                HStack(spacing: 12) {
                    Button("保存并开启自动连接") { _ = model.save(enable: true) }.buttonStyle(.borderedProminent)
                    Button("保存设置") { _ = model.save(enable: model.automatic) }
                    Spacer()
                    Text("密码保存在本机").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("修改后点击保存。下次打开会沿用已保存的账号和密码。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(26).disabled(model.joining)
        }
    }

}

struct PortalPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var portal: PortalController
    var body: some View {
        if model.usesSystemAuthentication {
            VStack(alignment: .leading, spacing: 16) {
                Label(model.connectionLabel, systemImage: "network").font(.system(size: 20, weight: .semibold))
                Text(model.systemAuthenticationHelp).foregroundStyle(.secondary)
                HStack {
                    Button("开始系统认证") { model.connect(manual: true) }.buttonStyle(.borderedProminent).disabled(model.joining)
                    Button("检查上网状态") { model.verifyInternet() }.disabled(!model.campusConnected)
                    Button("打开网络设置") { NSWorkspace.shared.open(WiredAuthentication.networkSettings) }
                }
                Spacer()
            }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("立即认证") { model.openPortal() }.buttonStyle(.borderedProminent).disabled(!model.campusConnected)
                Button("探测认证地址") { model.openPortal(discover: true) }.disabled(!model.campusConnected)
                Button("检查上网状态") { model.verifyInternet() }.disabled(!model.campusConnected)
                Spacer()
                if portal.loading { ProgressView().controlSize(.small) }
            }
            Text(portal.message).font(.system(size: 12)).foregroundStyle(.secondary)
            if !portal.address.isEmpty {
                HStack {
                    Text(portal.address).font(.system(size: 11, design: .monospaced)).lineLimit(1).textSelection(.disabled)
                    Spacer()
                    Button("使用当前页面地址") { model.adoptAddress() }.controlSize(.small)
                }
            }
            PortalWebView(controller: portal).frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
        }.padding(24)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let loginLaunch = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
        if loginLaunch {
            DispatchQueue.main.async {
                NSApplication.shared.windows.filter { $0.canBecomeMain }.forEach { $0.orderOut(nil) }
                NSApplication.shared.hide(nil)
            }
        } else { NSApplication.shared.activate(ignoringOtherApps: true) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
        return true
    }
}

@main struct CampusConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: AppModel
    init() {
        if CommandLine.arguments.contains("--configure-from-stdin") {
            do {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                let input = try JSONSerialization.jsonObject(with: data) as? [String: String] ?? [:]
                guard let username = input["username"], let password = input["password"], !username.isEmpty, !password.isEmpty else {
                    throw AppError.message("账号和密码不能为空。")
                }
                var profile = try LocalStore.load().profile
                profile.username = username; profile.automatic = false
                let wifi = try LocalStore.read(profile.ssid, "wifi")
                try LocalStore.save(profile: profile, secrets: Secrets(wifi: wifi, portal: password))
                print("Default profile saved to local configuration. Automatic connection disabled.")
                exit(0)
            } catch { fputs("Configuration failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        _model = StateObject(wrappedValue: AppModel())
    }
    var body: some Scene {
        WindowGroup("校园网助手", id: "main") { RootView(model: model) }.defaultSize(width: 1060, height: 760)
        MenuBarExtra("校园网络", systemImage: model.wiredMode ? "network" : "wifi") {
            MenuBarControls(model: model)
        }
    }
}

struct MenuBarControls: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.connectionTitle)
        Button("打开主窗口") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Toggle("自动连接", isOn: Binding(get: { model.automatic }, set: { model.setAutomatic($0) }))
        Button("刷新网络") { model.refresh() }
        Divider()
        Button("退出") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}
