import Foundation
import Testing
@testable import BentosVmmMacos

@Suite("EventBus")
struct EventBusTests {

    @Test @MainActor func emitToSingleSubscriber() async throws {
        let bus = EventBus()
        let (stream, _) = bus.subscribe()

        let event = MachineEvent.stateChanged(
            timestamp: Date(), previousState: .stopped, newState: .starting)
        bus.emit(event)

        var it = stream.makeAsyncIterator()
        let received = await it.next()
        #expect(received == event)
    }

    @Test @MainActor func emitToMultipleSubscribers() async throws {
        let bus = EventBus()
        let (stream1, _) = bus.subscribe()
        let (stream2, _) = bus.subscribe()

        #expect(bus.subscriberCount == 2)

        let event = MachineEvent.stateChanged(
            timestamp: Date(), previousState: .running, newState: .stopping)
        bus.emit(event)

        var it1 = stream1.makeAsyncIterator()
        var it2 = stream2.makeAsyncIterator()
        let r1 = await it1.next()
        let r2 = await it2.next()
        #expect(r1 == event)
        #expect(r2 == event)
    }

    @Test @MainActor func unsubscribeRemovesSubscriber() async throws {
        let bus = EventBus()
        let (_, subId) = bus.subscribe()
        #expect(bus.subscriberCount == 1)

        bus.unsubscribe(subId)
        #expect(bus.subscriberCount == 0)
    }

    @Test @MainActor func shutdownFinishesAllSubscribers() async throws {
        let bus = EventBus()
        let (stream, _) = bus.subscribe()
        let (_, _) = bus.subscribe()
        #expect(bus.subscriberCount == 2)

        bus.shutdown()
        #expect(bus.subscriberCount == 0)

        // Stream should complete
        var it = stream.makeAsyncIterator()
        let last = await it.next()
        #expect(last == nil)
    }
}
