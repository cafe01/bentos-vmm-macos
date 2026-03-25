import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

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
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
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
