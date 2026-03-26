import Foundation
import Testing
@testable import BentosVmmMacos

@Suite("SSE Events")
struct SSETests {

    // MARK: - M4.2: SSE endpoint

    @Test func eventsEndpointReturnsSSEContentType() async throws {
        try await withTestServer { socketPath in
            // Create a machine first
            let config = """
            {"name":"test","cpu_count":1,"memory_bytes":1073741824,
             "boot":{"kernel":"k","command_line":"c"},
             "disks":[{"role":"root","size_bytes":512,"read_only":false}],
             "network":{"mode":"nat"},
             "shared_directories":[],"enable_vsock":true,"enable_entropy":true,
             "enable_balloon":true,"enable_rosetta":false}
            """.data(using: .utf8)!
            let (_, createJson) = try await httpRequest(
                socketPath: socketPath, method: "POST", path: "/api/v1/machines", body: config)
            let id = createJson!["id"] as! String

            // GET events — check content type
            let (contentType, status) = try await httpSSEContentType(
                socketPath: socketPath, path: "/api/v1/machines/\(id)/events")
            #expect(status == 200)
            #expect(contentType?.contains("text/event-stream") == true)
        }
    }

    @Test func eventsOnNonexistentMachineReturns404() async throws {
        try await withTestServer { socketPath in
            let (status, json) = try await httpRequest(
                socketPath: socketPath, method: "GET", path: "/api/v1/machines/no-such/events")
            #expect(status == 404)
            #expect(json?["code"] as? String == "machine_not_found")
        }
    }

    @Test @MainActor func stateTransitionEmitsEvent() async throws {
        let dir = "/tmp/bentos-vm-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let store = MachineStore(baseDir: dir)
        let mgr = MachineManager(store: store)
        let testConfig = BentosVmConfig(
            name: "test",
            cpuCount: 2,
            memoryBytes: 2_147_483_648,
            boot: BootConfig(kernel: "bundled://bentos-arm64-Image"),
            disks: [DiskConfig(role: .root, sizeBytes: 1_073_741_824)]
        )
        let machine = try mgr.create(config: testConfig)
        let bus = try mgr.eventBus(for: machine.id)

        // Subscribe to events
        let (stream, subId) = bus.subscribe()

        // Trigger a state transition (start will fail, but that emits events too)
        do { try await mgr.start(machine.id) } catch { /* expected */ }

        // Should get stopped -> starting, then starting -> error
        var it = stream.makeAsyncIterator()
        let first = await it.next()
        if case .stateChanged(_, let prev, let next) = first {
            #expect(prev == .stopped)
            #expect(next == .starting)
        } else {
            Issue.record("Expected stateChanged event, got \(String(describing: first))")
        }

        let second = await it.next()
        if case .stateChanged(_, let prev, let next) = second {
            #expect(prev == .starting)
            #expect(next == .error)
        } else {
            Issue.record("Expected stateChanged event, got \(String(describing: second))")
        }

        bus.unsubscribe(subId)
    }

    @Test @MainActor func multipleSubscribersReceiveEvent() async throws {
        let dir = "/tmp/bentos-vm-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let store = MachineStore(baseDir: dir)
        let mgr = MachineManager(store: store)
        let testConfig = BentosVmConfig(
            name: "test",
            cpuCount: 2,
            memoryBytes: 2_147_483_648,
            boot: BootConfig(kernel: "bundled://bentos-arm64-Image"),
            disks: [DiskConfig(role: .root, sizeBytes: 1_073_741_824)]
        )
        let machine = try mgr.create(config: testConfig)
        let bus = try mgr.eventBus(for: machine.id)

        let (stream1, sub1) = bus.subscribe()
        let (stream2, sub2) = bus.subscribe()
        #expect(bus.subscriberCount == 2)

        // Trigger event
        do { try await mgr.start(machine.id) } catch { /* expected */ }

        var it1 = stream1.makeAsyncIterator()
        var it2 = stream2.makeAsyncIterator()
        let r1 = await it1.next()
        let r2 = await it2.next()
        #expect(r1 != nil)
        #expect(r2 != nil)

        bus.unsubscribe(sub1)
        bus.unsubscribe(sub2)
    }

    @Test @MainActor func eventJsonMatchesDartFormat() async throws {
        let event = MachineEvent.stateChanged(
            timestamp: Date(), previousState: .stopped, newState: .starting)
        let data = try JSONEncoder.vmm.encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "state_changed")
        #expect(json["previous_state"] as? String == "stopped")
        #expect(json["new_state"] as? String == "starting")
        #expect(json["timestamp"] is String)
    }

    // MARK: - Test helpers

    @MainActor
    private func withTestServer(
        _ body: @Sendable (String) async throws -> Void
    ) async throws {
        let socketPath = "/tmp/bentos-vmm-test-\(UUID().uuidString).sock"
        let tmpDir = "/tmp/bentos-vmm-test-data-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let store = MachineStore(baseDir: tmpDir)
        let manager = MachineManager(store: store)
        let server = HttpServer(socketPath: socketPath, manager: manager)
        let handle = try await server.start()

        try await Task.sleep(for: .milliseconds(100))

        do {
            try await body(socketPath)
        } catch {
            try? await handle.shutdown()
            throw error
        }
        try await handle.shutdown()
    }

    private func httpRequest(
        socketPath: String,
        method: String,
        path: String,
        body: Data? = nil
    ) async throws -> (Int, [String: Any]?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var args = [
            "--unix-socket", socketPath,
            "-s",
            "-w", "\n%{http_code}",
            "-X", method,
        ]
        if let body {
            args += ["-H", "Content-Type: application/json", "-d", String(data: body, encoding: .utf8)!]
        }
        args.append("http://localhost\(path)")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let lines = output.components(separatedBy: "\n")
        let statusCode = Int(lines.last(where: { !$0.isEmpty }) ?? "0") ?? 0
        let bodyStr = lines.dropLast().filter { !$0.isEmpty }.joined(separator: "\n")
        let bodyData = Data(bodyStr.utf8)
        let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        return (statusCode, json)
    }

    /// Fetch SSE endpoint with a short timeout and return content-type + status.
    private func httpSSEContentType(
        socketPath: String,
        path: String
    ) async throws -> (String?, Int) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = [
            "--unix-socket", socketPath,
            "-s",
            "--max-time", "1",
            "-D", "-",
            "-o", "/dev/null",
            "-w", "\n%{http_code}",
            "http://localhost\(path)"
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let lines = output.components(separatedBy: "\n")
        let statusCode = Int(lines.last(where: { !$0.isEmpty }) ?? "0") ?? 0

        let contentType = lines
            .first(where: { $0.lowercased().hasPrefix("content-type:") })
            .map { String($0.dropFirst("Content-Type:".count)).trimmingCharacters(in: .whitespaces) }

        return (contentType, statusCode)
    }
}
