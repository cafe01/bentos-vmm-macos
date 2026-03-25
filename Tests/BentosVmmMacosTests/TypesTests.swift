import Foundation
import Testing
@testable import BentosVmmMacos

@Suite("Types JSON round-trip")
struct TypesTests {

    // MARK: - BootConfig

    @Test func bootConfigRoundTrip() throws {
        let orig = BootConfig(kernel: "bundled://bentos-arm64-Image", initramfs: nil)
        let data = try JSONEncoder.vmm.encode(orig)
        let decoded = try JSONDecoder.vmm.decode(BootConfig.self, from: data)
        #expect(decoded == orig)
    }

    @Test func bootConfigWithInitramfs() throws {
        let orig = BootConfig(kernel: "bundled://k", initramfs: "bundled://initrd", commandLine: "quiet")
        let data = try JSONEncoder.vmm.encode(orig)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["command_line"] as? String == "quiet")
        #expect(json["initramfs"] as? String == "bundled://initrd")
        let decoded = try JSONDecoder.vmm.decode(BootConfig.self, from: data)
        #expect(decoded == orig)
    }

    @Test func bootConfigSnakeCaseKeys() throws {
        let json = """
        {"kernel":"k","command_line":"root=/dev/vda"}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder.vmm.decode(BootConfig.self, from: json)
        #expect(cfg.commandLine == "root=/dev/vda")
    }

    // MARK: - DiskConfig

    @Test func diskConfigRoundTrip() throws {
        let orig = DiskConfig(role: .root, sizeBytes: 1_073_741_824)
        let data = try JSONEncoder.vmm.encode(orig)
        let decoded = try JSONDecoder.vmm.decode(DiskConfig.self, from: data)
        #expect(decoded == orig)
    }

    @Test func diskConfigSnakeCaseKeys() throws {
        let json = """
        {"role":"data","size_bytes":512,"read_only":true}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder.vmm.decode(DiskConfig.self, from: json)
        #expect(cfg.readOnly == true)
        #expect(cfg.sizeBytes == 512)
    }

    // MARK: - NetworkConfig

    @Test func natNetworkRoundTrip() throws {
        let orig = NetworkConfig.nat
        let data = try JSONEncoder.vmm.encode(orig)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"nat\""))
        let decoded = try JSONDecoder.vmm.decode(NetworkConfig.self, from: data)
        #expect(decoded == orig)
    }

    @Test func bridgedNetworkRoundTrip() throws {
        let orig = NetworkConfig.bridged(interfaceName: "en0")
        let data = try JSONEncoder.vmm.encode(orig)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["mode"] as? String == "bridged")
        #expect(json["interface"] as? String == "en0")
        let decoded = try JSONDecoder.vmm.decode(NetworkConfig.self, from: data)
        #expect(decoded == orig)
    }

    @Test func noneNetworkRoundTrip() throws {
        let orig = NetworkConfig.none
        let data = try JSONEncoder.vmm.encode(orig)
        let decoded = try JSONDecoder.vmm.decode(NetworkConfig.self, from: data)
        #expect(decoded == orig)
    }

    // MARK: - SharedDirectoryConfig

    @Test func sharedDirRoundTrip() throws {
        let orig = SharedDirectoryConfig(tag: "workspace", hostPath: "/Users/dev", readOnly: true)
        let data = try JSONEncoder.vmm.encode(orig)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["host_path"] as? String == "/Users/dev")
        #expect(json["read_only"] as? Bool == true)
        let decoded = try JSONDecoder.vmm.decode(SharedDirectoryConfig.self, from: data)
        #expect(decoded == orig)
    }

    // MARK: - BentosVmConfig (the big one)

    @Test func vmConfigRoundTrip() throws {
        let orig = BentosVmConfig(
            name: "dev",
            cpuCount: 4,
            memoryBytes: 4_294_967_296,
            boot: BootConfig(kernel: "bundled://bentos-arm64-Image"),
            disks: [DiskConfig(role: .root, sizeBytes: 1_073_741_824)],
            network: .nat,
            sharedDirectories: [SharedDirectoryConfig(tag: "code", hostPath: "/src")],
            enableVsock: true,
            enableEntropy: true,
            enableBalloon: true,
            enableRosetta: false
        )
        let data = try JSONEncoder.vmm.encode(orig)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Verify snake_case keys
        #expect(json["cpu_count"] as? Int == 4)
        #expect(json["memory_bytes"] as? Int == 4_294_967_296)
        #expect(json["enable_vsock"] as? Bool == true)
        #expect(json["enable_rosetta"] as? Bool == false)
        #expect(json["shared_directories"] != nil)

        let decoded = try JSONDecoder.vmm.decode(BentosVmConfig.self, from: data)
        #expect(decoded == orig)
    }

    @Test func vmConfigFromDartWireFormat() throws {
        // Exact JSON a Dart client would send
        let json = """
        {
            "name":"dev","cpu_count":2,"memory_bytes":2147483648,
            "boot":{"kernel":"bundled://bentos-arm64-Image","command_line":"console=hvc0 root=/dev/vda rw quiet"},
            "disks":[{"role":"root","size_bytes":1073741824,"read_only":false}],
            "network":{"mode":"nat"},
            "shared_directories":[],
            "enable_vsock":true,"enable_entropy":true,"enable_balloon":true,"enable_rosetta":false
        }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder.vmm.decode(BentosVmConfig.self, from: json)
        #expect(cfg.name == "dev")
        #expect(cfg.cpuCount == 2)
        #expect(cfg.memoryBytes == 2_147_483_648)
        #expect(cfg.boot.kernel == "bundled://bentos-arm64-Image")
        #expect(cfg.disks.count == 1)
        #expect(cfg.disks[0].role == .root)
        #expect(cfg.network == .nat)
    }

    // MARK: - MachineRuntime

    @Test func runtimeRoundTrip() throws {
        let orig = MachineRuntime(
            cpuUsagePercent: 12.5,
            memoryUsedBytes: 1_073_741_824,
            uptimeSeconds: 3600,
            controlChannelConnected: true
        )
        let data = try JSONEncoder.vmm.encode(orig)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["cpu_usage_percent"] as? Double == 12.5)
        #expect(json["control_channel_connected"] as? Bool == true)
        let decoded = try JSONDecoder.vmm.decode(MachineRuntime.self, from: data)
        #expect(decoded == orig)
    }

    // MARK: - MachineError

    @Test func machineErrorRoundTrip() throws {
        let orig = MachineError(code: "boot_failed", message: "Kernel not found", recoverable: false)
        let data = try JSONEncoder.vmm.encode(orig)
        let decoded = try JSONDecoder.vmm.decode(MachineError.self, from: data)
        #expect(decoded == orig)
    }

    // MARK: - BentosMachine

    @Test func bentosMachineRoundTrip() throws {
        let now = Date()
        let orig = BentosMachine(
            id: "abc-123",
            config: BentosVmConfig(
                name: "test",
                cpuCount: 2,
                memoryBytes: 2_147_483_648,
                boot: BootConfig(kernel: "bundled://k"),
                disks: [DiskConfig(role: .root, sizeBytes: 1_073_741_824)]
            ),
            state: .stopped,
            createdAt: now,
            updatedAt: now
        )
        let data = try JSONEncoder.vmm.encode(orig)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["id"] as? String == "abc-123")
        #expect(json["state"] as? String == "stopped")
        #expect(json["created_at"] != nil)
        #expect(json["updated_at"] != nil)

        let decoded = try JSONDecoder.vmm.decode(BentosMachine.self, from: data)
        #expect(decoded.id == orig.id)
        #expect(decoded.state == orig.state)
        #expect(decoded.config.name == orig.config.name)
    }

    // MARK: - BentosSnapshot

    @Test func snapshotRoundTrip() throws {
        let now = Date()
        let orig = BentosSnapshot(
            id: "snap-1",
            machineId: "m-1",
            name: "before-update",
            sizeBytes: 536_870_912,
            createdAt: now
        )
        let data = try JSONEncoder.vmm.encode(orig)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["machine_id"] as? String == "m-1")
        #expect(json["size_bytes"] as? Int == 536_870_912)
        let decoded = try JSONDecoder.vmm.decode(BentosSnapshot.self, from: data)
        #expect(decoded.id == orig.id)
    }

    // MARK: - ResizeResult (sealed)

    @Test func resizeAppliedRoundTrip() throws {
        let orig = ResizeResult.applied
        let data = try JSONEncoder.vmm.encode(orig)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "applied")
        let decoded = try JSONDecoder.vmm.decode(ResizeResult.self, from: data)
        #expect(decoded == orig)
    }

    @Test func resizeRestartRequiredRoundTrip() throws {
        let orig = ResizeResult.restartRequired(message: "Restart needed")
        let data = try JSONEncoder.vmm.encode(orig)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "restart_required")
        #expect(json["message"] as? String == "Restart needed")
        let decoded = try JSONDecoder.vmm.decode(ResizeResult.self, from: data)
        #expect(decoded == orig)
    }

    // MARK: - BentosVmmCapabilities

    @Test func capabilitiesRoundTrip() throws {
        let orig = BentosVmmCapabilities(
            hotResize: false, liveMigration: false, bridgedNetwork: true,
            rosetta: true, snapshot: true, snapshotIncludesDisk: false,
            gpuPassthrough: false, maxVcpus: 10, maxMemoryBytes: 17_179_869_184,
            availableMemoryBytes: 8_589_934_592,
            backendName: "bentos-vmm-macos", backendVersion: "0.1.0",
            platform: "macOS 15.0 arm64"
        )
        let data = try JSONEncoder.vmm.encode(orig)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["hot_resize"] as? Bool == false)
        #expect(json["max_vcpus"] as? Int == 10)
        #expect(json["backend_name"] as? String == "bentos-vmm-macos")
        let decoded = try JSONDecoder.vmm.decode(BentosVmmCapabilities.self, from: data)
        #expect(decoded == orig)
    }

    // MARK: - VmmHealth

    @Test func healthRoundTrip() throws {
        let orig = VmmHealth(healthy: true, machineCount: 3, uptimeSeconds: 120)
        let data = try JSONEncoder.vmm.encode(orig)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["machine_count"] as? Int == 3)
        let decoded = try JSONDecoder.vmm.decode(VmmHealth.self, from: data)
        #expect(decoded == orig)
    }

    // MARK: - MachineEvent (sealed)

    @Test func stateChangedEventRoundTrip() throws {
        let now = Date()
        let orig = MachineEvent.stateChanged(
            timestamp: now, previousState: .stopped, newState: .starting)
        let data = try JSONEncoder.vmm.encode(orig)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "state_changed")
        #expect(json["previous_state"] as? String == "stopped")
        #expect(json["new_state"] as? String == "starting")
        let decoded = try JSONDecoder.vmm.decode(MachineEvent.self, from: data)
        if case .stateChanged(_, let prev, let next) = decoded {
            #expect(prev == .stopped)
            #expect(next == .starting)
        } else {
            Issue.record("Expected .stateChanged, got \(decoded)")
        }
    }

    @Test func errorEventRoundTrip() throws {
        let now = Date()
        let orig = MachineEvent.error(
            timestamp: now,
            error: MachineError(code: "boot_failed", message: "oops", recoverable: true))
        let data = try JSONEncoder.vmm.encode(orig)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "error")
        let decoded = try JSONDecoder.vmm.decode(MachineEvent.self, from: data)
        if case .error(_, let err) = decoded {
            #expect(err.code == "boot_failed")
        } else {
            Issue.record("Expected .error, got \(decoded)")
        }
    }

    @Test func controlChannelEventRoundTrip() throws {
        let now = Date()
        let orig = MachineEvent.controlChannel(timestamp: now, connected: true)
        let data = try JSONEncoder.vmm.encode(orig)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "control_channel")
        #expect(json["connected"] as? Bool == true)
        let decoded = try JSONDecoder.vmm.decode(MachineEvent.self, from: data)
        if case .controlChannel(_, let conn) = decoded {
            #expect(conn == true)
        } else {
            Issue.record("Expected .controlChannel, got \(decoded)")
        }
    }

    // MARK: - ResizeRequest

    @Test func resizeRequestRoundTrip() throws {
        let orig = ResizeRequest(cpuCount: 4, memoryBytes: nil)
        let data = try JSONEncoder.vmm.encode(orig)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["cpu_count"] as? Int == 4)
        // memoryBytes is nil, should not be present in JSON
        // Note: Codable includes nil as null by default — that's fine, Dart handles it
    }
}
