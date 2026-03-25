import Foundation
import Virtualization

/// Central machine registry. All VM operations go through here.
/// @MainActor because VZ.fw requires main queue.
@MainActor
final class MachineManager {
    var machines: [String: ManagedMachine] = [:]
    let store: MachineStore

    init(store: MachineStore) {
        self.store = store
    }

    // MARK: - Lifecycle: load/create/get/list/delete

    func loadPersisted() throws {
        let persisted = try store.loadAll()
        for (id, config) in persisted {
            machines[id] = ManagedMachine(id: id, config: config)
        }
    }

    func create(config: BentosVmConfig) throws -> ManagedMachine {
        let id = UUID().uuidString.lowercased()

        // Clone golden rootfs if root disk is specified
        let machineDir = store.machineDir(id)
        try store.save(id: id, config: config)

        if let rootDisk = config.disks.first(where: { $0.role == .root }) {
            let goldenPath = DiskManager.goldenRootfsPath()
            if FileManager.default.fileExists(atPath: goldenPath) {
                try DiskManager.cloneRootfs(
                    goldenPath: goldenPath,
                    destPath: "\(machineDir)/root.img",
                    expandTo: rootDisk.sizeBytes > 0 ? rootDisk.sizeBytes : nil
                )
            }
        }

        let machine = ManagedMachine(id: id, config: config)
        machines[id] = machine
        return machine
    }

    func get(_ id: String) throws -> ManagedMachine {
        guard let machine = machines[id] else {
            throw VmmApiError.machineNotFound(id)
        }
        return machine
    }

    func list() -> [ManagedMachine] {
        Array(machines.values)
    }

    func delete(_ id: String) throws {
        guard let machine = machines[id] else {
            throw VmmApiError.machineNotFound(id)
        }
        guard machine.state == .stopped || machine.state == .error else {
            throw VmmApiError.conflict(
                "Machine '\(id)' must be stopped before deletion (current state: \(machine.state))")
        }
        try store.delete(id: id)
        machines.removeValue(forKey: id)
    }

    // MARK: - VM Operations

    /// Start a stopped machine. Builds VZ config, creates VM, starts it.
    func start(_ id: String) async throws {
        guard var machine = machines[id] else {
            throw VmmApiError.machineNotFound(id)
        }
        guard machine.state == .stopped || machine.state == .error else {
            throw VmmApiError.conflict("Machine '\(id)' is already \(machine.state)")
        }

        let machineDir = store.machineDir(id)

        // Transition: stopped -> starting
        machine.state = .starting
        machine.error = nil
        machine.updatedAt = Date()
        machines[id] = machine

        do {
            let (vzConfig, consoleIO) = try ConfigTranslator.translate(
                machine.config, machineDir: machineDir)
            let vm = VZVirtualMachine(configuration: vzConfig)
            let delegate = MachineDelegate(machineId: id, manager: self)
            vm.delegate = delegate

            nonisolated(unsafe) let unsafeVm = vm
            try await unsafeVm.start()

            // Transition: starting -> running
            machine.state = .running
            machine.startedAt = Date()
            machine.updatedAt = Date()
            machine.vm = vm
            machine.delegate = delegate
            machine.consoleIO = consoleIO
            machines[id] = machine
        } catch let apiErr as VmmApiError {
            machine.state = .error
            machine.error = MachineError(code: apiErr.code, message: apiErr.message)
            machine.updatedAt = Date()
            machines[id] = machine
            throw apiErr
        } catch {
            machine.state = .error
            machine.error = MachineError(code: "start_failed", message: error.localizedDescription)
            machine.updatedAt = Date()
            machines[id] = machine
            throw VmmApiError(code: "start_failed", message: error.localizedDescription, status: .internalServerError)
        }
    }

    /// Stop a running machine. Graceful with timeout, or force.
    func stop(_ id: String, force: Bool = false) async throws {
        guard var machine = machines[id] else {
            throw VmmApiError.machineNotFound(id)
        }
        guard machine.state == .running || machine.state == .paused else {
            throw VmmApiError.conflict("Machine '\(id)' is not running (current state: \(machine.state))")
        }
        guard let vm = machine.vm else {
            throw VmmApiError.internalError("Machine '\(id)' has no VM instance")
        }

        // Transition: running -> stopping
        machine.state = .stopping
        machine.updatedAt = Date()
        machines[id] = machine

        if force {
            try await vm.stop()
        } else {
            // Graceful: requestStop + 30s timeout, fallback to force
            try vm.requestStop()
            let deadline = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(500))
                if machines[id]?.state == .stopped { return }
            }
            // Timeout: force stop
            if machines[id]?.state != .stopped {
                try await vm.stop()
            }
        }

        // Finalize
        machine = machines[id] ?? machine
        machine.state = .stopped
        machine.vm = nil
        machine.delegate = nil
        machine.consoleIO = nil
        machine.startedAt = nil
        machine.updatedAt = Date()
        machines[id] = machine
    }

    /// Pause a running machine.
    func pause(_ id: String) async throws {
        guard var machine = machines[id] else {
            throw VmmApiError.machineNotFound(id)
        }
        guard machine.state == .running else {
            throw VmmApiError.conflict("Machine '\(id)' must be running to pause (current state: \(machine.state))")
        }
        guard let vm = machine.vm else {
            throw VmmApiError.internalError("Machine '\(id)' has no VM instance")
        }

        try await vm.pause()
        machine.state = .paused
        machine.updatedAt = Date()
        machines[id] = machine
    }

    /// Resume a paused machine.
    func resume(_ id: String) async throws {
        guard var machine = machines[id] else {
            throw VmmApiError.machineNotFound(id)
        }
        guard machine.state == .paused else {
            throw VmmApiError.conflict("Machine '\(id)' must be paused to resume (current state: \(machine.state))")
        }
        guard let vm = machine.vm else {
            throw VmmApiError.internalError("Machine '\(id)' has no VM instance")
        }

        try await vm.resume()
        machine.state = .running
        machine.updatedAt = Date()
        machines[id] = machine
    }

    /// Press power button (ACPI signal). Guest may ignore.
    func pressePowerButton(_ id: String) throws {
        guard let machine = machines[id] else {
            throw VmmApiError.machineNotFound(id)
        }
        guard machine.state == .running else {
            throw VmmApiError.conflict("Machine '\(id)' must be running for power button")
        }
        guard let vm = machine.vm else {
            throw VmmApiError.internalError("Machine '\(id)' has no VM instance")
        }
        try vm.requestStop()
    }

    /// Resize: save updated config, return restart_required.
    func resize(_ id: String, request: ResizeRequest) throws -> ResizeResult {
        guard var machine = machines[id] else {
            throw VmmApiError.machineNotFound(id)
        }

        var updated = machine.config
        if let cpus = request.cpuCount {
            updated = BentosVmConfig(
                name: updated.name,
                cpuCount: cpus,
                memoryBytes: updated.memoryBytes,
                boot: updated.boot,
                disks: updated.disks,
                network: updated.network,
                sharedDirectories: updated.sharedDirectories,
                enableVsock: updated.enableVsock,
                enableEntropy: updated.enableEntropy,
                enableBalloon: updated.enableBalloon,
                enableRosetta: updated.enableRosetta
            )
        }
        if let mem = request.memoryBytes {
            updated = BentosVmConfig(
                name: updated.name,
                cpuCount: updated.cpuCount,
                memoryBytes: mem,
                boot: updated.boot,
                disks: updated.disks,
                network: updated.network,
                sharedDirectories: updated.sharedDirectories,
                enableVsock: updated.enableVsock,
                enableEntropy: updated.enableEntropy,
                enableBalloon: updated.enableBalloon,
                enableRosetta: updated.enableRosetta
            )
        }

        machine.config = updated
        machine.updatedAt = Date()
        machines[id] = machine
        try store.save(id: id, config: updated)

        return .restartRequired(
            message: "Machine must be restarted for resize to take effect.")
    }
}
