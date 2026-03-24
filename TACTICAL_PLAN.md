# bentos-vmm-macos: Tactical Plan

> Implementor: John (SWE)
> Owner: Cafe (CTO)
> Status: Not started

Two deliverables: (1) bentos-vmm-macos Swift daemon, (2) bentos-vmm Dart CLI.
Goal: `bentos-vmm create --name dev && bentos-vmm start dev && bentos-vmm console dev` boots a real Linux VM on Apple Silicon.

---

## Milestones

### M0: Skeleton (boots nothing, serves JSON)

SwiftPM project compiles and responds to HTTP on a Unix socket.

- [ ] **M0.1** Package.swift + entitlements.plist + main.swift
- [ ] **M0.2** SwiftNIO HTTP server binds to Unix socket, serves `GET /api/v1/vmm/ping` -> `{"healthy":true,"machine_count":0,"uptime_seconds":0}`
- [ ] **M0.3** Router dispatches all 18 endpoints (stub 501 for unimplemented)
- [ ] **M0.4** Model types: Swift structs matching Dart `types.dart` wire format (snake_case JSON)
- [ ] **M0.5** Error envelope: all non-2xx return `{"code":"...","message":"..."}`

**Validation**: `curl --unix-socket /tmp/bentos-vmm.sock http://localhost/api/v1/vmm/ping` returns health JSON.

### M1: Machine CRUD (no VZ.fw yet)

Create, list, get, delete machines with persisted config. No actual VMs — just state management.

- [ ] **M1.1** MachineStore: persistence layer at `~/Library/Application Support/com.bentos.vmm-macos/machines/{id}/`
  - Write `config.json` (exact BentosVmConfig JSON from Dart client)
  - Create machine directory tree: `config.json`, `snapshots/`, `logs/`
  - Load all persisted machines on startup
- [ ] **M1.2** MachineManager skeleton: `machines: [String: ManagedMachine]` dictionary on `@MainActor`
- [ ] **M1.3** `POST /api/v1/machines` — parse BentosVmConfig JSON, assign UUID, persist, return BentosMachine (state: stopped)
- [ ] **M1.4** `GET /api/v1/machines` — return `{"machines": [...]}`
- [ ] **M1.5** `GET /api/v1/machines/{id}` — return BentosMachine
- [ ] **M1.6** `DELETE /api/v1/machines/{id}` — remove from dictionary, delete directory
- [ ] **M1.7** `GET /api/v1/vmm/capabilities` — return hardcoded macOS capabilities JSON

**Validation**: Create a machine via curl, restart daemon, machine reappears in list.

### M2: Machine Image

Acquire or build the kernel + rootfs that VZ.fw will boot. Two options — pick whichever unblocks fastest.

**Option A: Minimal dev image (fastest)**

- [ ] **M2.A1** Obtain a bootable ARM64 Linux kernel `Image` (Alpine `linux-virt` package or manual compile)
- [ ] **M2.A2** Build minimal Alpine rootfs: `apk --root ... add alpine-base openssh-server openrc`
- [ ] **M2.A3** Kernel command line: `console=hvc0 root=/dev/vda rw quiet`
- [ ] **M2.A4** Validate both files exist and are correct format

**Option B: BentOS distro image (real deal)**

- [ ] **M2.B1** Cross-compile ARM64 kernel from Alpine `linux-virt` source with BentOS defconfig:
  - `CONFIG_VIRTIO_BLK=y`, `CONFIG_VIRTIO_NET=y`, `CONFIG_VIRTIO_CONSOLE=y`, `CONFIG_VIRTIO_VSOCK=y`
  - `CONFIG_EXT4_FS=y`, `CONFIG_FUSE_FS=y`, `CONFIG_CUSE=m`, `CONFIG_VIRTIO_FS=m`
- [ ] **M2.B2** Build Alpine rootfs with full BentOS bill of materials (linux-distros L09):
  - Alpine base (musl, BusyBox, apk-tools, OpenRC)
  - System packages (bash, shadow, openssh, sudo, networking)
  - Kernel modules (cuse.ko, virtiofs.ko)
  - BentOS binaries (bentosd, bentos-agent — Dart AOT for ARM64)
  - containerd + runc
  - OpenRC service configs for bentosd, sshd
- [ ] **M2.B3** Package as golden rootfs image: `bentos-arm64-rootfs.img` (sparse ext4)

Either option produces two files: kernel `Image` + rootfs `root.img`. Bundle alongside the daemon binary.

**Validation**: Files exist. Kernel is ARM64 (`file Image` shows ARM64). Rootfs mounts and contains `/sbin/init`.

### M3: Boot a VM (the milestone)

VZ.fw integration. From `POST .../start` to a running Linux guest.

- [ ] **M3.1** ConfigTranslator: `BentosVmConfig` JSON -> `VZVirtualMachineConfiguration`
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
  - `enable_rosetta` -> `VZLinuxRosettaDirectoryShare` + virtiofs tag `"rosetta"`
  - `shared_directories[]` -> `VZVirtioFileSystemDeviceConfiguration` + `VZSingleDirectoryShare`
  - **Console device**: `VZVirtioConsoleDeviceConfiguration` with `VZFileHandleSerialPortAttachment` — must be configured BEFORE VM creation (not after)
  - Call `config.validate()` before returning
- [ ] **M3.2** Disk image management at machine creation:
  - Copy golden rootfs to `machines/{id}/root.img` (APFS clonefile = instant)
  - If `DiskConfig.sizeBytes` > golden image, expand with `truncate -s` + `resize2fs`
- [ ] **M3.3** MachineManager.startMachine:
  - Build `VZVirtualMachineConfiguration` from persisted config JSON
  - `VZVirtualMachine(configuration:)` — must happen on `@MainActor`
  - Set `VZVirtualMachineDelegate` for state callbacks
  - `try await vm.start()`
  - Update state: stopped -> starting -> running (or -> error)
  - Emit `StateChangedEvent` at each transition
- [ ] **M3.4** MachineManager.stopMachine:
  - `force: false` -> `vm.requestStop()` + 30s timeout, fallback to `vm.stop()`
  - `force: true` -> `vm.stop()` immediately
  - Update state: running -> stopping -> stopped
- [ ] **M3.5** MachineManager.pauseMachine / resumeMachine:
  - `vm.pause()` / `vm.resume()`
  - running <-> paused
- [ ] **M3.6** `POST .../power-button` -> `vm.requestStop()` (ACPI signal only, no force)
- [ ] **M3.7** `POST .../resize` -> always return `{"type":"restart_required","message":"Machine must be restarted for resize to take effect."}`. Save updated config, rebuild VZ config. VZ.fw cannot hotplug.
- [ ] **M3.8** StateMapper: translate `VZVirtualMachine.state` enum to BentOS `MachineState` string
  - `.stopped` -> `"stopped"`, `.running` -> `"running"`, `.paused` -> `"paused"`
  - `.starting` -> `"starting"`, `.stopping` -> `"stopping"`, `.error` -> `"error"`
- [ ] **M3.9** MachineDelegate (`VZVirtualMachineDelegate`):
  - `guestDidStop` -> state = stopped
  - `virtualMachine(_:didStopWithError:)` -> state = error, populate MachineError

**Validation**: `curl POST .../machines` + `curl POST .../start` -> kernel boots. `curl GET .../machines/{id}` returns `"state":"running"`. `curl POST .../stop` -> state returns to stopped.

### M4: Console + Events (interactive access)

- [ ] **M4.1** Console WebSocket (`GET .../machines/{id}/console`):
  - WebSocket upgrade via SwiftNIO pipeline
  - Bridge WebSocket frames <-> VZ.fw virtio-console `FileHandle` pair
  - `VZFileHandleSerialPortAttachment` set at config time (M3.1) provides read/write FileHandles
  - Guest -> client: `readHandle.readabilityHandler` -> WebSocket binary frame
  - Client -> guest: WebSocket binary frame -> `writeHandle.write()`
  - Clean up readabilityHandler on WebSocket close
- [ ] **M4.2** SSE event stream (`GET .../machines/{id}/events`):
  - Long-lived HTTP response, `Content-Type: text/event-stream`
  - MachineDelegate state changes -> `AsyncStream<MachineEvent>`
  - Each event: `data: {"type":"state_changed","previous_state":"stopped","new_state":"starting","timestamp":"..."}\n\n`
  - Include `ControlChannelEvent` when vsock connects/disconnects (stub for now)

**Validation**: `websocat ws+unix:///tmp/bentos-vmm.sock:/api/v1/machines/{id}/console` shows kernel boot messages or login prompt. `curl -N .../events` shows state transitions.

### M5: Snapshots

- [ ] **M5.1** `POST .../snapshots` -> `vm.pause()`, `saveMachineStateTo(url)`, `vm.resume()`. Save to `machines/{id}/snapshots/{snapId}/state.vzsave`. Return BentosSnapshot JSON.
- [ ] **M5.2** `POST .../snapshots/{sid}/restore` -> rebuild VZ config, `VZVirtualMachine(configuration:)`, `restoreMachineStateFrom(url)`, resume. Machine must be stopped.
- [ ] **M5.3** `GET .../snapshots` -> list snapshot directories, return `{"snapshots":[...]}`.
- [ ] **M5.4** `DELETE .../snapshots/{sid}` -> delete snapshot directory.

**Validation**: Create snapshot of running machine, stop, restore, verify machine resumes.

### M6: bentos-vmm Dart CLI

Command-line client wrapping `HttpVmmClient`. Lives at `lib/bentos_vmm/bin/bentos_vmm.dart` (or a separate `lib/bentos_vmm_cli/` package if preferred).

- [ ] **M6.1** Project setup: executable target, depends on `bentos_vmm` package. Argument parsing (package:args or similar).
- [ ] **M6.2** Connection: `--socket` flag (default `/tmp/bentos-vmm.sock`) -> `HttpVmmClient.unix(socket)`
- [ ] **M6.3** Commands:

| Command | Maps to | Notes |
|---------|---------|-------|
| `bentos-vmm ping` | `GET /api/v1/vmm/ping` | Print health status |
| `bentos-vmm capabilities` | `GET /api/v1/vmm/capabilities` | Print capability table |
| `bentos-vmm create --name NAME --cpus N --memory SIZE` | `POST /api/v1/machines` | SIZE accepts human units (2G, 512M). Print machine ID. |
| `bentos-vmm list` | `GET /api/v1/machines` | Table: ID, name, state, CPUs, memory |
| `bentos-vmm get ID\|NAME` | `GET /api/v1/machines/{id}` | Detailed machine info |
| `bentos-vmm delete ID\|NAME` | `DELETE /api/v1/machines/{id}` | Confirm before delete |
| `bentos-vmm start ID\|NAME` | `POST .../start` | Wait for running state |
| `bentos-vmm stop ID\|NAME [--force]` | `POST .../stop` | Graceful by default |
| `bentos-vmm pause ID\|NAME` | `POST .../pause` | |
| `bentos-vmm resume ID\|NAME` | `POST .../resume` | |
| `bentos-vmm console ID\|NAME` | `GET .../console` (WS) | Interactive terminal. Raw mode. Ctrl-] to detach. |
| `bentos-vmm events ID\|NAME` | `GET .../events` (SSE) | Stream events to stdout |
| `bentos-vmm snapshot ID\|NAME [--name LABEL]` | `POST .../snapshots` | |
| `bentos-vmm snapshots ID\|NAME` | `GET .../snapshots` | List snapshots |
| `bentos-vmm restore ID\|NAME SNAP_ID` | `POST .../restore` | |

- [ ] **M6.4** Name resolution: commands accept machine name or ID. `list` first, find by name, use ID. Cache for session.
- [ ] **M6.5** Console mode: put stdin in raw mode (`dart:io` stdin rawMode), pipe bytes bidirectionally, restore on Ctrl-] or disconnect.

**Validation**: Full lifecycle via CLI — create, start, console (see login prompt), stop, delete.

---

## Concurrency Model (Swift)

Three domains, two bridges. This is non-negotiable — VZ.fw requires `@MainActor`.

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

2. **Entitlement crash.** Without `com.apple.security.virtualization` in the signed binary, VZ.fw calls crash with no useful error. Sign after every build.

3. **validate() catches config errors.** Always call `config.validate()` after building `VZVirtualMachineConfiguration`. It checks CPU count, memory size, device compatibility. Better to catch here than at `vm.start()`.

4. **VM state is in-memory.** If bentos-vmm-macos crashes, running VMs are lost. Persisted config survives (config.json on disk). Machines reappear as stopped on restart.

5. **MachineRuntime metrics.** VZ.fw does NOT expose CPU/memory usage. For v1, stub `cpu_usage_percent: 0.0` and `memory_used_bytes: config.memoryBytes`. Track `uptime_seconds` from start time. Track `control_channel_connected` from vsock state.

6. **requestStop() is best-effort.** It sends ACPI power button. If the guest ignores it (no ACPI daemon, hung kernel), it does nothing. Always implement the timeout + force-stop fallback.

7. **struct ManagedMachine value semantics.** Mutations require re-assignment: `machines[id] = machine`. The `VZVirtualMachine` inside is a reference type, so the VM instance is shared correctly.

8. **Rosetta availability check.** `VZLinuxRosettaDirectoryShare.availability` can be `.notSupported` or `.notInstalled`. Check before adding to config. If `.notInstalled`, VZ.fw can trigger installation.

---

## File Persistence Layout

```
~/Library/Application Support/com.bentos.vmm-macos/
+-- machines/
    +-- {uuid}/
    |   +-- config.json            BentosVmConfig JSON (exact Dart wire format)
    |   +-- root.img               Root filesystem (copy of golden image)
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
M0 (skeleton)           ~1 day     SwiftPM + NIO + ping endpoint
    |
M1 (CRUD)              ~1 day     Persistence + machine lifecycle (no VZ.fw)
    |
M2 (image)             ~1-2 days  Kernel + rootfs acquisition/build
    |                              (can be parallelized with M0-M1)
M3 (boot)              ~2-3 days  VZ.fw integration — the core work
    |
M4 (console+events)    ~1-2 days  WebSocket + SSE
    |
M5 (snapshots)         ~1 day     save/restore state
    |
M6 (CLI)               ~1-2 days  Dart CLI wrapping HttpVmmClient
                                   (can be parallelized with M3-M5)
```

M2 and M6 are independent of the Swift milestones. Start M6 as soon as M0 is up (test CLI against stub endpoints). Start M2 whenever — it's needed by M3.

**First demo**: M0 + M1 + M2 + M3 = create a machine, boot it, see it running, stop it. All via curl. This is the proof that VZ.fw works and the architecture holds.

**Full demo**: + M4 + M5 + M6 = full lifecycle via `bentos-vmm` CLI with interactive console.

---

## What's Explicitly Deferred

These are NOT in scope for this plan. They come later.

- Console (Flutter) integration
- bentosd protocol over vsock (stub the control channel event)
- launchd service registration
- Multi-machine memory management (balloon tuning)
- App Store distribution / entitlement approval
- bentos-vmm-linux (Rust / Cloud Hypervisor)
- Any BentOS business logic
