import Foundation
import Testing
@testable import BentosVmmMacos

/// Integration tests: real HTTP over Unix socket.
struct HttpServerTests {
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

    private func httpGet(socketPath: String, path: String) async throws -> (Int, [String: Any]?) {
        try await httpRequest(socketPath: socketPath, method: "GET", path: path)
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

    // MARK: - M0.2: Ping

    @Test func pingReturns200WithCorrectJSON() async throws {
        try await withTestServer { socketPath in
            let (status, json) = try await httpGet(socketPath: socketPath, path: "/api/v1/vmm/ping")
            #expect(status == 200)
            #expect(json?["healthy"] as? Bool == true)
            #expect(json?["machine_count"] as? Int == 0)
            #expect(json?["uptime_seconds"] is Int)
        }
    }

    @Test func unknownPathReturns404WithErrorEnvelope() async throws {
        try await withTestServer { socketPath in
            let (status, json) = try await httpGet(socketPath: socketPath, path: "/api/v1/nonexistent")
            #expect(status == 404)
            #expect(json?["code"] as? String == "not_found")
        }
    }

    @Test func connectionRefusedWhenServerNotRunning() async throws {
        let deadSocket = "/tmp/bentos-vmm-dead-\(UUID().uuidString).sock"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = [
            "--unix-socket", deadSocket,
            "-s", "--connect-timeout", "1",
            "-o", "/dev/null", "-w", "%{http_code}",
            "http://localhost/api/v1/vmm/ping"
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(proc.terminationStatus != 0 || output.trimmingCharacters(in: .whitespaces) == "000")
    }

    // MARK: - M0.3: Stubs return 501

    @Test func stubEndpointsReturn501() async throws {
        try await withTestServer { socketPath in
            // Only truly unimplemented endpoints (snapshots)
            let stubs: [(String, String)] = [
                ("POST", "/api/v1/machines/test-id/snapshots"),
                ("GET", "/api/v1/machines/test-id/snapshots"),
                ("DELETE", "/api/v1/machines/test-id/snapshots/snap-1"),
                ("POST", "/api/v1/machines/test-id/snapshots/snap-1/restore"),
            ]
            for (method, path) in stubs {
                let (status, json) = try await httpRequest(
                    socketPath: socketPath, method: method, path: path)
                #expect(status == 501,
                        "\(method) \(path) should return 501, got \(status)")
                #expect(json?["code"] as? String == "not_implemented",
                        "\(method) \(path) should return not_implemented error code")
            }
        }
    }

    @Test func wrongMethodReturns405() async throws {
        try await withTestServer { socketPath in
            let (status, json) = try await httpRequest(
                socketPath: socketPath, method: "POST", path: "/api/v1/vmm/ping")
            #expect(status == 405)
            #expect(json?["code"] as? String == "method_not_allowed")
        }
    }

    // MARK: - M1.3: Machine CRUD via HTTP

    @Test func capabilitiesReturns200() async throws {
        try await withTestServer { socketPath in
            let (status, json) = try await httpGet(socketPath: socketPath, path: "/api/v1/vmm/capabilities")
            #expect(status == 200)
            #expect(json?["backend_name"] as? String == "bentos-vmm-macos")
            #expect(json?["hot_resize"] as? Bool == false)
            #expect(json?["snapshot"] as? Bool == true)
        }
    }

    @Test func createAndGetMachine() async throws {
        try await withTestServer { socketPath in
            let config = """
            {"name":"test","cpu_count":2,"memory_bytes":2147483648,
             "boot":{"kernel":"bundled://bentos-arm64-Image","command_line":"console=hvc0"},
             "disks":[{"role":"root","size_bytes":1073741824,"read_only":false}],
             "network":{"mode":"nat"},
             "shared_directories":[],"enable_vsock":true,"enable_entropy":true,
             "enable_balloon":true,"enable_rosetta":false}
            """.data(using: .utf8)!

            // Create
            let (createStatus, createJson) = try await httpRequest(
                socketPath: socketPath, method: "POST", path: "/api/v1/machines", body: config)
            #expect(createStatus == 200)
            let machineId = createJson?["id"] as? String
            #expect(machineId != nil, "Machine should have an id")
            #expect(createJson?["state"] as? String == "stopped")

            // Get
            let (getStatus, getJson) = try await httpGet(
                socketPath: socketPath, path: "/api/v1/machines/\(machineId!)")
            #expect(getStatus == 200)
            #expect(getJson?["id"] as? String == machineId)
            let configResult = getJson?["config"] as? [String: Any]
            #expect(configResult?["name"] as? String == "test")
        }
    }

    @Test func listMachines() async throws {
        try await withTestServer { socketPath in
            // Empty list
            let (listStatus, listJson) = try await httpGet(
                socketPath: socketPath, path: "/api/v1/machines")
            #expect(listStatus == 200)
            let machines = listJson?["machines"] as? [[String: Any]]
            #expect(machines?.count == 0)

            // Create one
            let config = """
            {"name":"test","cpu_count":1,"memory_bytes":1073741824,
             "boot":{"kernel":"k","command_line":"c"},
             "disks":[{"role":"root","size_bytes":512,"read_only":false}],
             "network":{"mode":"nat"},
             "shared_directories":[],"enable_vsock":true,"enable_entropy":true,
             "enable_balloon":true,"enable_rosetta":false}
            """.data(using: .utf8)!
            let (_, _) = try await httpRequest(
                socketPath: socketPath, method: "POST", path: "/api/v1/machines", body: config)

            // List shows one
            let (_, listJson2) = try await httpGet(
                socketPath: socketPath, path: "/api/v1/machines")
            let machines2 = listJson2?["machines"] as? [[String: Any]]
            #expect(machines2?.count == 1)
        }
    }

    @Test func deleteMachine() async throws {
        try await withTestServer { socketPath in
            let config = """
            {"name":"del","cpu_count":1,"memory_bytes":1073741824,
             "boot":{"kernel":"k","command_line":"c"},
             "disks":[{"role":"root","size_bytes":512,"read_only":false}],
             "network":{"mode":"nat"},
             "shared_directories":[],"enable_vsock":true,"enable_entropy":true,
             "enable_balloon":true,"enable_rosetta":false}
            """.data(using: .utf8)!

            let (_, createJson) = try await httpRequest(
                socketPath: socketPath, method: "POST", path: "/api/v1/machines", body: config)
            let id = createJson!["id"] as! String

            // Delete
            let (delStatus, _) = try await httpRequest(
                socketPath: socketPath, method: "DELETE", path: "/api/v1/machines/\(id)")
            #expect(delStatus == 204)

            // Get after delete returns 404
            let (getStatus, getJson) = try await httpGet(
                socketPath: socketPath, path: "/api/v1/machines/\(id)")
            #expect(getStatus == 404)
            #expect(getJson?["code"] as? String == "machine_not_found")
        }
    }

    @Test func getUnknownMachineReturns404() async throws {
        try await withTestServer { socketPath in
            let (status, json) = try await httpGet(
                socketPath: socketPath, path: "/api/v1/machines/nonexistent")
            #expect(status == 404)
            #expect(json?["code"] as? String == "machine_not_found")
        }
    }

    @Test func deleteUnknownReturns404() async throws {
        try await withTestServer { socketPath in
            let (status, json) = try await httpRequest(
                socketPath: socketPath, method: "DELETE", path: "/api/v1/machines/nonexistent")
            #expect(status == 404)
            #expect(json?["code"] as? String == "machine_not_found")
        }
    }

    @Test func postInvalidJsonReturns400() async throws {
        try await withTestServer { socketPath in
            let (status, json) = try await httpRequest(
                socketPath: socketPath, method: "POST", path: "/api/v1/machines",
                body: "not json".data(using: .utf8)!)
            #expect(status == 400)
            #expect(json?["code"] as? String == "bad_request")
        }
    }

    @Test func pingShowsMachineCount() async throws {
        try await withTestServer { socketPath in
            let config = """
            {"name":"mc","cpu_count":1,"memory_bytes":1073741824,
             "boot":{"kernel":"k","command_line":"c"},
             "disks":[{"role":"root","size_bytes":512,"read_only":false}],
             "network":{"mode":"nat"},
             "shared_directories":[],"enable_vsock":true,"enable_entropy":true,
             "enable_balloon":true,"enable_rosetta":false}
            """.data(using: .utf8)!
            let (_, _) = try await httpRequest(
                socketPath: socketPath, method: "POST", path: "/api/v1/machines", body: config)

            let (_, json) = try await httpGet(socketPath: socketPath, path: "/api/v1/vmm/ping")
            #expect(json?["machine_count"] as? Int == 1)
        }
    }
}
