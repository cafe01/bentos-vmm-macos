import Foundation

/// Filesystem persistence for machine configs.
/// Path: ~/Library/Application Support/com.bentos.vmm-macos/machines/{id}/
final class MachineStore: @unchecked Sendable {
    let baseDir: String

    /// Use default Application Support path, or override for tests.
    init(baseDir: String? = nil) {
        if let baseDir {
            self.baseDir = baseDir
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.path
            self.baseDir = "\(appSupport)/com.bentos.vmm-macos/machines"
        }
    }

    private var fm: FileManager { FileManager.default }

    /// Persist a machine config. Creates directory tree: config.json, snapshots/, logs/.
    func save(id: String, config: BentosVmConfig) throws {
        let dir = machineDir(id)
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: "\(dir)/snapshots", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: "\(dir)/logs", withIntermediateDirectories: true)

        let data = try JSONEncoder.vmm.encode(config)
        try data.write(to: URL(fileURLWithPath: "\(dir)/config.json"))
    }

    /// Load a single machine config by ID. Returns nil if not found.
    func load(id: String) throws -> BentosVmConfig? {
        let path = "\(machineDir(id))/config.json"
        guard fm.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder.vmm.decode(BentosVmConfig.self, from: data)
    }

    /// Load all persisted machine IDs and their configs.
    func loadAll() throws -> [(id: String, config: BentosVmConfig)] {
        guard fm.fileExists(atPath: baseDir) else { return [] }
        let entries = try fm.contentsOfDirectory(atPath: baseDir)
        var result: [(id: String, config: BentosVmConfig)] = []
        for entry in entries {
            let configPath = "\(baseDir)/\(entry)/config.json"
            guard fm.fileExists(atPath: configPath) else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let config = try JSONDecoder.vmm.decode(BentosVmConfig.self, from: data)
            result.append((id: entry, config: config))
        }
        return result
    }

    /// Delete a machine's entire directory.
    func delete(id: String) throws {
        let dir = machineDir(id)
        guard fm.fileExists(atPath: dir) else {
            throw VmmApiError.machineNotFound(id)
        }
        try fm.removeItem(atPath: dir)
    }

    /// Check if a machine directory exists.
    func exists(id: String) -> Bool {
        fm.fileExists(atPath: "\(machineDir(id))/config.json")
    }

    func machineDir(_ id: String) -> String {
        "\(baseDir)/\(id)"
    }
}
