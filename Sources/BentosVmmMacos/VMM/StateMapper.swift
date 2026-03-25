import Virtualization

/// Maps VZVirtualMachine.State -> BentOS MachineState string.
enum StateMapper {
    static func map(_ vzState: VZVirtualMachine.State) -> MachineState {
        switch vzState {
        case .stopped: .stopped
        case .running: .running
        case .paused: .paused
        case .starting: .starting
        case .stopping: .stopping
        case .error: .error
        @unknown default: .error
        }
    }
}
