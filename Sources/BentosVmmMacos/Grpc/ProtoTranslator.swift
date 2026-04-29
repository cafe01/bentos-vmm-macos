import Foundation
import GRPCCore

// MARK: - ProtoTranslator
//
// Proto ↔ BentosVmConfig / ManagedMachine translations.
// ConfigTranslator.swift handles BentosVmConfig → VZVirtualMachineConfiguration.
// This file owns the proto wire boundary.

enum ProtoTranslator {

    // MARK: - MachineConfig (proto) → BentosVmConfig

    /// Translate a proto MachineConfig to the internal BentosVmConfig.
    /// Throws RPCError.invalidArgument on any structural violation.
    static func toInternal(_ proto: Bentos_Vmm_V1_MachineConfig) throws -> BentosVmConfig {
        guard !proto.image.kernelPath.isEmpty else {
            throw RPCError(code: .invalidArgument, message: "image.kernel_path must be non-empty")
        }

        let commandLine = proto.commandLine.isEmpty
            ? proto.image.defaultCommandLine
            : proto.commandLine

        let boot = BootConfig(
            kernel: proto.image.kernelPath,
            initramfs: nil,
            commandLine: commandLine.isEmpty ? "console=hvc0 root=/dev/vda rw quiet" : commandLine
        )

        var disks: [DiskConfig] = []
        var network: NetworkConfig = .nat
        var sharedDirectories: [SharedDirectoryConfig] = []

        for cap in proto.capabilities {
            switch cap.config {
            case .block(let block):
                let role: DiskRole = block.role == .root ? .root : .data
                disks.append(DiskConfig(role: role, sizeBytes: Int(block.sizeBytes), readOnly: block.readOnly))
            case .net(let net):
                switch net.mode {
                case .nat, .unspecified:
                    network = .nat
                case .bridged:
                    network = .bridged(interfaceName: net.interface)
                case .none:
                    network = .none
                case .UNRECOGNIZED:
                    network = .nat
                }
            case .storage(let storage):
                sharedDirectories.append(SharedDirectoryConfig(
                    tag: cap.path.isEmpty ? "share-\(sharedDirectories.count)" : cap.path,
                    hostPath: storage.hostPath,
                    readOnly: storage.readOnly
                ))
            case .guest:
                // GuestConfig is opaque to the VMM layer — forwarded over vsock, no translation.
                break
            case nil:
                break
            }
        }

        return BentosVmConfig(
            name: proto.name,
            cpuCount: Int(proto.cpuCount),
            memoryBytes: Int(proto.memoryBytes),
            boot: boot,
            disks: disks,
            network: network,
            sharedDirectories: sharedDirectories,
            enableVsock: proto.enableVsock,
            enableEntropy: proto.enableEntropy,
            enableBalloon: proto.enableBalloon,
            enableRosetta: proto.enableRosetta,
            rootfsPath: proto.image.rootfsPath.isEmpty ? nil : proto.image.rootfsPath
        )
    }

    // MARK: - ManagedMachine → proto Machine

    static func toProto(_ machine: ManagedMachine) -> Bentos_Vmm_V1_Machine {
        var m = Bentos_Vmm_V1_Machine()
        m.id = machine.id
        m.config = toProto(machine.config)
        m.state = toProtoState(machine.state)

        if let err = machine.error {
            var e = Bentos_Vmm_V1_MachineError()
            e.code = err.code
            e.message = err.message
            e.recoverable = err.recoverable
            m.error = e
        }

        if machine.state == .running || machine.state == .paused, let startedAt = machine.startedAt {
            var rt = Bentos_Vmm_V1_MachineRuntime()
            rt.cpuUsagePercent = 0.0
            rt.memoryUsedBytes = UInt64(machine.config.memoryBytes)
            rt.uptimeSeconds = UInt64(Date().timeIntervalSince(startedAt))
            m.runtime = rt
        }

        m.createdAt = ISO8601DateFormatter().string(from: machine.createdAt)
        m.updatedAt = ISO8601DateFormatter().string(from: machine.updatedAt)
        return m
    }

    // MARK: - BentosVmConfig → proto MachineConfig

    static func toProto(_ config: BentosVmConfig) -> Bentos_Vmm_V1_MachineConfig {
        var mc = Bentos_Vmm_V1_MachineConfig()
        mc.name = config.name
        mc.cpuCount = UInt32(config.cpuCount)
        mc.memoryBytes = UInt64(config.memoryBytes)
        mc.commandLine = config.boot.commandLine
        mc.enableVsock = config.enableVsock
        mc.enableEntropy = config.enableEntropy
        mc.enableBalloon = config.enableBalloon
        mc.enableRosetta = config.enableRosetta

        var img = Bentos_Vmm_V1_Image()
        img.kernelPath = config.boot.kernel
        img.rootfsPath = config.rootfsPath ?? ""
        img.defaultCommandLine = config.boot.commandLine
        mc.image = img

        for disk in config.disks {
            var cap = Bentos_Vmm_V1_MachineCapability()
            cap.kind = .device
            cap.backing = .host
            cap.subsystem = .block
            var block = Bentos_Vmm_V1_BlockConfig()
            block.role = disk.role == .root ? .root : .data
            block.sizeBytes = UInt64(disk.sizeBytes)
            block.readOnly = disk.readOnly
            cap.config = .block(block)
            mc.capabilities.append(cap)
        }

        switch config.network {
        case .nat:
            var cap = Bentos_Vmm_V1_MachineCapability()
            cap.kind = .device
            cap.backing = .host
            cap.subsystem = .net
            var net = Bentos_Vmm_V1_NetConfig()
            net.mode = .nat
            cap.config = .net(net)
            mc.capabilities.append(cap)
        case .bridged(let iface):
            var cap = Bentos_Vmm_V1_MachineCapability()
            cap.kind = .device
            cap.backing = .host
            cap.subsystem = .net
            var net = Bentos_Vmm_V1_NetConfig()
            net.mode = .bridged
            net.interface = iface
            cap.config = .net(net)
            mc.capabilities.append(cap)
        case .none:
            break
        }

        for shared in config.sharedDirectories {
            var cap = Bentos_Vmm_V1_MachineCapability()
            cap.kind = .filesystem
            cap.backing = .host
            cap.subsystem = .storage
            cap.path = shared.tag
            var storage = Bentos_Vmm_V1_StorageConfig()
            storage.hostPath = shared.hostPath
            storage.readOnly = shared.readOnly
            cap.config = .storage(storage)
            mc.capabilities.append(cap)
        }

        return mc
    }

    // MARK: - MachineEvent → proto MachineEvent

    static func toProtoEvent(_ event: MachineEvent) -> Bentos_Vmm_V1_MachineEvent {
        var e = Bentos_Vmm_V1_MachineEvent()
        switch event {
        case .stateChanged(let ts, let prev, let next):
            e.timestamp = ISO8601DateFormatter().string(from: ts)
            var sc = Bentos_Vmm_V1_MachineStateChanged()
            sc.previousState = toProtoState(prev)
            sc.newState = toProtoState(next)
            e.payload = .stateChanged(sc)
        case .error(let ts, let err):
            e.timestamp = ISO8601DateFormatter().string(from: ts)
            var inner = Bentos_Vmm_V1_MachineError()
            inner.code = err.code
            inner.message = err.message
            inner.recoverable = err.recoverable
            var me = Bentos_Vmm_V1_MachineErrored()
            me.error = inner
            e.payload = .errored(me)
        case .controlChannel:
            // No proto equivalent — omit payload; client skips unknown/empty payload per spec.
            e.timestamp = ISO8601DateFormatter().string(from: Date())
        }
        return e
    }

    // MARK: - State mapping

    static func toProtoState(_ state: MachineState) -> Bentos_Vmm_V1_MachineState {
        switch state {
        case .stopped:  return .stopped
        case .starting: return .starting
        case .running:  return .running
        case .paused:   return .paused
        case .stopping: return .stopping
        case .error:    return .error
        }
    }
}
