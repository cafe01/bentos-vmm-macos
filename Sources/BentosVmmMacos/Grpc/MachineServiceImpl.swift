import GRPCCore
import Foundation

/// gRPC service implementation for MachineService (§10 of bentos-vmm.proto).
/// Thin adapter over MachineManager — no VM logic lives here.
/// Streaming RPCs (WatchEvents, Console, Exec) are implemented in r3.
struct MachineServiceImpl: Bentos_Vmm_V1_MachineService.ServiceProtocol {

    private let manager: MachineManager

    init(manager: MachineManager) {
        self.manager = manager
    }

    // MARK: - CRUD

    func create(
        request: ServerRequest<Bentos_Vmm_V1_CreateMachineRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Bentos_Vmm_V1_Machine> {
        let config = try ProtoTranslator.toInternal(request.message.config)
        do {
            let machine = try await manager.create(config: config)
            return ServerResponse(message: ProtoTranslator.toProto(machine))
        } catch let e as VmmApiError {
            throw e.rpcError
        }
    }

    func list(
        request: ServerRequest<Bentos_Vmm_V1_ListMachinesRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Bentos_Vmm_V1_ListMachinesResponse> {
        let machines = await manager.list()
        var response = Bentos_Vmm_V1_ListMachinesResponse()
        response.machines = machines.map { ProtoTranslator.toProto($0) }
        return ServerResponse(message: response)
    }

    func get(
        request: ServerRequest<Bentos_Vmm_V1_GetMachineRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Bentos_Vmm_V1_Machine> {
        do {
            let machine = try await manager.get(request.message.machineID)
            return ServerResponse(message: ProtoTranslator.toProto(machine))
        } catch let e as VmmApiError {
            throw e.rpcError
        }
    }

    func apply(
        request: ServerRequest<Bentos_Vmm_V1_ApplyMachineConfigRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Bentos_Vmm_V1_Machine> {
        let config = try ProtoTranslator.toInternal(request.message.config)
        do {
            let machine = try await manager.apply(request.message.machineID, config: config)
            return ServerResponse(message: ProtoTranslator.toProto(machine))
        } catch let e as VmmApiError {
            throw e.rpcError
        }
    }

    func delete(
        request: ServerRequest<Bentos_Vmm_V1_DeleteMachineRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Bentos_Vmm_V1_DeleteMachineResponse> {
        do {
            try await manager.delete(request.message.machineID)
            return ServerResponse(message: Bentos_Vmm_V1_DeleteMachineResponse())
        } catch let e as VmmApiError {
            throw e.rpcError
        }
    }

    // MARK: - Lifecycle verbs

    func start(
        request: ServerRequest<Bentos_Vmm_V1_StartMachineRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Bentos_Vmm_V1_StartMachineResponse> {
        do {
            try await manager.start(request.message.machineID)
            return ServerResponse(message: Bentos_Vmm_V1_StartMachineResponse())
        } catch let e as VmmApiError {
            throw e.rpcError
        }
    }

    func stop(
        request: ServerRequest<Bentos_Vmm_V1_StopMachineRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Bentos_Vmm_V1_StopMachineResponse> {
        do {
            try await manager.stop(request.message.machineID, force: request.message.force)
            return ServerResponse(message: Bentos_Vmm_V1_StopMachineResponse())
        } catch let e as VmmApiError {
            throw e.rpcError
        }
    }

    func pause(
        request: ServerRequest<Bentos_Vmm_V1_PauseMachineRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Bentos_Vmm_V1_PauseMachineResponse> {
        do {
            try await manager.pause(request.message.machineID)
            return ServerResponse(message: Bentos_Vmm_V1_PauseMachineResponse())
        } catch let e as VmmApiError {
            throw e.rpcError
        }
    }

    func resume(
        request: ServerRequest<Bentos_Vmm_V1_ResumeMachineRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Bentos_Vmm_V1_ResumeMachineResponse> {
        do {
            try await manager.resume(request.message.machineID)
            return ServerResponse(message: Bentos_Vmm_V1_ResumeMachineResponse())
        } catch let e as VmmApiError {
            throw e.rpcError
        }
    }

    func pressPowerButton(
        request: ServerRequest<Bentos_Vmm_V1_PressPowerButtonRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Bentos_Vmm_V1_PressPowerButtonResponse> {
        do {
            try await manager.pressPowerButton(request.message.machineID)
            return ServerResponse(message: Bentos_Vmm_V1_PressPowerButtonResponse())
        } catch let e as VmmApiError {
            throw e.rpcError
        }
    }

    // MARK: - Snapshots

    func takeSnapshot(
        request: ServerRequest<Bentos_Vmm_V1_TakeSnapshotRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Bentos_Vmm_V1_SnapshotResult> {
        guard !request.message.path.isEmpty else {
            throw RPCError(code: .invalidArgument, message: "path must be non-empty")
        }
        do {
            let snap = try await manager.createSnapshot(
                request.message.machineID,
                path: request.message.path
            )
            var result = Bentos_Vmm_V1_SnapshotResult()
            result.path = snap.path ?? request.message.path
            result.sizeBytes = UInt64(snap.sizeBytes)
            result.takenAt = ISO8601DateFormatter().string(from: snap.createdAt)
            return ServerResponse(message: result)
        } catch let e as VmmApiError {
            throw e.rpcError
        }
    }

    func restoreSnapshot(
        request: ServerRequest<Bentos_Vmm_V1_RestoreSnapshotRequest>,
        context: ServerContext
    ) async throws -> ServerResponse<Bentos_Vmm_V1_RestoreSnapshotResponse> {
        guard !request.message.path.isEmpty else {
            throw RPCError(code: .invalidArgument, message: "path must be non-empty")
        }
        do {
            try await manager.restoreSnapshot(
                request.message.machineID,
                path: request.message.path
            )
            return ServerResponse(message: Bentos_Vmm_V1_RestoreSnapshotResponse())
        } catch let e as VmmApiError {
            throw e.rpcError
        }
    }

    // MARK: - Streaming (r3)

    func watchEvents(
        request: ServerRequest<Bentos_Vmm_V1_WatchMachineEventsRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Bentos_Vmm_V1_MachineEvent> {
        throw RPCError(code: .unimplemented, message: "WatchEvents: implemented in r3")
    }

    func console(
        request: StreamingServerRequest<Bentos_Vmm_V1_ConsoleClientMessage>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Bentos_Vmm_V1_ConsoleServerMessage> {
        throw RPCError(code: .unimplemented, message: "Console: implemented in r3")
    }

    func exec(
        request: StreamingServerRequest<Bentos_Vmm_V1_ExecClientMessage>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Bentos_Vmm_V1_ExecServerMessage> {
        throw RPCError(code: .unimplemented, message: "Exec: implemented in r3")
    }
}
