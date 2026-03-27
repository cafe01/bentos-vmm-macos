import Foundation

// MARK: - Machine state

enum MachineState: String, Codable, Sendable {
    case stopped
    case starting
    case running
    case paused
    case stopping
    case error
}

// MARK: - Boot

struct BootConfig: Codable, Equatable, Sendable {
    let kernel: String
    let initramfs: String?
    let commandLine: String

    init(
        kernel: String,
        initramfs: String? = nil,
        commandLine: String = "console=hvc0 root=/dev/vda rw quiet"
    ) {
        self.kernel = kernel
        self.initramfs = initramfs
        self.commandLine = commandLine
    }

    enum CodingKeys: String, CodingKey {
        case kernel
        case initramfs
        case commandLine = "command_line"
    }
}

// MARK: - Disk

enum DiskRole: String, Codable, Sendable {
    case root
    case data
}

struct DiskConfig: Codable, Equatable, Sendable {
    let role: DiskRole
    let sizeBytes: Int
    let readOnly: Bool

    init(role: DiskRole = .data, sizeBytes: Int, readOnly: Bool = false) {
        self.role = role
        self.sizeBytes = sizeBytes
        self.readOnly = readOnly
    }

    enum CodingKeys: String, CodingKey {
        case role
        case sizeBytes = "size_bytes"
        case readOnly = "read_only"
    }
}

// MARK: - Network

/// Sealed network config with "mode" discriminator.
enum NetworkConfig: Codable, Equatable, Sendable {
    case nat
    case bridged(interfaceName: String)
    case none

    enum CodingKeys: String, CodingKey {
        case mode
        case interface_ = "interface"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(String.self, forKey: .mode)
        switch mode {
        case "nat": self = .nat
        case "bridged":
            let iface = try container.decode(String.self, forKey: .interface_)
            self = .bridged(interfaceName: iface)
        case "none": self = .none
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .mode, in: container,
                debugDescription: "Unknown network mode: \(mode)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .nat:
            try container.encode("nat", forKey: .mode)
        case .bridged(let iface):
            try container.encode("bridged", forKey: .mode)
            try container.encode(iface, forKey: .interface_)
        case .none:
            try container.encode("none", forKey: .mode)
        }
    }
}

// MARK: - Shared directories

struct SharedDirectoryConfig: Codable, Equatable, Sendable {
    let tag: String
    let hostPath: String
    let readOnly: Bool

    init(tag: String, hostPath: String, readOnly: Bool = false) {
        self.tag = tag
        self.hostPath = hostPath
        self.readOnly = readOnly
    }

    enum CodingKeys: String, CodingKey {
        case tag
        case hostPath = "host_path"
        case readOnly = "read_only"
    }
}

// MARK: - VM config

struct BentosVmConfig: Codable, Equatable, Sendable {
    let name: String
    let cpuCount: Int
    let memoryBytes: Int
    let boot: BootConfig
    let disks: [DiskConfig]
    let network: NetworkConfig
    let sharedDirectories: [SharedDirectoryConfig]
    let enableVsock: Bool
    let enableEntropy: Bool
    let enableBalloon: Bool
    let enableRosetta: Bool

    init(
        name: String,
        cpuCount: Int,
        memoryBytes: Int,
        boot: BootConfig,
        disks: [DiskConfig],
        network: NetworkConfig = .nat,
        sharedDirectories: [SharedDirectoryConfig] = [],
        enableVsock: Bool = true,
        enableEntropy: Bool = true,
        enableBalloon: Bool = true,
        enableRosetta: Bool = false
    ) {
        self.name = name
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.boot = boot
        self.disks = disks
        self.network = network
        self.sharedDirectories = sharedDirectories
        self.enableVsock = enableVsock
        self.enableEntropy = enableEntropy
        self.enableBalloon = enableBalloon
        self.enableRosetta = enableRosetta
    }

    enum CodingKeys: String, CodingKey {
        case name
        case cpuCount = "cpu_count"
        case memoryBytes = "memory_bytes"
        case boot
        case disks
        case network
        case sharedDirectories = "shared_directories"
        case enableVsock = "enable_vsock"
        case enableEntropy = "enable_entropy"
        case enableBalloon = "enable_balloon"
        case enableRosetta = "enable_rosetta"
    }
}

// MARK: - Machine

struct MachineRuntime: Codable, Equatable, Sendable {
    let cpuUsagePercent: Double
    let memoryUsedBytes: Int
    let uptimeSeconds: Int
    let controlChannelConnected: Bool

    enum CodingKeys: String, CodingKey {
        case cpuUsagePercent = "cpu_usage_percent"
        case memoryUsedBytes = "memory_used_bytes"
        case uptimeSeconds = "uptime_seconds"
        case controlChannelConnected = "control_channel_connected"
    }
}

struct MachineError: Codable, Equatable, Sendable {
    let code: String
    let message: String
    let recoverable: Bool

    init(code: String, message: String, recoverable: Bool = true) {
        self.code = code
        self.message = message
        self.recoverable = recoverable
    }
}

struct BentosMachine: Codable, Equatable, Sendable {
    let id: String
    let config: BentosVmConfig
    let state: MachineState
    let error: MachineError?
    let runtime: MachineRuntime?
    let createdAt: Date
    let updatedAt: Date

    init(
        id: String,
        config: BentosVmConfig,
        state: MachineState,
        error: MachineError? = nil,
        runtime: MachineRuntime? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.config = config
        self.state = state
        self.error = error
        self.runtime = runtime
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, config, state, error, runtime
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Snapshots

struct BentosSnapshot: Codable, Equatable, Sendable {
    let id: String
    let machineId: String
    let name: String
    let sizeBytes: Int
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case machineId = "machine_id"
        case name
        case sizeBytes = "size_bytes"
        case createdAt = "created_at"
    }
}

// MARK: - Resize

struct ResizeRequest: Codable, Equatable, Sendable {
    let cpuCount: Int?
    let memoryBytes: Int?

    enum CodingKeys: String, CodingKey {
        case cpuCount = "cpu_count"
        case memoryBytes = "memory_bytes"
    }
}

/// Sealed resize result with "type" discriminator.
enum ResizeResult: Codable, Equatable, Sendable {
    case applied
    case restartRequired(message: String)

    enum CodingKeys: String, CodingKey {
        case type
        case message
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "applied": self = .applied
        case "restart_required":
            let msg = try container.decodeIfPresent(String.self, forKey: .message)
                ?? "Machine must be restarted for resize to take effect."
            self = .restartRequired(message: msg)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown resize result: \(type)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .applied:
            try container.encode("applied", forKey: .type)
        case .restartRequired(let msg):
            try container.encode("restart_required", forKey: .type)
            try container.encode(msg, forKey: .message)
        }
    }
}

// MARK: - Capabilities

struct BentosVmmCapabilities: Codable, Equatable, Sendable {
    let hotResize: Bool
    let liveMigration: Bool
    let bridgedNetwork: Bool
    let rosetta: Bool
    let snapshot: Bool
    let snapshotIncludesDisk: Bool
    let gpuPassthrough: Bool
    let maxVcpus: Int
    let maxMemoryBytes: Int
    let availableMemoryBytes: Int
    let backendName: String
    let backendVersion: String
    let platform: String

    enum CodingKeys: String, CodingKey {
        case hotResize = "hot_resize"
        case liveMigration = "live_migration"
        case bridgedNetwork = "bridged_network"
        case rosetta
        case snapshot
        case snapshotIncludesDisk = "snapshot_includes_disk"
        case gpuPassthrough = "gpu_passthrough"
        case maxVcpus = "max_vcpus"
        case maxMemoryBytes = "max_memory_bytes"
        case availableMemoryBytes = "available_memory_bytes"
        case backendName = "backend_name"
        case backendVersion = "backend_version"
        case platform
    }
}

// MARK: - Health

struct VmmHealth: Codable, Equatable, Sendable {
    let healthy: Bool
    let machineCount: Int
    let uptimeSeconds: Int

    enum CodingKeys: String, CodingKey {
        case healthy
        case machineCount = "machine_count"
        case uptimeSeconds = "uptime_seconds"
    }
}

// MARK: - Events

/// Sealed machine event with "type" discriminator.
enum MachineEvent: Codable, Equatable, Sendable {
    case stateChanged(timestamp: Date, previousState: MachineState, newState: MachineState)
    case error(timestamp: Date, error: MachineError)
    case controlChannel(timestamp: Date, connected: Bool)

    enum CodingKeys: String, CodingKey {
        case type, timestamp
        case previousState = "previous_state"
        case newState = "new_state"
        case error
        case connected
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let ts = try container.decode(Date.self, forKey: .timestamp)
        switch type {
        case "state_changed":
            let prev = try container.decode(MachineState.self, forKey: .previousState)
            let next = try container.decode(MachineState.self, forKey: .newState)
            self = .stateChanged(timestamp: ts, previousState: prev, newState: next)
        case "error":
            let err = try container.decode(MachineError.self, forKey: .error)
            self = .error(timestamp: ts, error: err)
        case "control_channel":
            let conn = try container.decode(Bool.self, forKey: .connected)
            self = .controlChannel(timestamp: ts, connected: conn)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown event type: \(type)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stateChanged(let ts, let prev, let next):
            try container.encode("state_changed", forKey: .type)
            try container.encode(ts, forKey: .timestamp)
            try container.encode(prev, forKey: .previousState)
            try container.encode(next, forKey: .newState)
        case .error(let ts, let err):
            try container.encode("error", forKey: .type)
            try container.encode(ts, forKey: .timestamp)
            try container.encode(err, forKey: .error)
        case .controlChannel(let ts, let conn):
            try container.encode("control_channel", forKey: .type)
            try container.encode(ts, forKey: .timestamp)
            try container.encode(conn, forKey: .connected)
        }
    }
}

// MARK: - Exec

/// Request body for one-shot exec (POST .../exec/run).
struct ExecRunRequest: Codable, Sendable {
    let command: [String]
    let env: [String: String]
    let workingDir: String?
    let tty: Bool
    let timeoutSeconds: Int?

    init(
        command: [String],
        env: [String: String] = [:],
        workingDir: String? = nil,
        tty: Bool = false,
        timeoutSeconds: Int? = nil
    ) {
        self.command = command
        self.env = env
        self.workingDir = workingDir
        self.tty = tty
        self.timeoutSeconds = timeoutSeconds
    }

    enum CodingKeys: String, CodingKey {
        case command
        case env
        case workingDir = "working_dir"
        case tty
        case timeoutSeconds = "timeout_seconds"
    }
}

/// Response body for one-shot exec (POST .../exec/run).
struct ExecRunResponse: Codable, Sendable {
    let exitCode: Int
    let stdout: String
    let stderr: String

    enum CodingKeys: String, CodingKey {
        case exitCode = "exit_code"
        case stdout
        case stderr
    }
}

// MARK: - JSON Encoder/Decoder configured for Dart wire format

extension JSONEncoder {
    /// Encoder matching the Dart wire format: ISO 8601 dates, snake_case via CodingKeys.
    static let vmm: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        return enc
    }()
}

extension JSONDecoder {
    static let vmm: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()
}
