import Foundation
import Testing
@testable import BentosVmmMacos

@Suite("Console")
struct ConsoleTests {

    @MainActor
    private func makeManager() throws -> (MachineManager, String) {
        let dir = "/tmp/bentos-vm-test-\(UUID().uuidString)"
        let store = MachineStore(baseDir: dir)
        let mgr = MachineManager(store: store)
        return (mgr, dir)
    }

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private let testConfig = BentosVmConfig(
        name: "test",
        cpuCount: 2,
        memoryBytes: 2_147_483_648,
        boot: BootConfig(kernel: "bundled://bentos-arm64-Image"),
        disks: [DiskConfig(role: .root, sizeBytes: 1_073_741_824)]
    )

    // MARK: - M4.1: Console acquire/release

    @Test @MainActor func acquireConsoleOnStoppedMachineThrows() throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let machine = try mgr.create(config: testConfig)
        do {
            let _ = try mgr.acquireConsole(machine.id)
            Issue.record("Should have thrown — machine is stopped")
        } catch let err as VmmApiError {
            #expect(err.code == "conflict")
        }
    }

    @Test @MainActor func acquireConsoleOnNonexistentThrows() throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        do {
            let _ = try mgr.acquireConsole("no-such-machine")
            Issue.record("Should have thrown")
        } catch let err as VmmApiError {
            #expect(err.code == "machine_not_found")
        }
    }

    @Test @MainActor func releaseConsoleIsIdempotent() throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let machine = try mgr.create(config: testConfig)
        // Release on a machine that has no console connected — should not throw
        mgr.releaseConsole(machine.id)
        mgr.releaseConsole(machine.id)
        // Also releasing nonexistent machine should not throw
        mgr.releaseConsole("nonexistent")
    }

    // MARK: - M4.1: HTTP console endpoint

    @Test func consoleOnStoppedMachineReturnsConflict() async throws {
        try await withTestServer { socketPath in
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

            // Console on stopped machine without WS upgrade -> 409
            let (status, json) = try await httpRequest(
                socketPath: socketPath, method: "GET", path: "/api/v1/machines/\(id)/console")
            #expect(status == 409)
            #expect(json?["code"] as? String == "conflict")
        }
    }

    @Test func consoleOnNonexistentMachineReturns404() async throws {
        try await withTestServer { socketPath in
            let (status, json) = try await httpRequest(
                socketPath: socketPath, method: "GET", path: "/api/v1/machines/no-such/console")
            #expect(status == 404)
            #expect(json?["code"] as? String == "machine_not_found")
        }
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
}
