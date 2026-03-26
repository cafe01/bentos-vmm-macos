# Session State — S309 shipped M4+M5 (all milestones complete)

## What Shipped This Session (S309)
- M4.1 (Console WebSocket): NIOWebSocketServerUpgrader in pipeline, ConsoleHandler bridges
  WebSocket frames <-> ConsoleIO FileHandle pair. One connection per machine (409 if occupied).
  Acquire/release tracked in ManagedMachine.consoleConnected.
- M4.2 (SSE Events): EventBus per machine (AsyncStream-based broadcast). SSEHandler writes
  long-lived text/event-stream response. State transitions emit via MachineManager.transition()
  helper. MachineDelegate also emits on guestDidStop/didStopWithError.
- M5.1 (Create Snapshot): pause+saveMachineStateTo+resume. Saves to snapshots/{snapId}/state.vzsave.
  Returns BentosSnapshot JSON. Optional name in request body.
- M5.2 (Restore Snapshot): machine must be stopped. Rebuilds VZ config, restoreMachineStateFrom.
  Transitions stopped -> starting -> paused.
- M5.3 (List Snapshots): enumerates snapshots/ dir, returns sorted by creation time.
- M5.4 (Delete Snapshot): removes snapshot directory, returns 204.
- 121 tests passing (was 91 at start of S309). +30 new tests.

## Cumulative State (S307-S309)
- M0 (skeleton): 5/5 subtasks
- M1 (CRUD): 4/4 subtasks
- M3 (boot): 9/9 subtasks
- M4 (console+events): 2/2 subtasks
- M5 (snapshots): 4/4 subtasks
- Total: 24/24 subtasks. ALL COMPLETE. No 501 stubs remain.

## Architecture
- Sources/BentosVmmMacos/ — main.swift, HttpServer.swift, HttpHandler.swift
- Sources/BentosVmmMacos/Server/ — Router.swift, ConsoleHandler.swift, SSEHandler.swift
- Sources/BentosVmmMacos/Model/ — Types.swift, Errors.swift
- Sources/BentosVmmMacos/Persistence/ — MachineStore.swift, DiskManager.swift
- Sources/BentosVmmMacos/VMM/ — ConfigTranslator.swift, MachineManager.swift,
  ManagedMachine.swift, StateMapper.swift, MachineDelegate.swift, EventBus.swift
- Tests/BentosVmmMacosTests/ — 15 test files, 121 tests

## Key Decisions
- M4: NIOWebSocketServerUpgrader at pipeline level, EventBus @MainActor, transition() helper
- M5: Snapshot save pauses VM, saves state file, resumes. Restore rebuilds VZ config from scratch.
  Snapshot metadata derived from filesystem (no separate metadata file). snapshotNotFound error added.
