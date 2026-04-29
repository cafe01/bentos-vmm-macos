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
            let goldenPath = config.rootfsPath ?? DiskManager.goldenRootfsPath()
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

    // MARK: - State transition helper

    /// Transition machine state and emit event.
    private func transition(_ id: String, _ machine: inout ManagedMachine, to newState: MachineState) {
        let prev = machine.state
        machine.state = newState
        machine.updatedAt = Date()
        machines[id] = machine
        machine.eventBus.emit(.stateChanged(
            timestamp: Date(), previousState: prev, newState: newState))
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
        machine.error = nil
        transition(id, &machine, to: .starting)

        do {
            let (vzConfig, consoleIO) = try ConfigTranslator.translate(
                machine.config, machineDir: machineDir)
            let vm = VZVirtualMachine(configuration: vzConfig)
            let delegate = MachineDelegate(machineId: id, manager: self)
            vm.delegate = delegate

            nonisolated(unsafe) let unsafeVm = vm
            try await unsafeVm.start()

            // Transition: starting -> running
            machine.startedAt = Date()
            machine.vm = vm
            machine.delegate = delegate
            machine.consoleIO = consoleIO
            transition(id, &machine, to: .running)

        } catch let apiErr as VmmApiError {
            machine.error = MachineError(code: apiErr.code, message: apiErr.message)
            transition(id, &machine, to: .error)
            throw apiErr
        } catch {
            machine.error = MachineError(code: "start_failed", message: error.localizedDescription)
            transition(id, &machine, to: .error)
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
        transition(id, &machine, to: .stopping)

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
        machine.vm = nil
        machine.delegate = nil
        machine.consoleIO = nil
        machine.consoleConnected = false
        machine.startedAt = nil
        transition(id, &machine, to: .stopped)
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
        transition(id, &machine, to: .paused)
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
        transition(id, &machine, to: .running)
    }

    /// Press power button (ACPI signal). Guest may ignore.
    func pressPowerButton(_ id: String) throws {
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

    // MARK: - Apply

    /// Replace a machine's config atomically. Persists immediately; takes effect on next start.
    func apply(_ id: String, config: BentosVmConfig) throws -> ManagedMachine {
        guard var machine = machines[id] else {
            throw VmmApiError.machineNotFound(id)
        }
        machine.config = config
        machine.updatedAt = Date()
        machines[id] = machine
        try store.save(id: id, config: config)
        return machine
    }

    // MARK: - Console

    /// Acquire console connection. Returns ConsoleIO or throws 409 if already connected.
    func acquireConsole(_ id: String) throws -> ConsoleIO {
        guard var machine = machines[id] else {
            throw VmmApiError.machineNotFound(id)
        }
        guard machine.state == .running || machine.state == .paused else {
            throw VmmApiError.conflict("Machine '\(id)' must be running for console (current state: \(machine.state))")
        }
        guard !machine.consoleConnected else {
            throw VmmApiError.conflict("Console already connected to machine '\(id)'")
        }
        guard let consoleIO = machine.consoleIO else {
            throw VmmApiError.internalError("Machine '\(id)' has no console I/O")
        }
        machine.consoleConnected = true
        machines[id] = machine
        return consoleIO
    }

    /// Release console connection.
    func releaseConsole(_ id: String) {
        guard var machine = machines[id] else { return }
        machine.consoleConnected = false
        machines[id] = machine
    }

    // MARK: - Exec (vsock)

    /// Open a vsock connection and return a Sendable box. Machine must be running.
    /// Wraps vsockConnect so the non-Sendable VZVirtioSocketConnection never leaves @MainActor.
    func vsockConnectBox(_ id: String, port: UInt32) async throws -> VsockConnectionBox {
        let conn = try await vsockConnect(id, port: port)
        return VsockConnectionBox(conn)
    }

    /// Open a vsock connection to the guest on [port]. Machine must be running.
    /// Returns the VZVirtioSocketConnection on success.
    func vsockConnect(_ id: String, port: UInt32) async throws -> VZVirtioSocketConnection {
        guard let machine = machines[id] else {
            throw VmmApiError.machineNotFound(id)
        }
        guard machine.state == .running else {
            throw VmmApiError.conflict(
                "Machine '\(id)' must be running for exec (current state: \(machine.state))")
        }
        guard let vm = machine.vm else {
            throw VmmApiError.internalError("Machine '\(id)' has no VM instance")
        }
        guard let vsockDev = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw VmmApiError.conflict(
                "Machine '\(id)' does not have vsock enabled")
        }

        // VZVirtioSocketConnection is not Sendable. Capture the device and port,
        // then perform the connect outside @MainActor to avoid the sending violation.
        nonisolated(unsafe) let dev = vsockDev
        let p = port
        return try await withCheckedThrowingContinuation { cont in
            dev.connect(toPort: p) { result in
                switch result {
                case .success(let conn):
                    nonisolated(unsafe) let c = conn
                    cont.resume(returning: c)
                case .failure(let err):
                    cont.resume(throwing: VmmApiError(
                        code: "exec_connect_failed",
                        message: "vsock connect to port \(p) failed: \(err.localizedDescription)",
                        status: .internalServerError))
                }
            }
        }
    }

    // MARK: - Events

    /// Get the event bus for a machine.
    func eventBus(for id: String) throws -> EventBus {
        guard let machine = machines[id] else {
            throw VmmApiError.machineNotFound(id)
        }
        return machine.eventBus
    }

    /// Subscribe to machine events. Combines machine lookup + bus subscribe in one @MainActor hop.
    func subscribeEvents(_ id: String) throws -> (stream: AsyncStream<MachineEvent>, subId: UUID) {
        let bus = try eventBus(for: id)
        let (stream, id) = bus.subscribe()
        return (stream, id)
    }

    /// Unsubscribe from machine events by subscription ID.
    func unsubscribeEvents(_ id: String, subId: UUID) {
        guard let machine = machines[id] else { return }
        machine.eventBus.unsubscribe(subId)
    }

    // MARK: - Snapshots

    /// Create a snapshot of a running or paused machine.
    /// Writes the VZ save bundle to the caller-supplied absolute path.
    /// Pauses if running, saves state, resumes if was running.
    func createSnapshot(_ machineId: String, path: String) async throws -> BentosSnapshot {
        guard !path.isEmpty, path.hasPrefix("/") else {
            throw VmmApiError.badRequest("Snapshot path must be an absolute path, got: '\(path)'")
        }
        guard var machine = machines[machineId] else {
            throw VmmApiError.machineNotFound(machineId)
        }
        guard machine.state == .running || machine.state == .paused else {
            throw VmmApiError.conflict(
                "Machine '\(machineId)' must be running or paused to snapshot (current state: \(machine.state))")
        }
        guard let vm = machine.vm else {
            throw VmmApiError.internalError("Machine '\(machineId)' has no VM instance")
        }

        let parentDir = (path as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: parentDir) else {
            throw VmmApiError.badRequest("Snapshot parent directory does not exist: '\(parentDir)'")
        }

        let wasRunning = machine.state == .running

        // Pause if running
        if wasRunning {
            try await vm.pause()
            transition(machineId, &machine, to: .paused)
        }

        do {
            let stateURL = URL(fileURLWithPath: path)
            try await vm.saveMachineStateTo(url: stateURL)
        } catch {
            if wasRunning {
                try? await vm.resume()
                machine = machines[machineId] ?? machine
                transition(machineId, &machine, to: .running)
            }
            throw VmmApiError(
                code: "snapshot_failed",
                message: "Failed to save snapshot: \(error.localizedDescription)",
                status: .internalServerError)
        }

        // Resume if was running
        if wasRunning {
            try await vm.resume()
            machine = machines[machineId] ?? machine
            transition(machineId, &machine, to: .running)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        let snapId = UUID().uuidString.lowercased()

        return BentosSnapshot(
            id: snapId,
            machineId: machineId,
            name: (path as NSString).lastPathComponent,
            sizeBytes: fileSize,
            createdAt: Date(),
            path: path
        )
    }

    /// Restore a machine from a snapshot at the given absolute host path. Machine must be stopped.
    func restoreSnapshot(_ machineId: String, path: String) async throws {
        guard !path.isEmpty, path.hasPrefix("/") else {
            throw VmmApiError.badRequest("Snapshot path must be an absolute path, got: '\(path)'")
        }
        guard var machine = machines[machineId] else {
            throw VmmApiError.machineNotFound(machineId)
        }
        guard machine.state == .stopped || machine.state == .error else {
            throw VmmApiError.conflict(
                "Machine '\(machineId)' must be stopped to restore (current state: \(machine.state))")
        }

        guard FileManager.default.fileExists(atPath: path) else {
            throw VmmApiError.badRequest("Snapshot file not found at path: '\(path)'")
        }

        let machineDir = store.machineDir(machineId)

        // Build VZ config and create a new VM instance
        machine.error = nil
        transition(machineId, &machine, to: .starting)

        do {
            let (vzConfig, consoleIO) = try ConfigTranslator.translate(
                machine.config, machineDir: machineDir)
            let vm = VZVirtualMachine(configuration: vzConfig)
            let delegate = MachineDelegate(machineId: machineId, manager: self)
            vm.delegate = delegate

            let stateURL = URL(fileURLWithPath: path)
            nonisolated(unsafe) let unsafeVm = vm
            try await unsafeVm.restoreMachineStateFrom(url: stateURL)

            machine.startedAt = Date()
            machine.vm = vm
            machine.delegate = delegate
            machine.consoleIO = consoleIO
            transition(machineId, &machine, to: .paused)
        } catch let apiErr as VmmApiError {
            machine.error = MachineError(code: apiErr.code, message: apiErr.message)
            transition(machineId, &machine, to: .error)
            throw apiErr
        } catch {
            machine.error = MachineError(code: "restore_failed", message: error.localizedDescription)
            transition(machineId, &machine, to: .error)
            throw VmmApiError(
                code: "restore_failed",
                message: error.localizedDescription,
                status: .internalServerError)
        }
    }

    // MARK: - Resize

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
