import Testing
import Virtualization
@testable import BentosVmmMacos

@Suite("StateMapper")
struct StateMapperTests {
    @Test func allStatesMap() {
        #expect(StateMapper.map(.stopped) == .stopped)
        #expect(StateMapper.map(.running) == .running)
        #expect(StateMapper.map(.paused) == .paused)
        #expect(StateMapper.map(.starting) == .starting)
        #expect(StateMapper.map(.stopping) == .stopping)
        #expect(StateMapper.map(.error) == .error)
    }
}
