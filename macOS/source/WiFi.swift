import Foundation
import CoreWLAN
import Network

// The path reports a usable Ethernet link, independently of internet reachability.
// All access and notifications occur on the main queue.
final class WiredNetwork {
    static let shared = WiredNetwork()
    private let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    private(set) var available = false
    private(set) var interfaces: [NWInterface] = []
    var onChange: (() -> Void)?
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.available = path.status == .satisfied
            self.interfaces = path.availableInterfaces
            self.onChange?()
        }
        monitor.start(queue: .main)
    }
}


struct VisibleNetwork: Identifiable {
    let ssid: String
    let signal: Int
    let security: String
    var id: String { ssid }
    var bars: Int { signal >= -55 ? 3 : signal >= -70 ? 2 : 1 }
}

struct WiFiSnapshot {
    var current: String?
    var powered: Bool
    var networks: [VisibleNetwork]
    var hiddenCount: Int
}

final class WiFiService {
    private let queue = DispatchQueue(label: "local.campusconnect.wifi", qos: .utility)
    func readConnection(profile: CampusProfile, completion: @escaping (Bool) -> Void) {
        if profile.isWired { completion(WiredSystem.connected(profile)); return }
        readCurrent { completion(profile.matchesNetwork(currentSSID: $0, wiredAvailable: false)) }
    }
    func readCurrent(completion: @escaping (String?) -> Void) {
        queue.async {
            let ssid = Self.currentSSID
            DispatchQueue.main.async { completion(ssid) }
        }
    }
    func scan(preferred: String? = nil, forceScan: Bool = false, completion: @escaping (Result<WiFiSnapshot, Error>) -> Void) {
        queue.async {
            let result: Result<WiFiSnapshot, Error> = Result {
                guard let interface = CWWiFiClient.shared().interface() else { throw AppError.message("未找到 Wi-Fi 接口。") }
                guard interface.powerOn() else { return WiFiSnapshot(current: nil, powered: false, networks: [], hiddenCount: 0) }
                // An existing campus connection can authenticate without a full radio scan.
                let networks = preferred != nil && interface.ssid() == preferred && !forceScan
                    ? (interface.cachedScanResults() ?? [])
                    : preferred != nil ? try interface.scanForNetworks(withName: preferred!) : try interface.scanForNetworks(withSSID: nil)
                var unique: [String: VisibleNetwork] = [:]
                var hidden = 0
                for n in networks {
                    guard let ssid = n.ssid, !ssid.isEmpty else { hidden += 1; continue }
                    let security = n.supportsSecurity(.none) ? "开放" :
                        (n.supportsSecurity(.enterprise) || n.supportsSecurity(.wpa2Enterprise) || n.supportsSecurity(.wpa3Enterprise)) ? "企业认证" : "加密"
                    if (unique[ssid]?.signal ?? -999) < n.rssiValue {
                        unique[ssid] = VisibleNetwork(ssid: ssid, signal: n.rssiValue, security: security)
                    }
                }
                return WiFiSnapshot(current: interface.ssid(), powered: true,
                    networks: unique.values.sorted { $0.signal > $1.signal }, hiddenCount: hidden)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func connect(profile: CampusProfile, password: String, allowSwitch: Bool = false, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            let result: Result<String, Error> = Result {
                guard let interface = CWWiFiClient.shared().interface() else { throw AppError.message("未找到 Wi-Fi 接口。") }
                if interface.ssid() == profile.ssid { return profile.ssid }
                if !allowSwitch, let current = interface.ssid(), !current.isEmpty { throw AppError.message("当前连接其他网络，自动连接已暂停。") }
                let candidates = try interface.scanForNetworks(withName: profile.ssid)
                    .filter { $0.ssid == profile.ssid }.sorted { $0.rssiValue > $1.rssiValue }
                guard let network = candidates.first else { throw AppError.message("暂未发现 \(profile.ssid)，请确认已到校园网络覆盖范围。") }
                if interface.ssid() == profile.ssid { return profile.ssid }
                if !allowSwitch, let current = interface.ssid(), !current.isEmpty { throw AppError.message("网络已变化，自动连接已暂停。") }
                switch profile.joinMode {
                case .open:
                    guard network.supportsSecurity(.none) else { throw AppError.message("这个网络需要 Wi-Fi 密码或企业认证，请修改连接方式。") }
                    try interface.associate(to: network, password: nil)
                case .personal:
                    guard !password.isEmpty else { throw AppError.message("请先保存 Wi-Fi 密码。") }
                    try interface.associate(to: network, password: password)
                case .enterprise:
                    guard !password.isEmpty else { throw AppError.message("请先保存企业认证密码。") }
                    try interface.associate(toEnterpriseNetwork: network, identity: nil, username: profile.wifiUsername, password: password)
                }
                guard interface.ssid() == profile.ssid else { throw AppError.message("系统尚未确认连接成功，请刷新后重试。") }
                return profile.ssid
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    static var currentSSID: String? { CWWiFiClient.shared().interface()?.ssid() }
}
