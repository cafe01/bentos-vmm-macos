import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

/// SwiftNIO HTTP server bound to a Unix domain socket.
final class HttpServer: @unchecked Sendable {
    let socketPath: String
    let startTime: ContinuousDate
    let manager: MachineManager

    init(socketPath: String, manager: MachineManager) {
        self.socketPath = socketPath
        self.startTime = ContinuousDate()
        self.manager = manager
    }

    /// Start the server and return a handle for programmatic shutdown (tests).
    func start() async throws -> ServerHandle {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let startTime = self.startTime
        let manager = self.manager

        let wsUpgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, head in
                // Upgrade console and exec WebSocket paths.
                let path = String(head.uri.split(separator: "?", maxSplits: 1).first ?? Substring(head.uri))
                let segs = path.split(separator: "/").map(String.init)
                // /api/v1/machines/{id}/console  (5 segments)
                if segs.count == 5,
                   segs[0] == "api", segs[1] == "v1", segs[2] == "machines", segs[4] == "console" {
                    return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                }
                // /api/v1/machines/{id}/exec  (5 segments)
                if segs.count == 5,
                   segs[0] == "api", segs[1] == "v1", segs[2] == "machines", segs[4] == "exec" {
                    return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                }
                return channel.eventLoop.makeSucceededFuture(nil)
            },
            upgradePipelineHandler: { channel, head in
                let path = String(head.uri.split(separator: "?", maxSplits: 1).first ?? Substring(head.uri))
                let segs = path.split(separator: "/").map(String.init)
                let machineId = segs[3]
                let endpoint = segs[4]

                let promise = channel.eventLoop.makePromise(of: Void.self)

                if endpoint == "exec" {
                    // Interactive exec: connect vsock, install ExecHandler
                    Task { @MainActor in
                        do {
                            let conn = try await manager.vsockConnect(machineId, port: 5100)
                            let handler = ExecHandler(machineId: machineId, conn: conn)
                            channel.eventLoop.execute {
                                channel.pipeline.addHandler(handler).whenComplete { result in
                                    switch result {
                                    case .success: promise.succeed(())
                                    case .failure(let err): promise.fail(err)
                                    }
                                }
                            }
                        } catch {
                            promise.fail(error)
                        }
                    }
                } else {
                    // Console: acquire console IO, install ConsoleHandler
                    Task { @MainActor in
                        do {
                            let consoleIO = try manager.acquireConsole(machineId)
                            let handler = ConsoleHandler(
                                machineId: machineId, consoleIO: consoleIO, manager: manager)
                            channel.eventLoop.execute {
                                channel.pipeline.addHandler(handler).whenComplete { result in
                                    switch result {
                                    case .success: promise.succeed(())
                                    case .failure(let err): promise.fail(err)
                                    }
                                }
                            }
                        } catch {
                            promise.fail(error)
                        }
                    }
                }

                return promise.futureResult
            }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .childChannelInitializer { channel in
                let upgradeConfig: NIOHTTPServerUpgradeSendableConfiguration = (
                    upgraders: [wsUpgrader],
                    completionHandler: { ctx in
                        // Remove HttpHandler after WebSocket upgrade — it would
                        // misinterpret raw WS frames as HTTP otherwise.
                        ctx.pipeline.context(handlerType: HttpHandler.self).whenSuccess { httpCtx in
                            try? ctx.pipeline.syncOperations.removeHandler(context: httpCtx)
                        }
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: upgradeConfig
                ).flatMap {
                    channel.pipeline.addHandler(
                        HttpHandler(startTime: startTime, manager: manager)
                    )
                }
            }
            .childChannelOption(.maxMessagesPerRead, value: 1)

        let channel = try await bootstrap.bind(
            unixDomainSocketPath: socketPath
        ).get()

        return ServerHandle(channel: channel, group: group, socketPath: socketPath)
    }

    /// Run until SIGINT or SIGTERM. Used by main.swift.
    func run() async throws {
        let handle = try await start()
        print("bentos-vmm-macos listening on \(socketPath)")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            func installSignal(_ sig: Int32) {
                let src = DispatchSource.makeSignalSource(signal: sig)
                Foundation.signal(sig, SIG_IGN)
                src.setEventHandler {
                    src.cancel()
                    cont.resume()
                }
                src.resume()
            }
            installSignal(SIGTERM)
            installSignal(SIGINT)
        }

        try await handle.shutdown()
        print("bentos-vmm-macos stopped")
    }
}

/// Handle for stopping a running server.
final class ServerHandle: Sendable {
    private let channel: any Channel
    private let group: MultiThreadedEventLoopGroup
    private let socketPath: String

    init(channel: any Channel, group: MultiThreadedEventLoopGroup, socketPath: String) {
        self.channel = channel
        self.group = group
        self.socketPath = socketPath
    }

    func shutdown() async throws {
        try await channel.close()
        try await group.shutdownGracefully()
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}

/// Tracks server start time using monotonic clock.
struct ContinuousDate: Sendable {
    private let ref = ContinuousClock.now

    var uptimeSeconds: Int {
        Int((ContinuousClock.now - ref).components.seconds)
    }
}
