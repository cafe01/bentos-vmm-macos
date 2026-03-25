import Foundation
import Testing
@testable import BentosVmmMacos

/// M3 tests: VM lifecycle error paths (no real kernel needed).
@Suite("VM Lifecycle")
struct VmLifecycleTests {
    private let testConfig = BentosVmConfig(
        name: "test",
        cpuCount: 2,
        memoryBytes: 2_147_483_648,
        boot: BootConfig(kernel: "bundled://bentos-arm64-Image"),
        disks: [DiskConfig(role: .root, sizeBytes: 1_073_741_824)]
    )

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

    @Test @MainActor func startNonexistentThrows() async throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        do {
            try await mgr.start("nonexistent")
            Issue.record("Should have thrown")
        } catch let err as VmmApiError {
            #expect(err.code == "machine_not_found")
        }
    }

    @Test @MainActor func stopStoppedMachineThrows() async throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let machine = try mgr.create(config: testConfig)
        do {
            try await mgr.stop(machine.id)
            Issue.record("Should have thrown")
        } catch let err as VmmApiError {
            #expect(err.code == "conflict")
        }
    }

    @Test @MainActor func pauseStoppedMachineThrows() async throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let machine = try mgr.create(config: testConfig)
        do {
            try await mgr.pause(machine.id)
            Issue.record("Should have thrown")
        } catch let err as VmmApiError {
            #expect(err.code == "conflict")
        }
    }

    @Test @MainActor func resumeStoppedMachineThrows() async throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let machine = try mgr.create(config: testConfig)
        do {
            try await mgr.resume(machine.id)
            Issue.record("Should have thrown")
        } catch let err as VmmApiError {
            #expect(err.code == "conflict")
        }
    }

    @Test @MainActor func resizeReturnsRestartRequired() throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let machine = try mgr.create(config: testConfig)
        let result = try mgr.resize(machine.id, request: ResizeRequest(cpuCount: 4, memoryBytes: nil))
        if case .restartRequired(let msg) = result {
            #expect(msg.contains("restart"))
        } else {
            Issue.record("Expected restart_required, got \(result)")
        }

        // Verify config updated
        let updated = try mgr.get(machine.id)
        #expect(updated.config.cpuCount == 4)
        #expect(updated.config.memoryBytes == testConfig.memoryBytes)
    }

    @Test @MainActor func resizeUpdatesPersistence() throws {
        let dir = "/tmp/bentos-vm-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let store = MachineStore(baseDir: dir)
        let mgr = MachineManager(store: store)
        let machine = try mgr.create(config: testConfig)
        let _ = try mgr.resize(machine.id, request: ResizeRequest(cpuCount: 8, memoryBytes: 4_294_967_296))

        // Reload from disk
        let loaded = try store.load(id: machine.id)
        #expect(loaded?.cpuCount == 8)
        #expect(loaded?.memoryBytes == 4_294_967_296)
    }

    @Test @MainActor func startWithMissingDiskImageErrors() async throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let machine = try mgr.create(config: testConfig)
        // Start should fail — no kernel binary and no golden rootfs
        do {
            try await mgr.start(machine.id)
            Issue.record("Should have thrown — no kernel/rootfs available")
        } catch {
            // Expected: either disk_not_found or start_failed
            let m = try mgr.get(machine.id)
            #expect(m.state == .error)
            #expect(m.error != nil)
        }
    }
}
