import Foundation
import Network

// A loopback-only bridge for this app's approved campus host. Outbound sockets
// require the selected Wi-Fi or wired Ethernet interface, so captive authentication can finish
// even when a packet-tunnel VPN captures the default route. No TLS interception.
final class CampusProxy {
    private let queue = DispatchQueue(label: "local.campusconnect.portal-bridge")
    private var listener: NWListener?
    private var pipes: [UUID: CampusPipe] = [:]
    private var generation = 0
    private var approvedHosts: Set<String> = []

    // Admit only main-document destinations observed by the native WebView.
    func allowNavigation(host: String, completion: @escaping () -> Void) {
        queue.async { [self] in
            approvedHosts.insert(host.lowercased())
            DispatchQueue.main.async(execute: completion)
        }
    }

    func start(host: String, additionalHosts: Set<String> = [], interfaceType: NWInterface.InterfaceType = .wifi, requiredInterface: NWInterface? = nil, completion: @escaping (Result<UInt16, Error>) -> Void) {
        queue.async { [self] in
            self.stopOnQueue()
            self.approvedHosts = Set(additionalHosts.map { $0.lowercased() }).union([host.lowercased()])
            let expected = self.generation
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                var delivered = false
                listener.stateUpdateHandler = { state in
                    guard expected == self.generation, !delivered else { return }
                    if case .ready = state, let port = listener.port {
                        delivered = true
                        DispatchQueue.main.async { completion(.success(port.rawValue)) }
                    } else if case .failed(let error) = state {
                        delivered = true
                        DispatchQueue.main.async { completion(.failure(error)) }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, expected == self.generation else { connection.cancel(); return }
                    let id = UUID()
                    let pipe = CampusPipe(client: connection, allowsHost: { [weak self] in self?.approvedHosts.contains($0) == true }, interfaceType: interfaceType, requiredInterface: requiredInterface, queue: self.queue) { [weak self] in self?.pipes.removeValue(forKey: id) }
                    self.pipes[id] = pipe
                    pipe.start()
                }
                listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 3) {
                    guard expected == self.generation, !delivered else { return }
                    delivered = true; self.stopOnQueue()
                    DispatchQueue.main.async { completion(.failure(AppError.message("本地网络探测初始化超时。"))) }
                }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    func stop() { queue.async { self.stopOnQueue() } }
    private func stopOnQueue() {
        generation += 1
        approvedHosts.removeAll()
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        let old = Array(pipes.values); pipes.removeAll()
        for pipe in old { pipe.close() }
    }
}

private final class CampusPipe {
    let client: NWConnection
    let allowsHost: (String) -> Bool
    let interfaceType: NWInterface.InterfaceType
    let requiredInterface: NWInterface?
    let queue: DispatchQueue
    let onClose: () -> Void
    var upstream: NWConnection?
    var header = Data()
    var closed = false
    init(client: NWConnection, allowsHost: @escaping (String) -> Bool, interfaceType: NWInterface.InterfaceType, requiredInterface: NWInterface?, queue: DispatchQueue, onClose: @escaping () -> Void) {
        self.client = client; self.allowsHost = allowsHost; self.interfaceType = interfaceType; self.requiredInterface = requiredInterface; self.queue = queue; self.onClose = onClose
    }
    func start() {
        client.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
        }
        client.start(queue: queue)
        receiveHeader()
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.upstream == nil else { return }; self.close()
        }
    }
    func close() {
        guard !closed else { return }
        closed = true; client.cancel(); upstream?.cancel(); onClose()
    }
    func receiveHeader() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.header.append(data) }
            guard self.header.count <= 65536, error == nil else { self.close(); return }
            if let range = self.header.range(of: Data("\r\n\r\n".utf8)) {
                let prefix = self.header[..<range.lowerBound]
                let tail = Data(self.header[range.upperBound...])
                self.begin(header: String(decoding: prefix, as: UTF8.self), tail: tail)
                self.header = Data()
            } else if complete { self.close() }
            else { self.receiveHeader() }
        }
    }
    func begin(header: String, tail: Data) {
        let lines = header.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard parts.count == 3 else { reject(); return }
        let tunnel = parts[0] == "CONNECT"
        let target = tunnel ? URL(string: "http://" + parts[1]) : URL(string: parts[1])
        guard let target, let host = target.host?.lowercased(), allowsHost(host),
              target.user == nil, target.password == nil else { reject(); return }
        let port = target.port ?? (target.scheme == "https" ? 443 : 80)
        guard port > 0, port <= 65535 else { reject(); return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = interfaceType
        parameters.requiredInterface = requiredInterface
        parameters.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: parameters)
        upstream = connection
        var ready = false
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready where !ready:
                ready = true
                if tunnel {
                    self.client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { error in
                        guard error == nil else { self.close(); return }
                        self.forwardInitial(tail)
                    })
                } else {
                    let components = URLComponents(url: target, resolvingAgainstBaseURL: false)
                    let path = components?.percentEncodedPath.isEmpty == false ? components!.percentEncodedPath : "/"
                    let query = components?.percentEncodedQuery.map { "?" + $0 } ?? ""
                    let retained = lines.dropFirst().filter { line in
                        let key = line.split(separator: ":", maxSplits: 1).first?.lowercased() ?? ""
                        return !["connection", "proxy-connection", "proxy-authorization"].contains(key)
                    }
                    let rewritten = "\(parts[0]) \(path)\(query) \(parts[2])\r\n" + retained.joined(separator: "\r\n") + "\r\nConnection: close\r\n\r\n"
                    self.forwardInitial(Data(rewritten.utf8) + tail)
                }
            case .failed: self.close()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in if !ready { self?.close() } }
    }
    func reject() {
        client.send(content: Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in self.close() })
    }
    func forwardInitial(_ data: Data) {
        guard let upstream, !closed else { return }
        upstream.send(content: data.isEmpty ? nil : data, completion: .contentProcessed { error in
            guard error == nil else { self.close(); return }
            self.pump(from: self.client, to: upstream)
            self.pump(from: upstream, to: self.client)
        })
    }
    func pump(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil else { self.close(); return }
            to.send(content: data, contentContext: complete ? .finalMessage : .defaultMessage, isComplete: complete, completion: .contentProcessed { error in
                if error != nil || complete { self.close() }
                else { self.pump(from: from, to: to) }
            })
        }
    }
}
