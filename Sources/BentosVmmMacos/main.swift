import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

let host = ProcessInfo.processInfo.environment["BENTOS_VMM_HOST"] ?? "127.0.0.1"
let port = Int(ProcessInfo.processInfo.environment["BENTOS_VMM_PORT"] ?? "50051") ?? 50051

let store = MachineStore()
let manager = await MachineManager(store: store)
try await manager.loadPersisted()

print("bentos-vmm-macos: listening on \(host):\(port)")

let server = GRPCServer(
    transport: .http2NIOPosix(
        address: .ipv4(host: host, port: port),
        transportSecurity: .plaintext
    ),
    services: [VmmServiceImpl(manager: manager)]
)

try await server.serve()
