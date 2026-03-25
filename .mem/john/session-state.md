# Session State — S307 Boardroom Onboarding + M0 Ship

## What Happened
- Onboarded by Alfred in boardroom. Thesis, architecture, roadmap, team, contract — all internalized.
- Shipped M0 (skeleton) — all 5 subtasks complete, 58 tests passing.
- M0.1: Package.swift + entitlements + main.swift (SwiftPM, swift-nio 2.65+, VZ.fw linked)
- M0.2: HttpServer on Unix socket, ping endpoint, graceful shutdown, test harness (curl-based)
- M0.3: Router dispatches all 18 endpoints (pure function, if-else dispatch — fixed illegal tuple pattern matching)
- M0.4: All 14 Dart types mirrored in Swift with Codable + snake_case CodingKeys
- M0.5: VmmApiError envelope, all non-2xx return {"code":"...","message":"..."}

## Pre-existing Code
Router.swift, Types.swift, Errors.swift existed before my session (from README scaffold).
Router had broken Swift syntax (`let` bindings in array patterns) — I rewrote to if-else.
A hook also rewrote HttpHandler.swift to integrate Router+Types+Errors properly.

## Key Decisions
- Test harness uses curl via Process (Foundation URLSession doesn't support Unix sockets)
- HttpServer.start() returns ServerHandle for programmatic shutdown in tests
- JSON encoding uses JSONEncoder.vmm / JSONDecoder.vmm with ISO 8601 dates + sorted keys

## File Layout
Sources/BentosVmmMacos/ — main.swift, HttpServer.swift, HttpHandler.swift
Sources/BentosVmmMacos/Server/ — Router.swift
Sources/BentosVmmMacos/Model/ — Types.swift, Errors.swift
Tests/BentosVmmMacosTests/ — 6 test files, 58 tests
