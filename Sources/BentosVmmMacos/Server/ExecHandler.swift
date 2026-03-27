import Foundation
import NIOCore
import NIOWebSocket
import Virtualization

/// NIO WebSocket handler for interactive exec sessions.
/// Bridges WebSocket binary frames <-> vsock TLV stream to bentos-execd on port 5100.
///
/// Frame protocol (raw binary over WebSocket):
///   Client -> server: TLV frames (ExecRequest protobuf), same wire format as bentos-execd.
///   Server -> client: TLV frames (ExecResponse / StdoutData / ExitStatus protobuf).
///
/// The handler is a transparent byte pipe: it does NOT parse TLV on the host side.
/// The guest-side bentos-execd owns the protocol; the host just relays bytes.
final class ExecHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let machineId: String
    private let conn: VZVirtioSocketConnection
    private var channel: (any Channel)?

    init(machineId: String, conn: VZVirtioSocketConnection) {
        self.machineId = machineId
        self.conn = conn
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
        let eventLoop = context.eventLoop
        nonisolated(unsafe) let ctx = context
        let fileHandle = FileHandle(fileDescriptor: conn.fileDescriptor, closeOnDealloc: false)

        // Guest -> WebSocket: forward vsock bytes to WebSocket client as binary frames.
        fileHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: guest closed connection
                eventLoop.execute {
                    guard ctx.channel.isActive else { return }
                    let closeFrame = WebSocketFrame(
                        fin: true, opcode: .connectionClose,
                        data: ctx.channel.allocator.buffer(capacity: 0))
                    ctx.writeAndFlush(self.wrapOutboundOut(closeFrame), promise: nil)
                    ctx.close(promise: nil)
                }
                return
            }
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
            // WebSocket -> Guest: forward bytes into vsock.
            var buf = frame.data
            if let bytes = buf.readBytes(length: buf.readableBytes) {
                let fd = conn.fileDescriptor
                _ = Data(bytes).withUnsafeBytes { ptr in
                    Darwin.write(fd, ptr.baseAddress!, ptr.count)
                }
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
        FileHandle(fileDescriptor: conn.fileDescriptor, closeOnDealloc: false).readabilityHandler = nil
        conn.close()
    }
}
