import Foundation
import Testing
@testable import BentosVmmMacos

@Suite("DiskManager")
struct DiskManagerTests {
    private func tmpPath() -> String {
        "/tmp/bentos-disk-test-\(UUID().uuidString)"
    }

    @Test func cloneCreatesFile() throws {
        let dir = tmpPath()
        let golden = "\(dir)/golden.img"
        let dest = "\(dir)/root.img"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: URL(fileURLWithPath: golden))

        try DiskManager.cloneRootfs(goldenPath: golden, destPath: dest)
        #expect(FileManager.default.fileExists(atPath: dest))

        let attrs = try FileManager.default.attributesOfItem(atPath: dest)
        #expect(attrs[.size] as? Int == 4096)
    }

    @Test func expandedFileIsLarger() throws {
        let dir = tmpPath()
        let golden = "\(dir)/golden.img"
        let dest = "\(dir)/root.img"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: URL(fileURLWithPath: golden))

        try DiskManager.cloneRootfs(goldenPath: golden, destPath: dest, expandTo: 1_048_576)

        let attrs = try FileManager.default.attributesOfItem(atPath: dest)
        let size = attrs[.size] as? Int ?? 0
        #expect(size == 1_048_576)
    }

    @Test func cloneMissingGoldenThrows() throws {
        let dir = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        #expect(throws: VmmApiError.self) {
            try DiskManager.cloneRootfs(
                goldenPath: "\(dir)/nonexistent.img",
                destPath: "\(dir)/root.img")
        }
    }
}
