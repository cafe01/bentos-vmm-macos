import GRPCCore
import Foundation
import Virtualization

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

    // MARK: - WatchEvents (server-stream)

    func watchEvents(
        request: ServerRequest<Bentos_Vmm_V1_WatchMachineEventsRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Bentos_Vmm_V1_MachineEvent> {
        let machineId = request.message.machineID

        // Verify machine exists and subscribe — single @MainActor hop.
        let eventStream: AsyncStream<MachineEvent>
        let subId: UUID
        do {
            (eventStream, subId) = try await manager.subscribeEvents(machineId)
        } catch let e as VmmApiError {
            throw e.rpcError
        }

        return StreamingServerResponse { [manager] writer in
            defer {
                Task { await manager.unsubscribeEvents(machineId, subId: subId) }
            }
            for await event in eventStream {
                // Client disconnect → task cancellation propagates into for-await.
                try Task.checkCancellation()
                try await writer.write(ProtoTranslator.toProtoEvent(event))
            }
            return Metadata()
        }
    }

    // MARK: - Console (bidi-stream)
    //
    // Lifecycle (§6 of bentos-vmm.proto):
    //   1. Client opens stream.
    //   2. First client message: ConsoleAttach { machine_id }.
    //   3. Server attaches to guest serial port; bytes flow bidirectionally.
    //   4. Either side closes → stream ends. Guest serial port persists.

    func console(
        request: StreamingServerRequest<Bentos_Vmm_V1_ConsoleClientMessage>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Bentos_Vmm_V1_ConsoleServerMessage> {
        // All setup happens inside the producer so no non-Sendable values cross
        // the @Sendable closure boundary. `request` is Sendable; captured safely.
        return StreamingServerResponse { [manager] writer in
            // First client message must be ConsoleAttach.
            var inbound = request.messages.makeAsyncIterator()
            guard let first = try await inbound.next() else {
                throw RPCError(code: .invalidArgument, message: "Console stream ended without attach message")
            }
            guard case .attach(let attach) = first.payload else {
                throw RPCError(code: .invalidArgument, message: "First Console message must be ConsoleAttach")
            }
            let machineId = attach.machineID

            let consoleIO: ConsoleIO
            do {
                consoleIO = try await manager.acquireConsole(machineId)
            } catch let e as VmmApiError {
                throw e.rpcError
            }

            defer {
                Task { await manager.releaseConsole(machineId) }
            }

            // Background Task: guest stdout → gRPC writer.
            let readerTask = Task {
                for await chunk in consoleIO.hostReadHandle.asyncReadStream {
                    var msg = Bentos_Vmm_V1_ConsoleServerMessage()
                    msg.payload = .stdout(chunk)
                    try await writer.write(msg)
                }
            }

            // Foreground: gRPC client stdin → guest.
            do {
                while let msg = try await inbound.next() {
                    if case .stdin(let bytes) = msg.payload {
                        try consoleIO.hostWriteHandle.write(contentsOf: bytes)
                    }
                }
            } catch {
                readerTask.cancel()
                throw error
            }

            // Client closed stream — cancel reader and drain.
            readerTask.cancel()
            _ = try? await readerTask.value
            return Metadata()
        }
    }

    // MARK: - Exec (bidi-stream)
    //
    // Lifecycle (§7 of bentos-vmm.proto):
    //   1. Client opens stream.
    //   2. First client message: ExecRequest { machine_id, cmd, ... }.
    //   3. Server connects vsock to bentos-execd (port 5100) and sends TLV EXEC_REQUEST.
    //   4. execd responds with TLV EXEC_STARTED → server emits ExecStarted { pid }.
    //   5. Client streams stdin; server streams stdout/stderr.
    //   6. Client sends ExecStdinEof; process exits → server emits ExecExited and closes.
    //   7. On execd failure → server emits ExecError and closes.

    func exec(
        request: StreamingServerRequest<Bentos_Vmm_V1_ExecClientMessage>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Bentos_Vmm_V1_ExecServerMessage> {
        // All setup inside producer: `request` is Sendable; `VsockConnectionBox` is Sendable.
        return StreamingServerResponse { [manager] writer in
            // First message must be ExecRequest.
            var inbound = request.messages.makeAsyncIterator()
            guard let first = try await inbound.next() else {
                throw RPCError(code: .invalidArgument, message: "Exec stream ended without request message")
            }
            guard case .request(let execReq) = first.payload else {
                throw RPCError(code: .invalidArgument, message: "First Exec message must be ExecRequest")
            }
            let machineId = execReq.machineID

            // Connect vsock to bentos-execd (port 5100).
            // vsockConnectBox wraps VZVirtioSocketConnection in a Sendable box on @MainActor.
            let connBox: VsockConnectionBox
            do {
                connBox = try await manager.vsockConnectBox(machineId, port: 5100)
            } catch let e as VmmApiError {
                // UNAVAILABLE per spec §conformance-8: execd not reachable.
                let code: RPCError.Code = e.message.contains("vsock") ? .unavailable : e.rpcError.code
                throw RPCError(code: code, message: e.message)
            }

            let fd = connBox.fileDescriptor
            defer { connBox.close() }

            // Send EXEC_REQUEST TLV frame.
            var wireReq = Bentos_Exec_ExecRequest()
            wireReq.cmd = Array(execReq.cmd)
            wireReq.env = execReq.env
            wireReq.cwd = execReq.cwd
            wireReq.tty = execReq.tty
            wireReq.rows = execReq.rows
            wireReq.cols = execReq.cols

            let reqData = try wireReq.serializedData()
            try ExecWire.writeAll(fd: fd, data: ExecWire.frame(type: ExecWire.typeExecRequest, payload: reqData))

            // Read first response: must be EXEC_STARTED or EXEC_ERROR.
            let (firstType, firstPayload) = try ExecWire.readFrame(fd: fd)
            switch firstType {
            case ExecWire.typeExecStarted:
                let started = try Bentos_Exec_ExecStarted(serializedBytes: firstPayload)
                var msg = Bentos_Vmm_V1_ExecServerMessage()
                var s = Bentos_Vmm_V1_ExecStarted()
                s.pid = started.pid
                msg.payload = .started(s)
                try await writer.write(msg)
            case ExecWire.typeExecError:
                let err = try Bentos_Exec_ExecError(serializedBytes: firstPayload)
                var msg = Bentos_Vmm_V1_ExecServerMessage()
                var e = Bentos_Vmm_V1_ExecError()
                e.error = err.error
                msg.payload = .error(e)
                try await writer.write(msg)
                return Metadata()
            default:
                throw RPCError(code: .internalError, message: "execd: unexpected first frame 0x\(String(firstType, radix: 16))")
            }

            // Concurrent I/O pump: vsock ↔ gRPC.
            //
            // Two directions must run concurrently, but `inbound` (the gRPC client iterator)
            // is not Sendable and cannot cross a TaskGroup.addTask boundary. Pattern: run the
            // vsock→gRPC reader in a background Task (captures only `fd` and `writer`, both
            // Sendable); drive the gRPC client→vsock writer in the foreground (owns `inbound`).

            // Background: vsock → gRPC writer. Captures fd (Int32) + writer (Sendable).
            let readerTask = Task {
                for await result in ExecWire.frameStream(fd: fd) {
                    let (type, payload) = try result.get()
                    var outMsg = Bentos_Vmm_V1_ExecServerMessage()
                    switch type {
                    case ExecWire.typeStdoutData:
                        outMsg.payload = .stdout(payload)
                        try await writer.write(outMsg)
                    case ExecWire.typeStderrData:
                        outMsg.payload = .stderr(payload)
                        try await writer.write(outMsg)
                    case ExecWire.typeExitStatus:
                        let status = try Bentos_Exec_ExitStatus(serializedBytes: payload)
                        var exited = Bentos_Vmm_V1_ExecExited()
                        exited.code = status.code
                        exited.signal = status.signal
                        outMsg.payload = .exited(exited)
                        try await writer.write(outMsg)
                        return  // process done — EXIT_STATUS terminates the reader
                    case ExecWire.typeExecError:
                        let e = try Bentos_Exec_ExecError(serializedBytes: payload)
                        var errMsg = Bentos_Vmm_V1_ExecError()
                        errMsg.error = e.error
                        outMsg.payload = .error(errMsg)
                        try await writer.write(outMsg)
                        return
                    default:
                        break  // unknown frame — forward-compat: skip
                    }
                }
            }

            // Foreground: gRPC client → vsock. Owns `inbound` — no Sendable crossing.
            do {
                while let inMsg = try await inbound.next() {
                    switch inMsg.payload {
                    case .stdin(let bytes):
                        try ExecWire.writeAll(fd: fd, data: ExecWire.frame(
                            type: ExecWire.typeStdinData, payload: bytes))
                    case .stdinEof:
                        try ExecWire.writeAll(fd: fd, data: ExecWire.frame(
                            type: ExecWire.typeStdinEof))
                    case .windowResize(let wr):
                        var resize = Bentos_Exec_WindowResize()
                        resize.rows = wr.rows
                        resize.cols = wr.cols
                        let data = try resize.serializedData()
                        try ExecWire.writeAll(fd: fd, data: ExecWire.frame(
                            type: ExecWire.typeWindowResize, payload: data))
                    case .signal(let sig):
                        var signal = Bentos_Exec_Signal()
                        signal.signal = sig.signal
                        let data = try signal.serializedData()
                        try ExecWire.writeAll(fd: fd, data: ExecWire.frame(
                            type: ExecWire.typeSignal, payload: data))
                    case .request:
                        break  // duplicate request — ignore
                    case nil:
                        break
                    }
                }
                // Client closed stream — send EOF to execd.
                try? ExecWire.writeAll(fd: fd, data: ExecWire.frame(type: ExecWire.typeStdinEof))
            } catch {
                readerTask.cancel()
                throw error
            }

            // Foreground done. Wait for reader to drain or cancel.
            readerTask.cancel()
            _ = try? await readerTask.value

            return Metadata()
        }
    }
}
