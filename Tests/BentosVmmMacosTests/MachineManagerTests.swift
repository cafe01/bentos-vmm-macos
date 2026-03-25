import Foundation
import Testing
@testable import BentosVmmMacos

@Suite("MachineManager")
struct MachineManagerTests {
    private let testConfig = BentosVmConfig(
        name: "test",
        cpuCount: 2,
        memoryBytes: 2_147_483_648,
        boot: BootConfig(kernel: "bundled://bentos-arm64-Image"),
        disks: [DiskConfig(role: .root, sizeBytes: 1_073_741_824)]
    )

    @MainActor
    private func makeManager() throws -> (MachineManager, String) {
        let dir = "/tmp/bentos-mgr-test-\(UUID().uuidString)"
        let store = MachineStore(baseDir: dir)
        let mgr = MachineManager(store: store)
        return (mgr, dir)
    }

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test @MainActor func createReturnsStopped() throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let machine = try mgr.create(config: testConfig)
        #expect(machine.state == .stopped)
        #expect(machine.config.name == "test")
        #expect(!machine.id.isEmpty)
    }

    @Test @MainActor func getById() throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let created = try mgr.create(config: testConfig)
        let fetched = try mgr.get(created.id)
        #expect(fetched.id == created.id)
        #expect(fetched.config.name == created.config.name)
    }

    @Test @MainActor func listReturnsAll() throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let _ = try mgr.create(config: testConfig)
        let _ = try mgr.create(config: testConfig)
        #expect(mgr.list().count == 2)
    }

    @Test @MainActor func deleteRemoves() throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let machine = try mgr.create(config: testConfig)
        try mgr.delete(machine.id)
        #expect(mgr.list().isEmpty)
    }

    @Test @MainActor func getAfterDeleteThrows() throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let machine = try mgr.create(config: testConfig)
        try mgr.delete(machine.id)
        #expect(throws: VmmApiError.self) {
            try mgr.get(machine.id)
        }
    }

    @Test @MainActor func createPopulatesTimestamps() throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let before = Date()
        let machine = try mgr.create(config: testConfig)
        let after = Date()
        #expect(machine.createdAt >= before)
        #expect(machine.createdAt <= after)
        #expect(machine.updatedAt >= before)
    }

    @Test @MainActor func loadPersistedOnRestart() throws {
        let dir = "/tmp/bentos-mgr-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // First "session": create a machine
        let store1 = MachineStore(baseDir: dir)
        let mgr1 = MachineManager(store: store1)
        let created = try mgr1.create(config: testConfig)

        // Second "session": new manager, load persisted
        let store2 = MachineStore(baseDir: dir)
        let mgr2 = MachineManager(store: store2)
        try mgr2.loadPersisted()
        let loaded = mgr2.list()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == created.id)
        #expect(loaded[0].state == .stopped)
        #expect(loaded[0].config.name == "test")
    }
}
