# Session State — S309 shipped M4 (Console + Events)

## What Shipped This Session (S309)
- M4.1 (Console WebSocket): NIOWebSocketServerUpgrader in pipeline, ConsoleHandler bridges
  WebSocket frames <-> ConsoleIO FileHandle pair. One connection per machine (409 if occupied).
  Acquire/release tracked in ManagedMachine.consoleConnected.
- M4.2 (SSE Events): EventBus per machine (AsyncStream-based broadcast). SSEHandler writes
  long-lived text/event-stream response. State transitions emit via MachineManager.transition()
  helper. MachineDelegate also emits on guestDidStop/didStopWithError.
- 105 tests passing (was 91). +14 new tests across EventBusTests, ConsoleTests, SSETests.

## Cumulative State (S307-S309)
- M0 (skeleton): 5/5 subtasks
- M1 (CRUD): 4/4 subtasks
- M3 (boot): 9/9 subtasks
- M4 (console+events): 2/2 subtasks
- Total: 20/24 subtasks. Only M5 (snapshots, 4 subtasks) remains.

## Architecture
- Sources/BentosVmmMacos/ — main.swift, HttpServer.swift, HttpHandler.swift
- Sources/BentosVmmMacos/Server/ — Router.swift, ConsoleHandler.swift, SSEHandler.swift
- Sources/BentosVmmMacos/Model/ — Types.swift, Errors.swift
- Sources/BentosVmmMacos/Persistence/ — MachineStore.swift, DiskManager.swift
- Sources/BentosVmmMacos/VMM/ — ConfigTranslator.swift, MachineManager.swift,
  ManagedMachine.swift, StateMapper.swift, MachineDelegate.swift, EventBus.swift
- Tests/BentosVmmMacosTests/ — 14 test files, 105 tests

## Key Decisions (M4)
- NIOWebSocketServerUpgrader integrated at pipeline level via configureHTTPServerPipeline(withServerUpgrade:)
- Console path check in shouldUpgrade callback (pure path matching)
- SSE uses NIOAny wrapping of HTTPServerResponsePart directly (no dedicated channel handler)
- EventBus is @MainActor, same isolation as MachineManager
- MachineManager.transition() helper centralizes state change + event emission

## What's Still 501 Stubs
- All snapshot endpoints (M5.1-M5.4)
