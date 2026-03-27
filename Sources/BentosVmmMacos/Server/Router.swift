import Foundation
import NIOCore
import NIOHTTP1

/// Route match result from pattern-matching on method + path segments.
enum Route: Sendable {
    // VMM backend
    case ping                                    // GET  /api/v1/vmm/ping
    case capabilities                            // GET  /api/v1/vmm/capabilities

    // Machine CRUD
    case createMachine                           // POST /api/v1/machines
    case listMachines                            // GET  /api/v1/machines
    case getMachine(id: String)                  // GET  /api/v1/machines/{id}
    case deleteMachine(id: String)               // DELETE /api/v1/machines/{id}

    // Machine operations
    case startMachine(id: String)                // POST /api/v1/machines/{id}/start
    case stopMachine(id: String)                 // POST /api/v1/machines/{id}/stop
    case pauseMachine(id: String)                // POST /api/v1/machines/{id}/pause
    case resumeMachine(id: String)               // POST /api/v1/machines/{id}/resume
    case powerButton(id: String)                 // POST /api/v1/machines/{id}/power-button
    case resizeMachine(id: String)               // POST /api/v1/machines/{id}/resize

    // Snapshots
    case createSnapshot(machineId: String)       // POST /api/v1/machines/{id}/snapshots
    case listSnapshots(machineId: String)        // GET  /api/v1/machines/{id}/snapshots
    case deleteSnapshot(machineId: String, snapshotId: String) // DELETE /api/v1/machines/{id}/snapshots/{sid}
    case restoreSnapshot(machineId: String, snapshotId: String) // POST /api/v1/machines/{id}/snapshots/{sid}/restore

    // Streaming
    case console(machineId: String)              // GET  /api/v1/machines/{id}/console
    case events(machineId: String)               // GET  /api/v1/machines/{id}/events

    // Exec
    case exec(machineId: String)                 // GET  /api/v1/machines/{id}/exec (WebSocket)
}

/// Result of routing an HTTP request.
enum RouteResult: Sendable {
    case matched(Route)
    case notFound(method: String, path: String)
    case methodNotAllowed(method: String, path: String)
}

/// Pure function: (method, path) -> RouteResult. No state, no side effects.
func route(method: HTTPMethod, path: String) -> RouteResult {
    let segs = path.split(separator: "/").map(String.init)
    let m = "\(method)"

    // All routes start with ["api", "v1", ...]
    guard segs.count >= 3, segs[0] == "api", segs[1] == "v1" else {
        return .notFound(method: m, path: path)
    }

    let rest = Array(segs[2...])
    let n = rest.count

    // /api/v1/vmm/ping
    if n == 2, rest[0] == "vmm", rest[1] == "ping" {
        return method == .GET
            ? .matched(.ping)
            : .methodNotAllowed(method: m, path: path)
    }

    // /api/v1/vmm/capabilities
    if n == 2, rest[0] == "vmm", rest[1] == "capabilities" {
        return method == .GET
            ? .matched(.capabilities)
            : .methodNotAllowed(method: m, path: path)
    }

    // /api/v1/machines
    if n == 1, rest[0] == "machines" {
        switch method {
        case .POST: return .matched(.createMachine)
        case .GET:  return .matched(.listMachines)
        default:    return .methodNotAllowed(method: m, path: path)
        }
    }

    // Everything below requires rest[0] == "machines" and at least 2 segments.
    guard n >= 2, rest[0] == "machines" else {
        return .notFound(method: m, path: path)
    }

    let id = rest[1]

    // /api/v1/machines/{id}
    if n == 2 {
        switch method {
        case .GET:    return .matched(.getMachine(id: id))
        case .DELETE: return .matched(.deleteMachine(id: id))
        default:      return .methodNotAllowed(method: m, path: path)
        }
    }

    let sub = rest[2]

    // /api/v1/machines/{id}/{operation}
    if n == 3 {
        switch sub {
        case "start":
            return method == .POST ? .matched(.startMachine(id: id)) : .methodNotAllowed(method: m, path: path)
        case "stop":
            return method == .POST ? .matched(.stopMachine(id: id)) : .methodNotAllowed(method: m, path: path)
        case "pause":
            return method == .POST ? .matched(.pauseMachine(id: id)) : .methodNotAllowed(method: m, path: path)
        case "resume":
            return method == .POST ? .matched(.resumeMachine(id: id)) : .methodNotAllowed(method: m, path: path)
        case "power-button":
            return method == .POST ? .matched(.powerButton(id: id)) : .methodNotAllowed(method: m, path: path)
        case "resize":
            return method == .POST ? .matched(.resizeMachine(id: id)) : .methodNotAllowed(method: m, path: path)
        case "snapshots":
            switch method {
            case .POST: return .matched(.createSnapshot(machineId: id))
            case .GET:  return .matched(.listSnapshots(machineId: id))
            default:    return .methodNotAllowed(method: m, path: path)
            }
        case "console":
            return method == .GET ? .matched(.console(machineId: id)) : .methodNotAllowed(method: m, path: path)
        case "events":
            return method == .GET ? .matched(.events(machineId: id)) : .methodNotAllowed(method: m, path: path)
        case "exec":
            return method == .GET ? .matched(.exec(machineId: id)) : .methodNotAllowed(method: m, path: path)
        default:
            return .notFound(method: m, path: path)
        }
    }

    // /api/v1/machines/{id}/snapshots/{sid}
    if n == 4, sub == "snapshots" {
        let sid = rest[3]
        return method == .DELETE
            ? .matched(.deleteSnapshot(machineId: id, snapshotId: sid))
            : .methodNotAllowed(method: m, path: path)
    }

    // /api/v1/machines/{id}/snapshots/{sid}/restore
    if n == 5, sub == "snapshots", rest[4] == "restore" {
        let sid = rest[3]
        return method == .POST
            ? .matched(.restoreSnapshot(machineId: id, snapshotId: sid))
            : .methodNotAllowed(method: m, path: path)
    }

    return .notFound(method: m, path: path)
}
