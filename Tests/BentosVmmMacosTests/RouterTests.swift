import Testing
import NIOHTTP1
@testable import BentosVmmMacos

@Suite("Router")
struct RouterTests {

    // MARK: - VMM backend

    @Test func pingRoute() {
        let r = route(method: .GET, path: "/api/v1/vmm/ping")
        guard case .matched(.ping) = r else { Issue.record("Expected .ping, got \(r)"); return }
    }

    @Test func capabilitiesRoute() {
        let r = route(method: .GET, path: "/api/v1/vmm/capabilities")
        guard case .matched(.capabilities) = r else { Issue.record("Expected .capabilities, got \(r)"); return }
    }

    // MARK: - Machine CRUD

    @Test func createMachineRoute() {
        let r = route(method: .POST, path: "/api/v1/machines")
        guard case .matched(.createMachine) = r else { Issue.record("Expected .createMachine, got \(r)"); return }
    }

    @Test func listMachinesRoute() {
        let r = route(method: .GET, path: "/api/v1/machines")
        guard case .matched(.listMachines) = r else { Issue.record("Expected .listMachines, got \(r)"); return }
    }

    @Test func getMachineRoute() {
        let r = route(method: .GET, path: "/api/v1/machines/abc-123")
        guard case .matched(.getMachine(id: "abc-123")) = r else { Issue.record("Expected .getMachine, got \(r)"); return }
    }

    @Test func deleteMachineRoute() {
        let r = route(method: .DELETE, path: "/api/v1/machines/abc-123")
        guard case .matched(.deleteMachine(id: "abc-123")) = r else { Issue.record("Expected .deleteMachine, got \(r)"); return }
    }

    // MARK: - Machine operations

    @Test func startMachineRoute() {
        let r = route(method: .POST, path: "/api/v1/machines/x/start")
        guard case .matched(.startMachine(id: "x")) = r else { Issue.record("Expected .startMachine, got \(r)"); return }
    }

    @Test func stopMachineRoute() {
        let r = route(method: .POST, path: "/api/v1/machines/x/stop")
        guard case .matched(.stopMachine(id: "x")) = r else { Issue.record("Expected .stopMachine, got \(r)"); return }
    }

    @Test func pauseMachineRoute() {
        let r = route(method: .POST, path: "/api/v1/machines/x/pause")
        guard case .matched(.pauseMachine(id: "x")) = r else { Issue.record("Expected .pauseMachine, got \(r)"); return }
    }

    @Test func resumeMachineRoute() {
        let r = route(method: .POST, path: "/api/v1/machines/x/resume")
        guard case .matched(.resumeMachine(id: "x")) = r else { Issue.record("Expected .resumeMachine, got \(r)"); return }
    }

    @Test func powerButtonRoute() {
        let r = route(method: .POST, path: "/api/v1/machines/x/power-button")
        guard case .matched(.powerButton(id: "x")) = r else { Issue.record("Expected .powerButton, got \(r)"); return }
    }

    @Test func resizeMachineRoute() {
        let r = route(method: .POST, path: "/api/v1/machines/x/resize")
        guard case .matched(.resizeMachine(id: "x")) = r else { Issue.record("Expected .resizeMachine, got \(r)"); return }
    }

    // MARK: - Snapshots

    @Test func createSnapshotRoute() {
        let r = route(method: .POST, path: "/api/v1/machines/x/snapshots")
        guard case .matched(.createSnapshot(machineId: "x")) = r else { Issue.record("Expected .createSnapshot, got \(r)"); return }
    }

    @Test func listSnapshotsRoute() {
        let r = route(method: .GET, path: "/api/v1/machines/x/snapshots")
        guard case .matched(.listSnapshots(machineId: "x")) = r else { Issue.record("Expected .listSnapshots, got \(r)"); return }
    }

    @Test func deleteSnapshotRoute() {
        let r = route(method: .DELETE, path: "/api/v1/machines/x/snapshots/s1")
        guard case .matched(.deleteSnapshot(machineId: "x", snapshotId: "s1")) = r else { Issue.record("Expected .deleteSnapshot, got \(r)"); return }
    }

    @Test func restoreSnapshotRoute() {
        let r = route(method: .POST, path: "/api/v1/machines/x/snapshots/s1/restore")
        guard case .matched(.restoreSnapshot(machineId: "x", snapshotId: "s1")) = r else { Issue.record("Expected .restoreSnapshot, got \(r)"); return }
    }

    // MARK: - Streaming

    @Test func consoleRoute() {
        let r = route(method: .GET, path: "/api/v1/machines/x/console")
        guard case .matched(.console(machineId: "x")) = r else { Issue.record("Expected .console, got \(r)"); return }
    }

    @Test func eventsRoute() {
        let r = route(method: .GET, path: "/api/v1/machines/x/events")
        guard case .matched(.events(machineId: "x")) = r else { Issue.record("Expected .events, got \(r)"); return }
    }

    // MARK: - Error cases

    @Test func unknownPathReturns404() {
        let r = route(method: .GET, path: "/api/v1/nope")
        guard case .notFound = r else { Issue.record("Expected .notFound, got \(r)"); return }
    }

    @Test func wrongMethodReturns405() {
        let r = route(method: .DELETE, path: "/api/v1/vmm/ping")
        guard case .methodNotAllowed = r else { Issue.record("Expected .methodNotAllowed, got \(r)"); return }
    }

    @Test func putOnMachinesReturns405() {
        let r = route(method: .PUT, path: "/api/v1/machines")
        guard case .methodNotAllowed = r else { Issue.record("Expected .methodNotAllowed, got \(r)"); return }
    }

    @Test func getOnStartReturns405() {
        let r = route(method: .GET, path: "/api/v1/machines/x/start")
        guard case .methodNotAllowed = r else { Issue.record("Expected .methodNotAllowed, got \(r)"); return }
    }

    @Test func nonApiPathReturns404() {
        let r = route(method: .GET, path: "/health")
        guard case .notFound = r else { Issue.record("Expected .notFound, got \(r)"); return }
    }
}
