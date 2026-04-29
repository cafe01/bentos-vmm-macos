> **Note on codebase state.** The implementation predates BenStack vocabulary and has not yet been refactored to conform to the canonical VMM Layer spec. This README describes the codebase **as if it already conforms** to [`hq/workshop/bentos-vmm/bentos-vmm-product-spec.md`](bentos-vmm-product-spec.md), which is itself under active development — see [`hq/warroom/c04-benstack/q05-vmm-layer/`](../../hq/warroom/c04-benstack/q05-vmm-layer/) for live status. The refactor to bring the implementation in line with the README's described state is q05/m03's deliverable.

# bentos-vmm-macos

macOS implementation of `bentos-vmm-*`. Wraps Apple's [Virtualization.framework](https://developer.apple.com/documentation/virtualization). Conforms to the canonical `bentos-vmm` product and system specs.

## What it does

`bentos-vmm-macos` is a Swift daemon that runs on the host macOS machine and exposes the `bentos-vmm` REST API over a local Unix-domain socket. `benstackd` connects to it via `lib/bentos_vmm-rs` to manage the machine lifecycle on macOS.

## Architecture

```
benstackd  (via lib/bentos_vmm-rs)
    │
    │  Unix socket  (bentos-vmm REST API)
    ▼
bentos-vmm-macos  (this package)
    │
    ▼
Apple Virtualization.framework
```

## Key characteristics

- **Daemon, local socket.** Runs as a background process; accepts connections on a configurable Unix-domain socket path.
- **Declarative machine config.** Machines are created by applying a `MachineConfig` (Image reference, CPU, memory, Capabilities). All subsequent mutations follow the same apply-new-config shape.
- **Image-aware.** Maintains a local image cache. Machines reference images by id; pull-on-demand is supported at machine create time.
- **Console as primary IO.** Every machine exposes its serial console over WebSocket (`GET /api/v1/machines/{id}/console`). Exec (`GET /api/v1/machines/{id}/exec`) is available conditionally on `bentos-execd` running in the guest.
- **Built as a Swift package.** `Package.swift` at the root; no Xcode project required.

## Supported capabilities

| Feature | Supported |
|---|---|
| Hot CPU/memory resize | — |
| Rosetta 2 (x86 translation) | yes |
| Bridged networking | yes |
| Snapshots | yes |
| GPU passthrough | — |
