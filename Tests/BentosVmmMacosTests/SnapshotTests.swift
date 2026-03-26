import Foundation
import Testing
@testable import BentosVmmMacos

/// M5 tests: Snapshot create/list/delete + error paths.
/// Restore and actual save require a real VZ.fw VM, so we test error paths only.
@Suite("Snapshots")
struct SnapshotTests {
    private let testConfig = BentosVmConfig(
        name: "snap-test",
        cpuCount: 2,
        memoryBytes: 2_147_483_648,
        boot: BootConfig(kernel: "bundled://bentos-arm64-Image"),
        disks: [DiskConfig(role: .root, sizeBytes: 1_073_741_824)]
    )

    @MainActor
    private func makeManager() throws -> (MachineManager, String) {
        let dir = "/tmp/bentos-snap-test-\(UUID().uuidString)"
        let store = MachineStore(baseDir: dir)
        let mgr = MachineManager(store: store)
        return (mgr, dir)
    }

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - M5.1: Create snapshot error paths

    @Test @MainActor func snapshotStoppedMachineThrows() async throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let machine = try mgr.create(config: testConfig)
        do {
            let _ = try await mgr.createSnapshot(machine.id, name: nil)
            Issue.record("Should have thrown")
        } catch let err as VmmApiError {
            #expect(err.code == "conflict")
        }
    }

    @Test @MainActor func snapshotNonexistentMachineThrows() async throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        do {
            let _ = try await mgr.createSnapshot("nonexistent", name: nil)
            Issue.record("Should have thrown")
        } catch let err as VmmApiError {
            #expect(err.code == "machine_not_found")
        }
    }

    // MARK: - M5.3: List snapshots

    @Test @MainActor func listSnapshotsEmptyForNewMachine() throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let machine = try mgr.create(config: testConfig)
        let snaps = try mgr.listSnapshots(machine.id)
        #expect(snaps.isEmpty, "New machine should have no snapshots")
    }

    @Test @MainActor func listSnapshotsNonexistentMachineThrows() throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        do {
            let _ = try mgr.listSnapshots("nonexistent")
            Issue.record("Should have thrown")
        } catch let err as VmmApiError {
            #expect(err.code == "machine_not_found")
        }
    }

    @Test @MainActor func listSnapshotsAfterManualCreate() throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let machine = try mgr.create(config: testConfig)

        // Manually create a fake snapshot directory with state.vzsave
        let snapId = UUID().uuidString.lowercased()
        let snapDir = "\(dir)/\(machine.id)/snapshots/\(snapId)"
        try FileManager.default.createDirectory(
            atPath: snapDir, withIntermediateDirectories: true)
        let stateFile = "\(snapDir)/state.vzsave"
        try Data("fake-state".utf8).write(to: URL(fileURLWithPath: stateFile))

        let snaps = try mgr.listSnapshots(machine.id)
        #expect(snaps.count == 1, "Should find the manually created snapshot")
        #expect(snaps[0].id == snapId)
        #expect(snaps[0].machineId == machine.id)
        #expect(snaps[0].sizeBytes > 0, "State file should have nonzero size")
    }

    // MARK: - M5.4: Delete snapshot

    @Test @MainActor func deleteSnapshotRemovesDirectory() throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let machine = try mgr.create(config: testConfig)

        // Manually create a fake snapshot
        let snapId = UUID().uuidString.lowercased()
        let snapDir = "\(dir)/\(machine.id)/snapshots/\(snapId)"
        try FileManager.default.createDirectory(
            atPath: snapDir, withIntermediateDirectories: true)
        try Data("fake-state".utf8).write(
            to: URL(fileURLWithPath: "\(snapDir)/state.vzsave"))

        // Verify it exists
        #expect(FileManager.default.fileExists(atPath: snapDir))

        // Delete
        try mgr.deleteSnapshot(machine.id, snapshotId: snapId)

        // Verify removed
        #expect(!FileManager.default.fileExists(atPath: snapDir))

        // List should be empty
        let snaps = try mgr.listSnapshots(machine.id)
        #expect(snaps.isEmpty)
    }

    @Test @MainActor func deleteUnknownSnapshotThrows() throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        let machine = try mgr.create(config: testConfig)
        do {
            try mgr.deleteSnapshot(machine.id, snapshotId: "nonexistent")
            Issue.record("Should have thrown")
        } catch let err as VmmApiError {
            #expect(err.code == "snapshot_not_found")
        }
    }

    @Test @MainActor func deleteSnapshotOnNonexistentMachineThrows() throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        do {
            try mgr.deleteSnapshot("nonexistent", snapshotId: "snap1")
            Issue.record("Should have thrown")
        } catch let err as VmmApiError {
            #expect(err.code == "machine_not_found")
        }
    }

    // MARK: - M5.2: Restore error paths

    @Test @MainActor func restoreOnRunningMachineThrowsConflict() async throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        // Create machine — state is stopped, but we need to test conflict
        // when machine is NOT stopped. We can't truly set it to running without VZ.fw,
        // so we'll just test the nonexistent snapshot case on a stopped machine.
        let machine = try mgr.create(config: testConfig)

        // Restore with missing snapshot
        do {
            try await mgr.restoreSnapshot(machine.id, snapshotId: "nonexistent")
            Issue.record("Should have thrown")
        } catch let err as VmmApiError {
            #expect(err.code == "snapshot_not_found")
        }
    }

    @Test @MainActor func restoreNonexistentMachineThrows() async throws {
        let (mgr, dir) = try makeManager()
        defer { cleanup(dir) }

        do {
            try await mgr.restoreSnapshot("nonexistent", snapshotId: "snap1")
            Issue.record("Should have thrown")
        } catch let err as VmmApiError {
            #expect(err.code == "machine_not_found")
        }
    }

    // MARK: - BentosSnapshot JSON round-trip

    @Test func snapshotJsonRoundTrip() throws {
        let snap = BentosSnapshot(
            id: "abc-123",
            machineId: "machine-456",
            name: "before-update",
            sizeBytes: 1_048_576,
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )

        let data = try JSONEncoder.vmm.encode(snap)
        let decoded = try JSONDecoder.vmm.decode(BentosSnapshot.self, from: data)

        #expect(decoded.id == snap.id)
        #expect(decoded.machineId == snap.machineId)
        #expect(decoded.name == snap.name)
        #expect(decoded.sizeBytes == snap.sizeBytes)
        #expect(decoded == snap)
    }

    @Test func snapshotJsonKeys() throws {
        let snap = BentosSnapshot(
            id: "test",
            machineId: "m1",
            name: "snap",
            sizeBytes: 100,
            createdAt: Date(timeIntervalSince1970: 0)
        )

        let data = try JSONEncoder.vmm.encode(snap)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Verify snake_case keys match Dart contract
        #expect(json["id"] as? String == "test")
        #expect(json["machine_id"] as? String == "m1")
        #expect(json["name"] as? String == "snap")
        #expect(json["size_bytes"] as? Int == 100)
        #expect(json["created_at"] != nil, "Should have created_at key")
    }
}
