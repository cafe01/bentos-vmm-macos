import Foundation
import Testing
@testable import BentosVmmMacos

@Suite("MachineStore")
struct MachineStoreTests {
    private func makeStore() throws -> (MachineStore, String) {
        let dir = "/tmp/bentos-store-test-\(UUID().uuidString)"
        let store = MachineStore(baseDir: dir)
        return (store, dir)
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

    @Test func writeAndReadRoundTrips() throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        try store.save(id: "m1", config: testConfig)
        let loaded = try store.load(id: "m1")
        #expect(loaded == testConfig)
    }

    @Test func loadOnFreshInitReturnsEmpty() throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        let all = try store.loadAll()
        #expect(all.isEmpty)
    }

    @Test func createThenLoadAll() throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        try store.save(id: "a", config: testConfig)
        try store.save(id: "b", config: testConfig)
        let all = try store.loadAll()
        #expect(all.count == 2)
        #expect(Set(all.map(\.id)) == ["a", "b"])
    }

    @Test func deleteThenLoadReturnsNil() throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        try store.save(id: "m1", config: testConfig)
        try store.delete(id: "m1")
        let loaded = try store.load(id: "m1")
        #expect(loaded == nil)
    }

    @Test func deleteNonexistentThrows() throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        #expect(throws: VmmApiError.self) {
            try store.delete(id: "nope")
        }
    }

    @Test func createsDirectoryTree() throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        try store.save(id: "m1", config: testConfig)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: "\(dir)/m1/config.json"))
        #expect(fm.fileExists(atPath: "\(dir)/m1/snapshots"))
        #expect(fm.fileExists(atPath: "\(dir)/m1/logs"))
    }

    @Test func concurrentCreatesGetDistinctDirs() throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        try store.save(id: "x1", config: testConfig)
        try store.save(id: "x2", config: testConfig)

        #expect(store.exists(id: "x1"))
        #expect(store.exists(id: "x2"))
        #expect(store.machineDir("x1") != store.machineDir("x2"))
    }
}
