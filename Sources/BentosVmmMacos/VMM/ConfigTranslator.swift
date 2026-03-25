import Foundation
import Virtualization

/// Translates BentosVmConfig -> VZVirtualMachineConfiguration.
/// Pure function: config in, VZ config out. No side effects.
enum ConfigTranslator {

    /// Build a validated VZVirtualMachineConfiguration from a BentosVmConfig.
    /// - Parameter machineDir: path to the machine's directory (for disk images).
    @MainActor
    static func translate(
        _ config: BentosVmConfig,
        machineDir: String
    ) throws -> (VZVirtualMachineConfiguration, ConsoleIO) {
        let vzConfig = VZVirtualMachineConfiguration()
        vzConfig.cpuCount = config.cpuCount
        vzConfig.memorySize = UInt64(config.memoryBytes)

        // Boot loader
        let kernelPath = resolveKernelPath(config.boot.kernel)
        let kernelURL = URL(fileURLWithPath: kernelPath)
        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootLoader.commandLine = config.boot.commandLine
        if let initramfs = config.boot.initramfs {
            bootLoader.initialRamdiskURL = URL(fileURLWithPath: resolveKernelPath(initramfs))
        }
        vzConfig.bootLoader = bootLoader

        // Storage (disks)
        var storageDevices: [VZStorageDeviceConfiguration] = []
        for (i, disk) in config.disks.enumerated() {
            let imgPath: String
            if disk.role == .root {
                imgPath = "\(machineDir)/root.img"
            } else {
                imgPath = "\(machineDir)/data-\(i).img"
            }
            guard FileManager.default.fileExists(atPath: imgPath) else {
                throw VmmApiError(
                    code: "disk_not_found",
                    message: "Disk image not found: \(imgPath)",
                    status: .internalServerError)
            }
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: imgPath),
                readOnly: disk.readOnly
            )
            storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
        }
        vzConfig.storageDevices = storageDevices

        // Network
        var networkDevices: [VZNetworkDeviceConfiguration] = []
        switch config.network {
        case .nat:
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZNATNetworkDeviceAttachment()
            networkDevices.append(net)
        case .bridged(let ifaceName):
            let ifaces = VZBridgedNetworkInterface.networkInterfaces
            guard let iface = ifaces.first(where: { $0.identifier == ifaceName }) else {
                throw VmmApiError(
                    code: "interface_not_found",
                    message: "Network interface '\(ifaceName)' not found",
                    status: .badRequest)
            }
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZBridgedNetworkDeviceAttachment(interface: iface)
            networkDevices.append(net)
        case .none:
            break
        }
        vzConfig.networkDevices = networkDevices

        // Console: create FileHandle pair BEFORE VM creation (VZ.fw requirement)
        let consoleIO = ConsoleIO()
        let consoleDevice = VZVirtioConsoleDeviceConfiguration()
        let serialPort = VZVirtioConsolePortConfiguration()
        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: consoleIO.guestInput,
            fileHandleForWriting: consoleIO.guestOutput
        )
        consoleDevice.ports[0] = serialPort
        vzConfig.consoleDevices = [consoleDevice]

        // Entropy
        if config.enableEntropy {
            vzConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        }

        // Vsock
        if config.enableVsock {
            vzConfig.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        }

        // Balloon (macOS 14+)
        if config.enableBalloon {
            vzConfig.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        }

        // Rosetta
        if config.enableRosetta {
            let availability = VZLinuxRosettaDirectoryShare.availability
            switch availability {
            case .installed:
                let rosettaShare = try VZLinuxRosettaDirectoryShare()
                let rosettaDevice = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                rosettaDevice.share = rosettaShare
                vzConfig.directorySharingDevices.append(rosettaDevice)
            case .notInstalled:
                throw VmmApiError(
                    code: "rosetta_not_installed",
                    message: "Rosetta is not installed. Install it first.",
                    status: .badRequest)
            case .notSupported:
                throw VmmApiError(
                    code: "rosetta_not_supported",
                    message: "Rosetta is not supported on this machine",
                    status: .badRequest)
            @unknown default:
                break
            }
        }

        // Shared directories
        for shared in config.sharedDirectories {
            let sharedDir = VZSharedDirectory(url: URL(fileURLWithPath: shared.hostPath), readOnly: shared.readOnly)
            let share = VZSingleDirectoryShare(directory: sharedDir)
            let device = VZVirtioFileSystemDeviceConfiguration(tag: shared.tag)
            device.share = share
            vzConfig.directorySharingDevices.append(device)
        }

        // Validate
        try vzConfig.validate()

        return (vzConfig, consoleIO)
    }

    // MARK: - Path resolution

    /// Resolve "bundled://filename" to the path alongside the daemon binary.
    private static func resolveKernelPath(_ path: String) -> String {
        if path.hasPrefix("bundled://") {
            let filename = String(path.dropFirst("bundled://".count))
            let execDir = Bundle.main.executableURL?.deletingLastPathComponent().path
                ?? ProcessInfo.processInfo.arguments[0]
                    .split(separator: "/").dropLast().joined(separator: "/")
            return "\(execDir)/\(filename)"
        }
        return path
    }
}

/// Console I/O pipe pair. Created at config time, bridged to WebSocket in M4.
final class ConsoleIO: Sendable {
    /// Write here -> data appears in guest stdin.
    let guestInput: FileHandle
    /// Read from here -> data from guest stdout.
    let guestOutput: FileHandle

    /// Host reads guest output from this handle.
    let hostReadHandle: FileHandle
    /// Host writes to guest input via this handle.
    let hostWriteHandle: FileHandle

    init() {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        // guestInput = read end of input pipe (guest reads from here)
        self.guestInput = inputPipe.fileHandleForReading
        // hostWriteHandle = write end of input pipe (host writes here -> guest reads)
        self.hostWriteHandle = inputPipe.fileHandleForWriting
        // guestOutput = write end of output pipe (guest writes here)
        self.guestOutput = outputPipe.fileHandleForWriting
        // hostReadHandle = read end of output pipe (host reads guest output from here)
        self.hostReadHandle = outputPipe.fileHandleForReading
    }
}
