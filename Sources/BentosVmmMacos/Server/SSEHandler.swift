import Foundation
import NIOCore
import NIOHTTP1

/// Writes SSE events to a long-lived HTTP response.
/// Each event: "data: {json}\n\n"
final class SSEHandler: @unchecked Sendable {
    private let machineId: String
    private let eventBus: EventBus
    private var subId: UUID?
    private var task: Task<Void, Never>?

    init(machineId: String, eventBus: EventBus) {
        self.machineId = machineId
        self.eventBus = eventBus
    }

    /// Start streaming SSE events on the given channel handler context.
    /// Writes HTTP head immediately, then streams events until channel closes.
    func start(context: ChannelHandlerContext) {
        // Write SSE response head
        let head = HTTPResponseHead(
            version: .http1_1,
            status: .ok,
            headers: [
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
            ]
        )
        context.write(wrapHead(head), promise: nil)
        context.flush()

        // Subscribe to events
        let eventLoop = context.eventLoop
        nonisolated(unsafe) let ctx = context

        Task { @MainActor in
            let (stream, subId) = self.eventBus.subscribe()
            self.subId = subId

            // Stream events in a detached task to avoid blocking @MainActor
            self.task = Task.detached { [weak self] in
                for await event in stream {
                    guard let self else { break }
                    guard let data = try? JSONEncoder.vmm.encode(event) else { continue }
                    let line = "data: \(String(data: data, encoding: .utf8) ?? "")\n\n"
                    eventLoop.execute {
                        guard ctx.channel.isActive else { return }
                        var buf = ctx.channel.allocator.buffer(capacity: line.utf8.count)
                        buf.writeString(line)
                        ctx.writeAndFlush(self.wrapBody(buf), promise: nil)
                    }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let subId {
            let bus = eventBus
            let id = subId
            Task { @MainActor in
                bus.unsubscribe(id)
            }
        }
        subId = nil
    }

    private func wrapHead(_ head: HTTPResponseHead) -> NIOAny {
        NIOAny(HTTPServerResponsePart.head(head))
    }

    private func wrapBody(_ buf: ByteBuffer) -> NIOAny {
        NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf)))
    }
}
