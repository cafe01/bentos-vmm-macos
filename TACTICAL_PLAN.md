# bentos-vmm-macos: Tactical Plan

> Implementor: John (SWE)
> Owner: Cafe (CTO) + Alfred (CPO/COO)
> Status: ALL MILESTONES COMPLETE + E2E VALIDATED — M0+M1+M3+M4+M5 (121 tests, S308-S309). 24/24 subtasks. First VM boot achieved S309.

One deliverable: the bentos-vmm-macos Swift daemon — an HTTP API over Unix socket wrapping Apple's Virtualization.framework. Goal: `POST /api/v1/machines` + `POST .../start` boots a real Linux VM on Apple Silicon.

---

## Operating Model

John executes this plan as a hydra — two heads working in parallel on independent tracks. The plan is structured for divide-and-conquer: each milestone is a clean unit of work assignable to a single head, with explicit fork points and convergence gates.

### Head Assignment

```
HEAD A (john-vmm-swift-NN):  M0 ── M1 ── M3 ── M4 ── M5    (Swift daemon)
HEAD B (john-distro-NN):     M2                                (Machine image — see lib/bentos_distro/)
```

- **Head A is the main line.** M0 (skeleton) is John's first mission on this plan — straightforward SwiftPM + NIO setup, ships something real. M0 -> M1 -> M3 is sequential (each builds on the last).
- Head B is fully independent. Start immediately. Produces kernel + rootfs artifacts that M3 needs.
- **Convergence gate**: M3.3 (first boot) requires Head B's artifacts (kernel + rootfs) AND Head A's M0-M1.
- M4 and M5 are sequential after M3 on Head A (or can be split to a new head).

### TDD Discipline

Every subtask follows red-green-refactor. The Swift test suite is the primary feedback loop — not external tools. As long as test coverage is sufficient to keep advancing submilestones, John pushes forward. External validation (curl against the socket) is a final capstone, not a gating concern.

| Milestone | Test type | What to test |
|-----------|-----------|-------------|
| M0 | Swift unit + integration | HTTP response codes, JSON shape, route dispatch, error envelope |
| M1 | Swift unit | MachineStore (persist/load/delete), MachineManager CRUD, JSON round-trip |
| M3 | Swift unit + integration | ConfigTranslator (JSON -> VZ config assertions), StateMapper, start/stop lifecycle |
| M4 | Swift integration | WebSocket frame bridging, SSE event format |
| M5 | Swift integration | Snapshot save/restore lifecycle |

"Validation" sections at milestone end are **integration smoke tests** — the capstone after all unit tests pass. They are NOT the primary feedback loop.

### Handoff Protocol

Each `.N` subtask boundary is a valid nap point. When handing off:
1. State what subtask completed (with test count).
2. State what's next (the next `.N`).
3. Note any deviation from plan or gotcha discovered.

The successor reads the nap checkpoint + runs `swift test` to verify green, then continues.

---

## Milestones

### M0: Skeleton (boots nothing, serves JSON)

SwiftPM project compiles and responds to HTTP on a Unix socket.

- [x] **M0.1** Package.swift + entitlements.plist + main.swift
  - SwiftPM executable target `bentos-vmm-macos`
  - Dependencies: `swift-nio` (2.65+), `swift-nio-extras`
  - System framework: `Virtualization` (linked, not used yet)
  - `entitlements.plist`: `com.apple.security.virtualization: true`
  - **Test**: project compiles (`swift build` succeeds)

- [x] **M0.2** SwiftNIO HTTP server binds to Unix socket
  - `HttpServer` class: takes socket path, starts NIO `ServerBootstrap`
  - Default socket: `/tmp/bentos-vmm.sock`
  - Serves `GET /api/v1/vmm/ping` -> `{"healthy":true,"machine_count":0,"uptime_seconds":0}`
  - **Tests**: server starts on socket; ping returns 200 + correct JSON; connection refused when server not running

- [x] **M0.3** Router dispatches all 18 endpoints
  - Pattern-matching router (method + path segments), NOT a framework
  - All 18 endpoints registered. Unimplemented ones return 501 `{"code":"not_implemented","message":"..."}`
  - **Tests**: each endpoint returns correct status (501 for stubs, 200 for ping); unknown path returns 404; wrong method returns 405

- [x] **M0.4** Model types: Swift structs matching Dart `types.dart`
  - Every type in `types.dart` has a Swift mirror with `Codable` conformance
  - **snake_case** JSON keys via `CodingKeys` (Swift properties are camelCase, wire format is snake_case)
  - Sealed types use `"type"` discriminator: `NetworkConfig`, `ResizeResult`, `MachineEvent`
  - **Tests**: JSON round-trip for every type. Encode Swift struct -> JSON string -> decode back -> assert equal. Test against the EXACT JSON examples from the Dart `toJson()` output.

- [x] **M0.5** Error envelope: all non-2xx return `{"code":"...","message":"..."}`
  - `VmmApiError` struct with HTTP status mapping
  - Router wraps all handlers: any thrown error becomes the envelope
  - **Tests**: invalid JSON body -> 400 + error envelope; unknown machine ID -> 404 + error envelope

**Milestone validation**: `curl --unix-socket /tmp/bentos-vmm.sock http://localhost/api/v1/vmm/ping` returns health JSON. All endpoints respond (501 for stubs). Bad requests get error envelopes.

### M1: Machine CRUD (no VZ.fw yet)

Create, list, get, delete machines with persisted config. No actual VMs — just state management.

- [x] **M1.1** MachineStore: filesystem persistence
  - Path: `~/Library/Application Support/com.bentos.vmm-macos/machines/{id}/`
  - Write `config.json` (exact `BentosVmConfig` JSON — Dart wire format)
  - Create directory tree: `config.json`, `snapshots/`, `logs/`
  - Load all persisted machines on startup
  - Delete removes entire machine directory
  - **Tests**: write + read round-trips JSON exactly; load on fresh init returns empty; create then load returns the machine; delete then load returns empty; concurrent creates get distinct IDs

- [x] **M1.2** MachineManager: `@MainActor` machine registry
  - `machines: [String: ManagedMachine]` dictionary
  - `ManagedMachine`: config + state + timestamps + optional VZ runtime (nil for now)
  - Methods: `create()`, `get()`, `list()`, `delete()`. All modify the dictionary + persist via MachineStore.
  - ID generation: UUID v4
  - **Tests**: create returns ManagedMachine in stopped state; get by ID works; list returns all; delete removes from dictionary; get after delete throws; create populates createdAt/updatedAt

- [x] **M1.3** Wire up HTTP handlers to MachineManager
  - `POST /api/v1/machines` — parse `BentosVmConfig` JSON, call `manager.create()`, return `BentosMachine` JSON (state: stopped)
  - `GET /api/v1/machines` — return `{"machines": [...]}`
  - `GET /api/v1/machines/{id}` — return `BentosMachine` JSON
  - `DELETE /api/v1/machines/{id}` — call `manager.delete()`, return 204
  - `GET /api/v1/vmm/capabilities` — return hardcoded macOS capabilities JSON
  - **Tests**: full HTTP round-trip via test client: POST create -> GET list (contains machine) -> GET by ID (matches) -> DELETE -> GET list (empty). Error cases: GET unknown ID -> 404; DELETE unknown -> 404; POST invalid JSON -> 400.

- [x] **M1.4** Restart persistence
  - On startup, MachineManager loads all machines from MachineStore
  - All loaded machines start in `stopped` state regardless of previous state
  - **Tests**: create machine via HTTP, restart server, list shows machine with state stopped

**Milestone validation**: Create a machine via curl, restart daemon, machine reappears in list. Capabilities endpoint returns hardcoded macOS capabilities.

### M2: Machine Image

> **This milestone lives in `lib/bentos_distro/`.** See `lib/bentos_distro/TACTICAL_PLAN.md` for the full plan.
>
> Head B executes this independently. What matters here: M2 produces two files that M3 needs.

**Outputs consumed by M3:**
- `bentos-arm64-Image` — ARM64 Linux kernel (VZ.fw bootable)
- `bentos-arm64-rootfs.img` — ext4 root filesystem (Alpine minimal, boots to login prompt)

**Option A (fastest unblock for M3):** Obtain a pre-built Alpine `linux-virt` ARM64 kernel + build minimal Alpine rootfs. No custom kernel config. Good enough to validate VZ.fw boot.

**Option B (real deal):** Full `bentos_distro` M0-M2 — custom kernel with BentOS defconfig + rootfs with kernel modules.

Either option unblocks M3. Head B should start with Option A to unblock fast, then proceed to Option B for the real artifacts.

**Validation**: `file bentos-arm64-Image` shows ARM64 executable. Rootfs mounts and contains `/sbin/init`.

### M3: Boot a VM (the milestone)

VZ.fw integration. From `POST .../start` to a running Linux guest.

- [x] **M3.1** ConfigTranslator: `BentosVmConfig` JSON -> `VZVirtualMachineConfiguration`
  - `cpu_count` -> `config.cpuCount`
  - `memory_bytes` -> `config.memorySize`
  - `boot.kernel` -> `VZLinuxBootLoader(kernelURL:)` with `bundled://` resolution
  - `boot.initramfs` -> `VZLinuxBootLoader.initialRamdiskURL` (optional)
  - `boot.command_line` -> `VZLinuxBootLoader.commandLine`
  - `disks[].size_bytes` -> `VZDiskImageStorageDeviceAttachment` + `VZVirtioBlockDeviceConfiguration`
  - `network.mode: nat` -> `VZNATNetworkDeviceAttachment` + `VZVirtioNetworkDeviceConfiguration`
  - `network.mode: bridged` -> `VZBridgedNetworkDeviceAttachment`
  - `enable_vsock` -> `VZVirtioSocketDeviceConfiguration`
  - `enable_entropy` -> `VZVirtioEntropyDeviceConfiguration`
  - `enable_balloon` -> `VZVirtioBalloonDeviceConfiguration` (macOS 14+)
  - `enable_rosetta` -> `VZLinuxRosettaDirectoryShare` + virtiofs tag `"rosetta"` (check availability first)
  - `shared_directories[]` -> `VZVirtioFileSystemDeviceConfiguration` + `VZSingleDirectoryShare`
  - **Console device**: `VZVirtioConsoleDeviceConfiguration` with `VZFileHandleSerialPortAttachment` — MUST be configured BEFORE VM creation. Create FileHandle pair here; bridge to WebSocket later in M4.
  - Call `config.validate()` before returning
  - **Tests**: build VZ config from known JSON input, assert cpuCount/memorySize/device counts match; assert validate() passes for valid configs; assert validate() throws for invalid configs (0 CPUs, too little memory); test `bundled://` path resolution; test each device flag (vsock, entropy, balloon) toggles the correct device presence

- [x] **M3.2** Disk image management
  - On machine creation: copy golden rootfs to `machines/{id}/root.img`
  - Use APFS clonefile for instant copy (`copyfile()` with `COPYFILE_CLONE`)
  - If `DiskConfig.sizeBytes` > golden image size: expand with `truncate` + note that `resize2fs` runs inside guest on first boot
  - **Tests**: cloned file exists and has correct size; expanded file is larger than original; clone of missing golden image returns clear error

- [x] **M3.3** MachineManager.startMachine
  - Build `VZVirtualMachineConfiguration` from persisted config JSON via ConfigTranslator
  - `VZVirtualMachine(configuration:)` — on `@MainActor`
  - Set `VZVirtualMachineDelegate` for state callbacks
  - `try await vm.start()`
  - Update state: stopped -> starting -> running (or -> error)
  - Store `VZVirtualMachine` reference in `ManagedMachine`
  - **Tests**: start transitions state to running; start on already-running machine returns error; start with missing disk image returns error; state change events emitted in correct order

- [x] **M3.4** MachineManager.stopMachine
  - `force: false` -> `vm.requestStop()` + 30s timeout, fallback to `vm.stop()`
  - `force: true` -> `vm.stop()` immediately
  - Update state: running -> stopping -> stopped
  - Nil out `VZVirtualMachine` reference
  - **Tests**: stop transitions state to stopped; force-stop skips graceful; stop on already-stopped machine returns error

- [x] **M3.5** MachineManager.pauseMachine / resumeMachine
  - `vm.pause()` / `vm.resume()`
  - running <-> paused
  - **Tests**: pause transitions running -> paused; resume transitions paused -> running; pause on stopped machine returns error

- [x] **M3.6** `POST .../power-button`
  - `vm.requestStop()` — ACPI signal only, no force, no timeout
  - **Test**: returns 200, does not force state change (guest may ignore)

- [x] **M3.7** `POST .../resize`
  - Always return `{"type":"restart_required","message":"Machine must be restarted for resize to take effect."}`
  - Save updated config to disk
  - VZ.fw cannot hotplug — this is correct behavior
  - **Tests**: resize returns restart_required; config on disk is updated; next start uses new config

- [x] **M3.8** StateMapper
  - `VZVirtualMachine.state` enum -> BentOS `MachineState` string
  - `.stopped` -> `"stopped"`, `.running` -> `"running"`, `.paused` -> `"paused"`, `.starting` -> `"starting"`, `.stopping` -> `"stopping"`, `.error` -> `"error"`
  - **Tests**: every VZ state maps to correct string; unknown state handled gracefully

- [x] **M3.9** MachineDelegate
  - `guestDidStop` -> state = stopped, nil out VM reference
  - `virtualMachine(_:didStopWithError:)` -> state = error, populate `MachineError`
  - **Tests**: delegate callback transitions state correctly; error populates MachineError with message

**Milestone validation**: `curl POST .../machines` + `curl POST .../start` -> kernel boots. `curl GET .../machines/{id}` returns `"state":"running"`. `curl POST .../stop` -> state returns to stopped. Full lifecycle via HTTP.

> **E2E validated S309**: Linux 6.12.77 (aarch64) boots to Alpine 3.21 login prompt via REST API. Two bugs fixed during validation:
> 1. `serialPorts` not `consoleDevices` — `VZVirtioConsoleDeviceSerialPortConfiguration` via `vzConfig.serialPorts` is the correct API for `hvc0` console.
> 2. `HttpHandler` removal on WS upgrade — NIO's upgrade mechanism doesn't remove custom handlers added after the codec, causing crash on console connect.
> Initramfs required: kernel has `virtio_blk`, `ext4`, `crc32c`, `libcrc32c` as modules (`=m`). Built minimal busybox initramfs as workaround. Follow-up: rebuild kernel with these as `=y` or add initramfs to distro build.

### M4: Console + Events (interactive access)

- [x] **M4.1** Console WebSocket (`GET .../machines/{id}/console`)
  - WebSocket upgrade via SwiftNIO `WebSocketUpgradeHandler`
  - Bridge WebSocket frames <-> VZ.fw virtio-console `FileHandle` pair
  - `VZFileHandleSerialPortAttachment` set at config time (M3.1) provides read/write FileHandles
  - Guest -> client: `readHandle.readabilityHandler` -> WebSocket binary frame
  - Client -> guest: WebSocket binary frame -> `writeHandle.write()`
  - Clean up readabilityHandler on WebSocket close
  - Multiple clients: only one console connection per machine at a time (return 409 if already connected)
  - **Tests**: WebSocket upgrade succeeds for running machine; fails for stopped machine (409); data written to WebSocket arrives at write handle; data from read handle arrives at WebSocket; disconnect cleans up handlers

- [x] **M4.2** SSE event stream (`GET .../machines/{id}/events`)
  - Long-lived HTTP response, `Content-Type: text/event-stream`
  - `AsyncStream<MachineEvent>` backed by delegate state changes
  - Each event: `data: {"type":"state_changed","previous_state":"stopped","new_state":"starting","timestamp":"..."}\n\n`
  - Include `ControlChannelEvent` when vsock connects/disconnects (stub for now)
  - Multiple SSE clients allowed (broadcast pattern)
  - **Tests**: SSE response has correct content-type; state transition emits correctly formatted event; multiple clients each receive the event; disconnected client doesn't block others

**Milestone validation**: `websocat ws+unix:///tmp/bentos-vmm.sock:/api/v1/machines/{id}/console` shows kernel boot messages or login prompt. `curl -N .../events` shows state transitions during start/stop.

### M5: Snapshots

- [x] **M5.1** Create snapshot
  - `POST .../snapshots` -> `vm.pause()`, `saveMachineStateTo(url)`, `vm.resume()`
  - Save to `machines/{id}/snapshots/{snapId}/state.vzsave`
  - Return `BentosSnapshot` JSON with size from file
  - **Tests**: snapshot creates directory + state file; snapshot of stopped machine returns error; snapshot JSON has correct fields

- [x] **M5.2** Restore snapshot
  - `POST .../snapshots/{sid}/restore` -> machine must be stopped
  - Rebuild VZ config, `VZVirtualMachine(configuration:)`, `restoreMachineStateFrom(url)`
  - **Tests**: restore from valid snapshot succeeds; restore on running machine returns error; restore from missing snapshot returns 404

- [x] **M5.3** List snapshots
  - `GET .../snapshots` -> enumerate snapshot directories, return `{"snapshots":[...]}`
  - **Tests**: empty list for new machine; list after create shows snapshot; list after delete shows empty

- [x] **M5.4** Delete snapshot
  - `DELETE .../snapshots/{sid}` -> remove snapshot directory
  - **Tests**: delete removes directory; delete unknown returns 404

**Milestone validation**: Create snapshot of running machine, stop, restore, verify machine resumes from saved state.

---

## Concurrency Model (Swift)

Three domains, two bridges. Non-negotiable — VZ.fw requires `@MainActor`.

```
SwiftNIO event loops (HTTP I/O)  <-->  @MainActor (VZ.fw)  <-->  Background (I/O forwarding)
```

- **NIO -> @MainActor**: `Task { @MainActor in ... }` for every VM operation
- **@MainActor -> NIO**: `eventLoop.execute { ... }` to send HTTP responses
- **@MainActor -> Background**: `Task.detached { ... }` for vsock reads, console forwarding

All `VZVirtualMachine` method calls happen on `@MainActor`. The async methods yield the main queue — multiple VMs can start/stop/pause concurrently.

---

## VZ.fw Gotchas

Things John will hit that the course mentions but are easy to miss:

1. **Console attachment is config-time, not runtime.** `VZFileHandleSerialPortAttachment` must be set on `VZVirtioConsoleDeviceConfiguration` BEFORE creating `VZVirtualMachine`. You can't attach a console to a running VM. Create the FileHandle pair at config translation time, bridge to WebSocket when a client connects.

2. **Entitlement crash.** Without `com.apple.security.virtualization` in the signed binary, VZ.fw calls crash with no useful error. Sign after every build. Add a build script or Makefile target: `swift build && codesign ...`.

3. **validate() catches config errors.** Always call `config.validate()` after building `VZVirtualMachineConfiguration`. It checks CPU count, memory size, device compatibility. Better to catch here than at `vm.start()`.

4. **VM state is in-memory.** If bentos-vmm-macos crashes, running VMs are lost. Persisted config survives (config.json on disk). Machines reappear as stopped on restart.

5. **MachineRuntime metrics.** VZ.fw does NOT expose CPU/memory usage. For v1, stub `cpu_usage_percent: 0.0` and `memory_used_bytes: config.memoryBytes`. Track `uptime_seconds` from start time. Track `control_channel_connected` from vsock state.

6. **requestStop() is best-effort.** It sends ACPI power button. If the guest ignores it (no ACPI daemon, hung kernel), it does nothing. Always implement the timeout + force-stop fallback.

7. **struct ManagedMachine value semantics.** Mutations require re-assignment: `machines[id] = machine`. The `VZVirtualMachine` inside is a reference type, so the VM instance is shared correctly. Consider making ManagedMachine a class if value-type mutation becomes friction.

8. **Rosetta availability check.** `VZLinuxRosettaDirectoryShare.availability` can be `.notSupported` or `.notInstalled`. Check before adding to config. If `.notInstalled`, VZ.fw can trigger installation — but don't do this silently. Return a clear error.

---

## File Persistence Layout

```
~/Library/Application Support/com.bentos.vmm-macos/
+-- machines/
    +-- {uuid}/
    |   +-- config.json            BentosVmConfig JSON (exact Dart wire format)
    |   +-- root.img               Root filesystem (clone of golden image)
    |   +-- snapshots/
    |   |   +-- {snap-uuid}/
    |   |       +-- state.vzsave   VZ.fw saved machine state
    |   +-- logs/
    |       +-- console.log        Captured kernel console output (optional)
    +-- {uuid}/
        +-- ...
```

Golden image location: alongside the daemon binary.
```
.build/debug/bentos-vmm-macos          The daemon
.build/debug/bentos-arm64-Image        ARM64 kernel
.build/debug/bentos-arm64-rootfs.img   Golden rootfs
```

---

## Implementation Order

```
HEAD A (Swift daemon — MAIN LINE):
M0 (skeleton)           SwiftPM + NIO + ping endpoint + types + routing
    |
M1 (CRUD)              Persistence + machine lifecycle (no VZ.fw)
    |
    |<--- GATE: needs M2 artifacts (kernel + rootfs) from Head B --->
    |
M3 (boot)              VZ.fw integration — the core work
    |
M4 (console+events)    WebSocket + SSE
    |
M5 (snapshots)         save/restore state

HEAD B (distro — see lib/bentos_distro/TACTICAL_PLAN.md):
M2 (image)             Kernel + rootfs. Fully independent. Start immediately.
```

**First demo** (M0 + M1 + M2 + M3): `curl POST .../machines` + `curl POST .../start` boots a real VM. Proof that VZ.fw works and the architecture holds.

**Full demo** (+ M4 + M5): Full lifecycle with interactive console and snapshots.

---

## The Contract (source of truth)

The canonical interface lives in Dart at `lib/bentos_vmm/lib/src/`. This daemon MUST match it exactly:

| File | What it defines | John must |
|------|----------------|-----------|
| `types.dart` | 14 data types with `toJson()`/`fromJson()` | Mirror every type in Swift. JSON must round-trip identically. |
| `vmm_client.dart` | 17 operations (abstract interface) | Implement every operation as an HTTP endpoint. |
| `http_vmm_client.dart` | Endpoint paths, HTTP methods, response parsing | Match paths, methods, status codes, response shapes exactly. |
| `events.dart` | SSE event types (sealed: state_changed, error, control_channel) | Emit events in the exact JSON format `MachineEvent.fromJson()` expects. |
| `errors.dart` | Error JSON: `{"code":"...","message":"..."}` + HTTP status | Return this envelope for every non-2xx response. |

**If this daemon and the Dart client disagree, the Dart client wins.**

---

## What's Explicitly Deferred

These are NOT in scope. They come later.

- Dart CLI (`bentos-vmm` command) — separate deliverable, see `lib/bentos_vmm/TACTICAL_PLAN.md`
- Console (Flutter) integration
- bentosd protocol over vsock (stub the control channel event)
- launchd service registration
- Multi-machine memory management (balloon tuning)
- App Store distribution / entitlement approval
- bentos-vmm-linux (Rust / Cloud Hypervisor)
- Any BentOS business logic
- Logging infrastructure (structured logs, log rotation)
- Metrics / observability beyond VmmHealth
- TLS on the Unix socket
