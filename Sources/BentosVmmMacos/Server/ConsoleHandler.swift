import Foundation
import NIOCore
import NIOWebSocket

/// NIO WebSocket handler: bridges WebSocket frames <-> ConsoleIO FileHandle pair.
/// One per console connection. Cleans up on disconnect.
final class ConsoleHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let machineId: String
    private let consoleIO: ConsoleIO
    private let manager: MachineManager
    private var channel: (any Channel)?

    init(machineId: String, consoleIO: ConsoleIO, manager: MachineManager) {
        self.machineId = machineId
        self.consoleIO = consoleIO
        self.manager = manager
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel

        // Guest -> WebSocket: forward console output to WebSocket client
        let eventLoop = context.eventLoop
        nonisolated(unsafe) let ctx = context
        consoleIO.hostReadHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            eventLoop.execute {
                guard ctx.channel.isActive else { return }
                var buf = ctx.channel.allocator.buffer(capacity: data.count)
                buf.writeBytes(data)
                let frame = WebSocketFrame(fin: true, opcode: .binary, data: buf)
                ctx.writeAndFlush(self.wrapOutboundOut(frame), promise: nil)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .binary, .text:
            // WebSocket -> Guest: forward input to guest stdin
            var buf = frame.data
            if let bytes = buf.readBytes(length: buf.readableBytes) {
                consoleIO.hostWriteHandle.write(Data(bytes))
            }

        case .connectionClose:
            cleanup()
            context.close(promise: nil)

        case .ping:
            var pongData = context.channel.allocator.buffer(capacity: frame.data.readableBytes)
            pongData.writeImmutableBuffer(frame.data)
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: pongData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)

        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        cleanup()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        cleanup()
        context.close(promise: nil)
    }

    private func cleanup() {
        consoleIO.hostReadHandle.readabilityHandler = nil
        let id = machineId
        let mgr = manager
        Task { @MainActor in
            mgr.releaseConsole(id)
        }
    }
}
