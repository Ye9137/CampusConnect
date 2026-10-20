import Foundation
import Darwin

// Match a normal system ping: one ICMP reply from Baidu means online.
// This uses the system route (including a VPN if the system routes it there).
enum Connectivity {
    static func check(completion: @escaping (InternetStatus) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = runPing(executable: "/sbin/ping", arguments: ["-n", "-c", "1", "-W", "3000", "-t", "4", "www.baidu.com"])
            DispatchQueue.main.async { completion(result) }
        }
    }
    static func runPing(executable: String, arguments: [String], timeout: TimeInterval = 4) -> InternetStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do { try process.run() } catch { return .unavailable }
        if completed.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if completed.wait(timeout: .now() + 1) == .timedOut && process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            return .unavailable
        }
        return process.terminationReason == .exit && process.terminationStatus == 0 ? .online : .unavailable
    }
}
