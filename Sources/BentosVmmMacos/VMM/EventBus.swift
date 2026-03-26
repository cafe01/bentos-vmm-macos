import Foundation

/// Per-machine event broadcaster. Supports multiple SSE subscribers.
/// All access on @MainActor (same as MachineManager).
@MainActor
final class EventBus {
    private var continuations: [UUID: AsyncStream<MachineEvent>.Continuation] = [:]

    /// Subscribe to events. Returns an AsyncStream and a subscription ID for unsubscribe.
    func subscribe() -> (stream: AsyncStream<MachineEvent>, id: UUID) {
        let subId = UUID()
        let stream = AsyncStream<MachineEvent> { cont in
            self.continuations[subId] = cont
            cont.onTermination = { @Sendable _ in
                Task { @MainActor in
                    self.continuations.removeValue(forKey: subId)
                }
            }
        }
        return (stream, subId)
    }

    func unsubscribe(_ id: UUID) {
        continuations[id]?.finish()
        continuations.removeValue(forKey: id)
    }

    /// Broadcast an event to all subscribers.
    func emit(_ event: MachineEvent) {
        for (_, cont) in continuations {
            cont.yield(event)
        }
    }

    /// Number of active subscribers.
    var subscriberCount: Int { continuations.count }

    /// Shut down all subscribers.
    func shutdown() {
        for (_, cont) in continuations {
            cont.finish()
        }
        continuations.removeAll()
    }
}
