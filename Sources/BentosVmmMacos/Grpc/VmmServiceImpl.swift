import GRPCCore
import Foundation

/// gRPC service implementation for VmmService (§9 of bentos-vmm.proto).
/// Thin adapter over MachineManager — no VM logic lives here.
struct VmmServiceImpl: Bentos_Vmm_V1_VmmService.ServiceProtocol {

    private let manager: MachineManager

    init(manager: MachineManager) {
        self.manager = manager
    }

    // MARK: - GetCapabilities

    func getCapabilities(
        request: ServerRequest<Bentos_Vmm_V1_GetVmmCapabilitiesRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Bentos_Vmm_V1_VmmCapabilities> {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let processorCount = ProcessInfo.processInfo.processorCount

        var caps = Bentos_Vmm_V1_VmmCapabilities()
        caps.hotResize = false
        caps.liveMigration = false
        caps.bridgedNetwork = true
        caps.rosetta = true
        caps.snapshot = true
        caps.snapshotIncludesDisk = false
        caps.gpuPassthrough = false
        caps.pauseResume = true
        caps.maxVcpus = UInt32(processorCount)
        caps.maxMemoryBytes = physicalMemory
        caps.availableMemoryBytes = physicalMemory  // conservative; GC pressure not measured
        caps.vmmName = "bentos-vmm-macos"
        caps.vmmVersion = "0.1.0"
        caps.platform = "macos"

        return ServerResponse(message: caps)
    }

    // MARK: - Ping

    func ping(
        request: ServerRequest<Bentos_Vmm_V1_PingRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Bentos_Vmm_V1_VmmHealth> {
        let machineCount = await manager.machines.count
        var health = Bentos_Vmm_V1_VmmHealth()
        health.healthy = true
        health.machineCount = UInt32(machineCount)
        health.uptimeSeconds = 0  // uptime tracking deferred to r2
        return ServerResponse(message: health)
    }
}
