import Foundation
import Darwin

// Shared cancellation state is protected by lock; each instance runs one query at a time.
final class CodexClient: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        if let active, active.isRunning { active.terminate() }
        lock.unlock()
    }

    // One short-lived official child per refresh, with no shell and no TCP listener.
    // The child manages authentication; this client never reads credential storage.
    func fetch(executable: URL, timeout: TimeInterval = 25) throws -> QuotaResponse {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio",
            "-c", "analytics.enabled=false",
            "-c", "otel.exporter=\"none\"",
            "-c", "otel.trace_exporter=\"none\"",
            "-c", "otel.metrics_exporter=\"none\""]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["RUST_LOG"] = "off"
        process.environment = environment
        lock.lock()
        if cancelled { lock.unlock(); throw QuotaError.cancelled }
        if active != nil { lock.unlock(); throw QuotaError.queryFailed }
        do { try process.run() } catch { lock.unlock(); throw QuotaError.launchFailed }
        active = process
        lock.unlock()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let stopAt = Date().addingTimeInterval(1)
            while process.isRunning && Date() < stopAt { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
            lock.lock(); active = nil; lock.unlock()
        }

        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            do { try input.fileHandleForWriting.write(contentsOf: data) }
            catch { throw QuotaError.disconnected }
        }
        try send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "codex_quota", "title": "Codex Usage Monitor", "version": "0.1.0"],
            "capabilities": ["experimentalApi": false]]])

        let fd = output.fileHandleForReading.fileDescriptor
        var pending = Data()
        var didInitialize = false
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { throw QuotaError.cancelled }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 200)
            if ready < 0 { if errno == EINTR { continue }; throw QuotaError.disconnected }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = read(fd, &bytes, bytes.count)
            guard count > 0 else { throw QuotaError.disconnected }
            pending.append(contentsOf: bytes.prefix(count))
            guard pending.count <= 2_000_000 else { throw QuotaError.invalidResponse }
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                // Ignore all unsolicited events and requests; never execute server-supplied actions.
                guard object["method"] == nil, let id = object["id"] as? Int, id == 1 || id == 2 else { continue }
                if let failure = object["error"] as? [String: Any] {
                    let message = (failure["message"] as? String ?? "").lowercased()
                    if ["401", "unauthorized", "not logged", "authentication"].contains(where: message.contains) {
                        throw QuotaError.authentication
                    }
                    throw QuotaError.queryFailed
                }
                guard let result = object["result"] else { throw QuotaError.invalidResponse }
                if id == 1 && !didInitialize {
                    didInitialize = true
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 2, "method": "account/rateLimits/read", "params": ["excludeResetCreditDetails": true]])
                } else if id == 2 && didInitialize {
                    do {
                        return try JSONDecoder().decode(QuotaResponse.self, from: JSONSerialization.data(withJSONObject: result))
                    } catch { throw QuotaError.invalidResponse }
                }
            }
        }
        throw QuotaError.timeout
    }
}
