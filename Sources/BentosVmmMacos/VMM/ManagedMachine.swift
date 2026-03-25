import Foundation
import Virtualization

/// Per-machine state. Config + lifecycle state + timestamps + VZ runtime.
/// Only accessed on @MainActor (via MachineManager).
struct ManagedMachine: @unchecked Sendable {
    let id: String
    var config: BentosVmConfig
    var state: MachineState
    var error: MachineError?
    var startedAt: Date?
    let createdAt: Date
    var updatedAt: Date

    // VZ runtime — nil when stopped. Set by MachineManager.start().
    var vm: VZVirtualMachine?
    var delegate: MachineDelegate?
    var consoleIO: ConsoleIO?

    init(id: String, config: BentosVmConfig) {
        self.id = id
        self.config = config
        self.state = .stopped
        self.error = nil
        self.startedAt = nil
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }

    /// Convert to the wire-format BentosMachine.
    func toBentosMachine() -> BentosMachine {
        let runtime: MachineRuntime? = if state == .running || state == .paused {
            MachineRuntime(
                cpuUsagePercent: 0.0,
                memoryUsedBytes: config.memoryBytes,
                uptimeSeconds: startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0,
                controlChannelConnected: false
            )
        } else {
            nil
        }

        return BentosMachine(
            id: id,
            config: config,
            state: state,
            error: error,
            runtime: runtime,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
