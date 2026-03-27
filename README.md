# bentos-vmm-macos

Standalone Swift daemon that wraps Apple's Virtualization.framework and serves the BentOS VMM REST API on a Unix domain socket. This is the macOS backend — one of several `bentos-vmm-*` processes that BentOS Console connects to. Console never links VZ.fw directly; it speaks HTTP to this daemon.

## Architecture

```
bentos-vmm-macos (this package)
+--------------------------------------------------------------+
|  SwiftNIO HTTP Server (Unix socket)                          |
|    /api/v1/machines, /api/v1/vmm/...                         |
|    JSON in/out. WebSocket for console + exec. SSE for events.|
|                                                              |
|  MachineManager (@MainActor)                                 |
|    machines: [String: ManagedMachine]                        |
|    Per machine: BentosVmConfig JSON + VZVirtualMachine       |
|                                                              |
|  Virtualization.framework                                    |
|    VZVirtualMachine instances on main queue                  |
|    Device backends: blk, net, vsock, console, entropy,       |
|                     balloon, virtiofs                         |
+--------------------------------------------------------------+
         |                            |
    Unix socket                  AppleHV.kext
         |                       ARM VHE hardware
    Dart CLI / Console                |
    (HttpVmmClient)              Guest Linux VM
                                 (Alpine + bentosd)
```

## The Contract

The canonical interface is defined in Dart at `lib/bentos_vmm/lib/src/`. This daemon must match that contract exactly:

- **types.dart** — 14 data types with `toJson()`/`fromJson()`. The JSON wire format.
- **vmm_client.dart** — 17 operations. The abstract interface.
- **http_vmm_client.dart** — The HTTP implementation. Defines endpoint paths, methods, and response expectations.
- **events.dart** — SSE event types (state_changed, error, control_channel).
- **errors.dart** — Error JSON format: `{"code": "...", "message": "..."}`.

If this code and the Dart client disagree, the Dart client wins.

## REST API

### Machines

| Method | Endpoint | Request Body | Response |
|--------|----------|-------------|----------|
| POST | `/api/v1/machines` | `BentosVmConfig` JSON | `BentosMachine` JSON (state: stopped) |
| GET | `/api/v1/machines` | - | `{"machines": [BentosMachine...]}` |
| GET | `/api/v1/machines/{id}` | - | `BentosMachine` JSON |
| DELETE | `/api/v1/machines/{id}` | - | 204 No Content |
| POST | `/api/v1/machines/{id}/start` | - | 200 OK |
| POST | `/api/v1/machines/{id}/stop` | `{"force": bool}` | 200 OK |
| POST | `/api/v1/machines/{id}/pause` | - | 200 OK |
| POST | `/api/v1/machines/{id}/resume` | - | 200 OK |
| POST | `/api/v1/machines/{id}/power-button` | - | 200 OK |
| POST | `/api/v1/machines/{id}/resize` | `ResizeRequest` JSON | `ResizeResult` JSON |

### Snapshots

| Method | Endpoint | Request Body | Response |
|--------|----------|-------------|----------|
| POST | `/api/v1/machines/{id}/snapshots` | `{"name": "..."}` (optional) | `BentosSnapshot` JSON |
| GET | `/api/v1/machines/{id}/snapshots` | - | `{"snapshots": [...]}` |
| DELETE | `/api/v1/machines/{id}/snapshots/{sid}` | - | 204 No Content |
| POST | `/api/v1/machines/{id}/snapshots/{sid}/restore` | - | 200 OK |

### Exec

| Method | Endpoint | Protocol | Description |
|--------|----------|----------|-------------|
| GET | `/api/v1/machines/{id}/exec` | WebSocket | Exec in guest via vsock + bentos-execd. TLV-framed binary. Interactive and one-shot (one-shot is a client-side pattern via `.collect()`). |

### Streaming

| Method | Endpoint | Protocol | Description |
|--------|----------|----------|-------------|
| GET | `/api/v1/machines/{id}/console` | WebSocket | Bidirectional serial console (raw bytes) |
| GET | `/api/v1/machines/{id}/events` | SSE | Machine events (`data: {JSON}\n\n`) |

### Backend

| Method | Endpoint | Response |
|--------|----------|----------|
| GET | `/api/v1/vmm/capabilities` | `BentosVmmCapabilities` JSON |
| GET | `/api/v1/vmm/ping` | `VmmHealth` JSON |

## Wire Format

- **snake_case** keys in all JSON (`cpu_count`, `memory_bytes`, `command_line`)
- **Enum values** as lowercase strings (`"stopped"`, `"running"`, `"nat"`)
- **Timestamps** as ISO 8601 (`"2026-03-24T10:30:00.000Z"`)
- **Sealed types** use a `"type"` discriminator (`ResizeResult.type`, `MachineEvent.type`, `NetworkConfig.mode`)
- **List responses** wrapped in a keyed object (`{"machines": [...]}`, `{"snapshots": [...]}`)
- **Errors** always: `{"code": "machine_not_found", "message": "No machine with id 'abc'"}` + appropriate HTTP status

## Capabilities (macOS)

```json
{
  "hot_resize": false,
  "live_migration": false,
  "bridged_network": true,
  "rosetta": true,
  "snapshot": true,
  "snapshot_includes_disk": false,
  "gpu_passthrough": false,
  "max_vcpus": <host physical cores>,
  "max_memory_bytes": <host physical memory>,
  "available_memory_bytes": <host available memory>,
  "backend_name": "bentos-vmm-macos",
  "backend_version": "0.1.0",
  "platform": "macOS <version> arm64"
}
```

## Project Structure

```
lib/bentos_vmm_macos/
+-- Package.swift
+-- entitlements.plist
+-- Sources/
|   +-- BentosVmmMacos/
|       +-- main.swift
|       +-- Server/
|       |   +-- Router.swift             Route dispatch (pattern matching)
|       |   +-- ConsoleHandler.swift     WebSocket bridge to virtio-console
|       |   +-- ExecHandler.swift        WebSocket bridge to vsock exec (TLV frames)
|       |   +-- SSEHandler.swift         SSE event stream
|       +-- HttpHandler.swift             NIO channel handler (request dispatch + response writing)
|       +-- HttpServer.swift             SwiftNIO on Unix socket + WebSocket upgrade
|       +-- VMM/
|       |   +-- MachineManager.swift     @MainActor, owns all VMs + vsockConnect
|       |   +-- ManagedMachine.swift     Per-machine state (config + VZVirtualMachine)
|       |   +-- MachineDelegate.swift    VZ.fw delegate callbacks
|       |   +-- ConfigTranslator.swift   BentosVmConfig JSON -> VZVirtualMachineConfiguration
|       |   +-- StateMapper.swift        VZVirtualMachine.state -> MachineState string
|       |   +-- EventBus.swift           Per-machine event publication
|       +-- Model/
|       |   +-- Types.swift              Swift mirrors of Dart types (JSON Codable)
|       |   +-- Errors.swift             VmmApiError JSON envelope
|       +-- Persistence/
|           +-- DiskManager.swift        Disk image creation + management
|           +-- MachineStore.swift       config.json + disk images + snapshots on disk
+-- Tests/
    +-- BentosVmmMacosTests/
```

## Dependencies

- **SwiftNIO** (2.65+) — HTTP server, Unix socket, WebSocket, event loops
- **Virtualization.framework** — system framework (`import Virtualization`)
- **Foundation** — JSON coding, file management
- macOS 14+ (for `VZVirtioBalloonDeviceConfiguration` and latest VZ.fw APIs)

## Build and Run

```bash
cd lib/bentos_vmm_macos
swift build

# Sign with virtualization entitlement
codesign --entitlements entitlements.plist --force \
    --sign "Apple Development: <your-identity>" \
    .build/debug/bentos-vmm-macos

# Place kernel + rootfs alongside binary
cp <path-to>/bentos-arm64-Image .build/debug/
cp <path-to>/bentos-arm64-rootfs.img .build/debug/

# Run
.build/debug/bentos-vmm-macos
# Listening on /tmp/bentos-vmm.sock
```

## Test with CLI

```bash
# Health check
bentos-vmm ping

# Create a machine
bentos-vmm create --name dev --cpus 2 --memory 2G

# Boot
bentos-vmm start dev

# Check state
bentos-vmm list
bentos-vmm get dev

# Attach console
bentos-vmm console dev

# Exec a command in the guest
bentos-vmm exec dev -- uname -a

# Interactive shell
bentos-vmm shell dev

# Stop
bentos-vmm stop dev

# Clean up
bentos-vmm delete dev
```

Or with curl directly:

```bash
curl --unix-socket /tmp/bentos-vmm.sock http://localhost/api/v1/vmm/ping
curl --unix-socket /tmp/bentos-vmm.sock -X POST http://localhost/api/v1/machines \
  -H "Content-Type: application/json" \
  -d '{"name":"dev","cpu_count":2,"memory_bytes":2147483648,
       "boot":{"kernel":"bundled://bentos-arm64-Image"},
       "disks":[{"role":"root","size_bytes":1073741824}],
       "network":{"mode":"nat"}}'
```

## Key References

| Document | What it covers |
|----------|---------------|
| `lib/bentos_vmm/lib/src/types.dart` | Canonical data model — every `toJson()`/`fromJson()` = the wire format |
| `lib/bentos_vmm/lib/src/http_vmm_client.dart` | Endpoint paths, HTTP methods, response parsing |
| `university/cs/apple-virtualization/lessons/10-vmm-macos-architecture.md` | Architecture, VZ.fw mapping, internal design |
| `university/cs/apple-virtualization/lessons/11-swift-implementation-guide.md` | SwiftPM, SwiftNIO, ConfigTranslator, concurrency, wire format matching |
| `university/cs/apple-virtualization/lessons/12-the-boot-pipeline.md` | Kernel bundling, rootfs creation, boot sequence, dev workflow |
| `university/cs/apple-virtualization/lessons/A1-bentos-vmm-interface.md` | Design philosophy, capability matrix, interface rationale |
| `university/cs/apple-virtualization/lessons/13-vm-exec.md` | VM exec architecture — vsock + guest agent, TLV protocol, data paths |
| `hq/console-virtualization-intel.md` | System-level VMM architecture, cross-platform strategy |
