# Next Actions

## Immediate: M1.1 — MachineStore filesystem persistence
- Path: ~/Library/Application Support/com.bentos.vmm-macos/machines/{id}/
- Write config.json (exact BentosVmConfig JSON — Dart wire format)
- Create directory tree: config.json, snapshots/, logs/
- Load all persisted machines on startup
- Delete removes entire machine directory
- Tests: write+read round-trip, load on fresh init, create then load, delete then load, concurrent creates

## Then: M1.2 — MachineManager (@MainActor machine registry)
## Then: M1.3 — Wire up HTTP handlers to MachineManager
## Then: M1.4 — Restart persistence

## Contract reminder
Dart client at lib/bentos_vmm/lib/src/ is source of truth. If disagreement, Dart wins.
