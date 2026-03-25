import Foundation
import NIOCore
import NIOPosix

let defaultSocketPath = "/tmp/bentos-vmm.sock"

let socketPath = ProcessInfo.processInfo.environment["BENTOS_VMM_SOCKET"]
    ?? defaultSocketPath

// Remove stale socket file.
let fm = FileManager.default
if fm.fileExists(atPath: socketPath) {
    try fm.removeItem(atPath: socketPath)
}

let store = MachineStore()
let manager = await MachineManager(store: store)
try await manager.loadPersisted()

let server = HttpServer(socketPath: socketPath, manager: manager)
try await server.run()
