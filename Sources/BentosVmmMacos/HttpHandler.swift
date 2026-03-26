import Foundation
import NIOCore
import NIOHTTP1

/// Serializable response produced on @MainActor, written on the event loop.
enum HttpResponse: Sendable {
    case json(status: HTTPStatus, bytes: [UInt8])
    case noContent
    case error(VmmApiError)
    case sse(machineId: String)
}

/// NIO channel handler: accumulates request, dispatches via Router, writes response.
final class HttpHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let startTime: ContinuousDate
    private let manager: MachineManager
    private var requestHead: HTTPRequestHead?
    private var body = ByteBuffer()
    private var sseHandler: SSEHandler?

    init(startTime: ContinuousDate, manager: MachineManager) {
        self.startTime = startTime
        self.manager = manager
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            body.clear()
        case .body(var buf):
            body.writeBuffer(&buf)
        case .end:
            guard let head = requestHead else { return }
            handleRequest(context: context, head: head, body: body)
            requestHead = nil
            body.clear()
        }
    }

    // MARK: - Dispatch

    private func handleRequest(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        body: ByteBuffer
    ) {
        let path = String(head.uri.split(separator: "?", maxSplits: 1).first ?? Substring(head.uri))
        let result = route(method: head.method, path: path)

        switch result {
        case .notFound(let method, let path):
            writeResponse(context: context,
                          response: .error(.notFound("No route for \(method) \(path)")))

        case .methodNotAllowed(let method, let path):
            writeResponse(context: context,
                          response: .error(.methodNotAllowed(method, path)))

        case .matched(let rt):
            let bodyBytes = Array(body.readableBytesView)
            let manager = self.manager
            let startTime = self.startTime
            let eventLoop = context.eventLoop
            // Do @MainActor work in Task, produce Sendable response, write on event loop.
            // Safety: context is only used on its owning event loop via execute().
            nonisolated(unsafe) let ctx = context
            Task { @MainActor in
                let response = await Self.handleRoute(
                    rt, bodyBytes: bodyBytes, manager: manager, startTime: startTime)
                eventLoop.execute {
                    self.writeResponse(context: ctx, response: response)
                }
            }
        }
    }

    /// Process route on @MainActor, return a Sendable response.
    @MainActor
    private static func handleRoute(
        _ rt: Route,
        bodyBytes: [UInt8],
        manager: MachineManager,
        startTime: ContinuousDate
    ) async -> HttpResponse {
        do {
            switch rt {
            case .ping:
                let health = VmmHealth(
                    healthy: true,
                    machineCount: manager.machines.count,
                    uptimeSeconds: startTime.uptimeSeconds
                )
                return try encodable(.ok, health)

            case .capabilities:
                return try encodable(.ok, macOSCapabilities())

            case .createMachine:
                let config = try decodeBody(BentosVmConfig.self, from: bodyBytes)
                let machine = try manager.create(config: config)
                return try encodable(.ok, machine.toBentosMachine())

            case .listMachines:
                let list = manager.list().map { $0.toBentosMachine() }
                return try encodable(.ok, MachineListResponse(machines: list))

            case .getMachine(let id):
                let machine = try manager.get(id)
                return try encodable(.ok, machine.toBentosMachine())

            case .deleteMachine(let id):
                try manager.delete(id)
                return .noContent

            case .startMachine(let id):
                try await manager.start(id)
                let machine = try manager.get(id)
                return try encodable(.ok, machine.toBentosMachine())

            case .stopMachine(let id):
                let force: Bool
                if !bodyBytes.isEmpty,
                   let body = try? JSONDecoder.vmm.decode(StopRequest.self, from: Data(bodyBytes)) {
                    force = body.force
                } else {
                    force = false
                }
                try await manager.stop(id, force: force)
                let machine = try manager.get(id)
                return try encodable(.ok, machine.toBentosMachine())

            case .pauseMachine(let id):
                try await manager.pause(id)
                let machine = try manager.get(id)
                return try encodable(.ok, machine.toBentosMachine())

            case .resumeMachine(let id):
                try await manager.resume(id)
                let machine = try manager.get(id)
                return try encodable(.ok, machine.toBentosMachine())

            case .powerButton(let id):
                try manager.pressePowerButton(id)
                return try encodable(.ok, EmptyResponse())

            case .resizeMachine(let id):
                let req = try decodeBody(ResizeRequest.self, from: bodyBytes)
                let result = try manager.resize(id, request: req)
                return try encodable(.ok, result)

            case .createSnapshot(let id):
                let snapReq: SnapshotRequest?
                if !bodyBytes.isEmpty {
                    snapReq = try? JSONDecoder.vmm.decode(SnapshotRequest.self, from: Data(bodyBytes))
                } else {
                    snapReq = nil
                }
                let snap = try await manager.createSnapshot(id, name: snapReq?.name)
                return try encodable(.ok, snap)

            case .listSnapshots(let id):
                let snaps = try manager.listSnapshots(id)
                return try encodable(.ok, SnapshotListResponse(snapshots: snaps))

            case .deleteSnapshot(let machineId, let snapshotId):
                try manager.deleteSnapshot(machineId, snapshotId: snapshotId)
                return .noContent

            case .restoreSnapshot(let machineId, let snapshotId):
                try await manager.restoreSnapshot(machineId, snapshotId: snapshotId)
                let machine = try manager.get(machineId)
                return try encodable(.ok, machine.toBentosMachine())
            case .console(let id):
                // WebSocket upgrade is handled by NIOWebSocketServerUpgrader in the pipeline.
                // If we reach here, the client didn't send upgrade headers — reject.
                // But first check if the machine is valid and console is available.
                let machine = try manager.get(id)
                if machine.state != .running && machine.state != .paused {
                    throw VmmApiError.conflict(
                        "Machine '\(id)' must be running for console (current state: \(machine.state))")
                }
                if machine.consoleConnected {
                    throw VmmApiError.conflict("Console already connected to machine '\(id)'")
                }
                throw VmmApiError.badRequest("Console endpoint requires WebSocket upgrade")
            case .events(let id):
                // Validate machine exists (eventBus throws if not found)
                let _ = try manager.eventBus(for: id)
                return .sse(machineId: id)
            }
        } catch let apiErr as VmmApiError {
            return .error(apiErr)
        } catch {
            return .error(.internalError(error.localizedDescription))
        }
    }

    // MARK: - Helpers

    private static func encodable<T: Encodable>(_ status: HTTPStatus, _ value: T) throws -> HttpResponse {
        let data = try JSONEncoder.vmm.encode(value)
        return .json(status: status, bytes: Array(data))
    }

    private static func decodeBody<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        guard !bytes.isEmpty else {
            throw VmmApiError.badRequest("Request body is empty")
        }
        do {
            return try JSONDecoder.vmm.decode(type, from: Data(bytes))
        } catch {
            throw VmmApiError.badRequest("Invalid JSON: \(error.localizedDescription)")
        }
    }

    // MARK: - Response writing (event loop only)

    func channelInactive(context: ChannelHandlerContext) {
        sseHandler?.stop()
        sseHandler = nil
        context.fireChannelInactive()
    }

    private func writeResponse(context: ChannelHandlerContext, response: HttpResponse) {
        switch response {
        case .json(let status, let bytes):
            writeJsonBytes(context: context, status: status, bytes: bytes)
        case .noContent:
            let head = HTTPResponseHead(
                version: .http1_1,
                status: .custom(code: 204, reasonPhrase: "No Content"),
                headers: ["Connection": "close"]
            )
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        case .error(let err):
            writeJsonBytes(context: context, status: err.status, bytes: err.jsonBytes)
        case .sse(let machineId):
            let mgr = self.manager
            let eventLoop = context.eventLoop
            nonisolated(unsafe) let ctx = context
            Task { @MainActor in
                do {
                    let bus = try mgr.eventBus(for: machineId)
                    let handler = SSEHandler(machineId: machineId, eventBus: bus)
                    eventLoop.execute {
                        self.sseHandler = handler
                        handler.start(context: ctx)
                    }
                } catch {
                    eventLoop.execute {
                        let err = VmmApiError.machineNotFound(machineId)
                        self.writeJsonBytes(context: ctx, status: err.status, bytes: err.jsonBytes)
                    }
                }
            }
        }
    }

    private func writeJsonBytes(
        context: ChannelHandlerContext,
        status: HTTPStatus,
        bytes: some Collection<UInt8>
    ) {
        var buf = context.channel.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)

        let head = HTTPResponseHead(
            version: .http1_1,
            status: .custom(code: UInt(status.rawValue), reasonPhrase: status.reasonPhrase),
            headers: [
                "Content-Type": "application/json",
                "Content-Length": "\(bytes.count)",
                "Connection": "close",
            ]
        )
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

// MARK: - Capabilities

private func macOSCapabilities() -> BentosVmmCapabilities {
    let physCores = ProcessInfo.processInfo.processorCount
    let physMem = ProcessInfo.processInfo.physicalMemory

    var sysInfo = utsname()
    uname(&sysInfo)
    let machine = withUnsafePointer(to: &sysInfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
    }
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

    return BentosVmmCapabilities(
        hotResize: false,
        liveMigration: false,
        bridgedNetwork: true,
        rosetta: true,
        snapshot: true,
        snapshotIncludesDisk: false,
        gpuPassthrough: false,
        maxVcpus: physCores,
        maxMemoryBytes: Int(physMem),
        availableMemoryBytes: Int(physMem),
        backendName: "bentos-vmm-macos",
        backendVersion: "0.1.0",
        platform: "macOS \(osVersion) \(machine)"
    )
}

// MARK: - Request/Response wrappers

struct MachineListResponse: Codable, Sendable {
    let machines: [BentosMachine]
}

struct StopRequest: Codable, Sendable {
    let force: Bool
}

struct EmptyResponse: Codable, Sendable {}

struct SnapshotRequest: Codable, Sendable {
    let name: String?
}

struct SnapshotListResponse: Codable, Sendable {
    let snapshots: [BentosSnapshot]
}

// MARK: - HTTPStatus reason phrases

extension HTTPStatus {
    var reasonPhrase: String {
        switch self {
        case .ok: "OK"
        case .noContent: "No Content"
        case .badRequest: "Bad Request"
        case .notFound: "Not Found"
        case .methodNotAllowed: "Method Not Allowed"
        case .conflict: "Conflict"
        case .internalServerError: "Internal Server Error"
        case .notImplemented: "Not Implemented"
        }
    }
}
