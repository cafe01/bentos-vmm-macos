import Foundation
import Virtualization

/// VZVirtualMachineDelegate: receives state change callbacks from VZ.fw.
final class MachineDelegate: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    private let machineId: String
    // Stored as nonisolated(unsafe) because VZ.fw calls delegate methods from arbitrary threads,
    // but we only use manager inside a Task { @MainActor }.
    nonisolated(unsafe) private weak var manager: MachineManager?

    @MainActor
    init(machineId: String, manager: MachineManager) {
        self.machineId = machineId
        self.manager = manager
    }

    func guestDidStop(_ vm: VZVirtualMachine) {
        let id = machineId
        let mgr = manager
        Task { @MainActor in
            guard var machine = mgr?.machines[id] else { return }
            let prev = machine.state
            machine.state = .stopped
            machine.startedAt = nil
            machine.vm = nil
            machine.delegate = nil
            machine.consoleIO = nil
            machine.consoleConnected = false
            machine.updatedAt = Date()
            mgr?.machines[id] = machine
            machine.eventBus.emit(.stateChanged(
                timestamp: Date(), previousState: prev, newState: .stopped))
        }
    }

    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: any Error) {
        let id = machineId
        let mgr = manager
        let msg = error.localizedDescription
        Task { @MainActor in
            guard var machine = mgr?.machines[id] else { return }
            let prev = machine.state
            machine.error = MachineError(
                code: "vm_error",
                message: msg,
                recoverable: true
            )
            machine.state = .error
            machine.vm = nil
            machine.delegate = nil
            machine.consoleIO = nil
            machine.consoleConnected = false
            machine.updatedAt = Date()
            mgr?.machines[id] = machine
            machine.eventBus.emit(.stateChanged(
                timestamp: Date(), previousState: prev, newState: .error))
            machine.eventBus.emit(.error(
                timestamp: Date(),
                error: MachineError(code: "vm_error", message: msg, recoverable: true)))
        }
    }
}
