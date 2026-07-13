# Codex Pet Quota Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS companion that shows real Codex five-hour and weekly quota beside a Codex Pet.

**Architecture:** A SwiftUI app owns a non-activating transparent overlay window. A protocol-isolated App Server client reads `account/rateLimits/read` and listens for `account/rateLimits/updated`; a mapper converts snapshots into two display rows, while a store handles refresh, countdown, errors, and reconnection.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Package Manager, XCTest, Codex App Server JSON-RPC protocol.

---

## File map

- `Package.swift`: macOS executable and test targets.
- `Sources/QuotaOverlayApp/App.swift`: application entry point.
- `Sources/QuotaOverlayApp/AppServer/AppServerClient.swift`: process transport and JSON-RPC lifecycle.
- `Sources/QuotaOverlayApp/AppServer/ProtocolTypes.swift`: request, response, and notification types.
- `Sources/QuotaOverlayApp/Quota/RateLimitMapper.swift`: five-hour and weekly window mapping.
- `Sources/QuotaOverlayApp/Quota/QuotaStore.swift`: refresh, countdown, connection, and presentation state.
- `Sources/QuotaOverlayApp/Overlay/QuotaPanelView.swift`: compact two-row SwiftUI card.
- `Sources/QuotaOverlayApp/Overlay/OverlayWindowController.swift`: transparent non-activating window and screen-edge placement.
- `Sources/QuotaOverlayApp/Overlay/PetAnchorTracker.swift`: pet anchoring with draggable fallback.
- `Tests/QuotaOverlayTests/*`: mapper, countdown, store, protocol, and placement tests.

### Task 1: Create the Swift package shell

- [ ] Create `Package.swift` with a macOS 13 executable target and XCTest target.
- [ ] Create `App.swift` with an empty `WindowGroup` and application delegate hook.
- [ ] Run `swift test`; expect compilation and zero failures.
- [ ] Commit with `chore: scaffold macOS quota overlay`.

### Task 2: Define protocol types with tests

- [ ] Add decoding fixtures for primary and secondary `RateLimitWindow` values.
- [ ] Write failing tests that decode `RateLimitSnapshot`, `GetAccountRateLimitsResponse`, and update notifications.
- [ ] Implement `ProtocolTypes.swift` with explicit coding keys and optional forward-compatible fields.
- [ ] Run `swift test --filter ProtocolTypesTests`; expect all tests to pass.
- [ ] Commit with `feat: define Codex rate limit protocol types`.

### Task 3: Map real windows to display quotas

- [ ] Write failing tests proving mapping uses window duration or server identifier rather than array order.
- [ ] Test remaining calculation with 0%, 20%, 90%, 100%, and out-of-range usage.
- [ ] Implement `RateLimitMapper.map(snapshot:)` returning independent five-hour and weekly models.
- [ ] Run `swift test --filter RateLimitMapperTests`; expect all tests to pass.
- [ ] Commit with `feat: map Codex quota windows`.

### Task 4: Build the App Server client

- [ ] Add a fake line-delimited JSON-RPC transport for tests.
- [ ] Write failing tests for initialize, `account/rateLimits/read`, update notification, disconnect, and reconnect.
- [ ] Implement a transport actor that launches `codex app-server --listen stdio://`, writes JSON-RPC lines, and reads responses asynchronously.
- [ ] Reject non-local transports and redact sensitive fields from errors.
- [ ] Run `swift test --filter AppServerClientTests`; expect all tests to pass.
- [ ] Commit with `feat: read live Codex rate limits`.

### Task 5: Implement quota state and timing

- [ ] Write failing tests for startup refresh, 60-second polling, minute countdown, manual refresh, stale data, and three retry attempts.
- [ ] Implement `QuotaStore` on `@MainActor` with injectable clock and client protocols.
- [ ] Preserve last successful data during disconnect and expose unavailable state when no successful data exists.
- [ ] Run `swift test --filter QuotaStoreTests`; expect all tests to pass.
- [ ] Commit with `feat: manage quota refresh and recovery`.

### Task 6: Build the compact two-line panel

- [ ] Add snapshot-oriented view model tests for normal, warning, critical, stale, unavailable, and signed-out states.
- [ ] Implement the two lines `⏱ 5h <percent> · <countdown>` and `📅 周 <percent> · <countdown>`.
- [ ] Apply white, orange-under-20%, and red-under-10% status colors.
- [ ] Make clicking the panel call `refresh()` without activating another application.
- [ ] Run `swift test`; expect all tests to pass.
- [ ] Commit with `feat: add compact quota panel`.

### Task 7: Add overlay placement and pet anchoring

- [ ] Write geometry tests for right-side placement, automatic left-side flip, visible-screen clamping, and saved draggable fallback.
- [ ] Implement a transparent, titleless, non-activating `NSPanel` that does not steal keyboard focus.
- [ ] Implement best-effort pet anchoring and persist only the fallback panel position.
- [ ] Hide the panel when Codex is not running and restore it after Codex returns.
- [ ] Run `swift test`; expect all tests to pass.
- [ ] Commit with `feat: anchor quota overlay beside Codex Pet`.

### Task 8: Package and verify

- [ ] Add a release build script that creates `Codex Pet Quota.app` without embedding credentials.
- [ ] Add installation, launch-at-login, removal, and troubleshooting instructions to `README.md`.
- [ ] Verify a real signed-in account shows both windows and correct reset times.
- [ ] Verify signed-out, Codex-stopped, protocol-error, and network-loss states.
- [ ] Run `swift test` and `swift build -c release`; expect success.
- [ ] Commit with `docs: add installation and verification guide`.

## Acceptance gate

- Both real quota windows appear continuously beside the pet.
- Percentages and reset countdowns update without starting a Codex task.
- The panel never displays invented values.
- The app stores no password, token, cookie, or raw account payload.
- All unit and integration tests pass, and the release app launches on a clean macOS account with Codex installed.
