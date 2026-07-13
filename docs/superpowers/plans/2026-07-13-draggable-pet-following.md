# Draggable Pet Following Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the quota panel reliably identify and follow the current Codex Pet while allowing the user to drag and persist a relative offset, with double-click reset.

**Architecture:** Keep pet discovery in `PetAnchorTracker`, pure geometry in `OverlayPlacement`, and interaction/state coordination in `OverlayWindowController`. Extend the panel abstraction with explicit user drag and reset callbacks so programmatic frame changes never masquerade as user input. Persist relative offsets separately from the existing absolute fallback origin.

**Tech Stack:** Swift 6, AppKit, SwiftUI, CoreGraphics, XCTest, Swift Testing, UserDefaults.

---

### Task 1: Recognize the Current Codex Pet Window

**Files:**
- Modify: `Sources/QuotaOverlayApp/Overlay/PetAnchorTracker.swift`
- Test: `Tests/QuotaOverlayTests/PetAnchorTrackerTests.swift`

- [ ] **Step 1: Add the failing real-window-shape test**

Add a test constructing the observed `34×37` ChatGPT/Codex accessory window and `356×320` pet window, then assert `PetAnchorSelection.select` returns the pet window.

```swift
func testSelectsCurrentLargePetInsteadOfTinyCodexAccessoryWindow() {
    let accessory = PetWindow(owner: "ChatGPT", bundleID: "com.openai.codex", title: "", frame: .init(x: 943, y: 0, width: 34, height: 37), layer: 25, onScreen: true, windowID: 1)
    let pet = PetWindow(owner: "ChatGPT", bundleID: "com.openai.codex", title: "", frame: .init(x: 1083, y: 36, width: 356, height: 320), layer: 3, onScreen: true, windowID: 2)
    XCTAssertEqual(PetAnchorSelection.select(from: [accessory, pet])?.windowID, pet.windowID)
}
```

- [ ] **Step 2: Run the test and confirm the current rules fail**

Run:

```bash
swift test --disable-sandbox --scratch-path /tmp/codex-pet-follow-red --filter PetAnchorTrackerTests/testSelectsCurrentLargePetInsteadOfTinyCodexAccessoryWindow
```

Expected: failure because the `356×320` pet exceeds the current maximum and the `34×37` accessory remains plausible.

- [ ] **Step 3: Update the trusted size range**

In `PetAnchorSelection.select`, change the plausible size bounds to require both dimensions at least `48` and at most `400`, retaining the existing visibility, layer, Codex ownership, self-bundle exclusion, deduplication, and ambiguity rules.

```swift
let plausible = windows.filter {
    $0.onScreen && $0.layer > 0 &&
    $0.frame.width >= 48 && $0.frame.height >= 48 &&
    $0.frame.width <= 400 && $0.frame.height <= 400 &&
    isCodex($0)
}
```

- [ ] **Step 4: Run all tracker tests**

```bash
swift test --disable-sandbox --scratch-path /tmp/codex-pet-follow-green --filter PetAnchorTrackerTests
```

Expected: all tracker tests pass.

- [ ] **Step 5: Commit the recognition fix**

```bash
git add Sources/QuotaOverlayApp/Overlay/PetAnchorTracker.swift Tests/QuotaOverlayTests/PetAnchorTrackerTests.swift
git commit -m "fix: recognize current Codex Pet window"
```

### Task 2: Persist Relative Placement and Apply It Safely

**Files:**
- Modify: `Sources/QuotaOverlayApp/Overlay/OverlayWindowController.swift`
- Test: `Tests/QuotaOverlayTests/OverlayPlacementTests.swift`
- Test: `Tests/QuotaOverlayTests/OverlayWindowControllerTests.swift`

- [ ] **Step 1: Add failing geometry and persistence tests**

Add pure geometry coverage that applies a saved offset to the default pet-relative frame and clamps the result to the visible screen.

```swift
func testRelativeOffsetIsAppliedThenClampedToVisibleScreen() {
    let pet = CGRect(x: 700, y: 400, width: 100, height: 100)
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let frame = OverlayPlacement.frame(pet: pet, panel: .init(width: 190, height: 62), screens: [screen], gap: 8, offset: .init(x: 300, y: 300))
    XCTAssertEqual(frame.maxX, screen.maxX)
    XCTAssertEqual(frame.maxY, screen.maxY)
}
```

Extend the fake persistence in controller tests with `loadRelativeOffset`, `saveRelativeOffset`, and `clearRelativeOffset`. Add tests proving a saved offset is restored after controller restart and double-click/reset clears it.

- [ ] **Step 2: Run the new tests and confirm missing APIs fail**

```bash
swift test --disable-sandbox --scratch-path /tmp/codex-pet-offset-red --filter 'OverlayPlacementTests|OverlayWindowControllerTests'
```

Expected: compile/test failures for the missing offset-aware frame API and persistence methods.

- [ ] **Step 3: Implement offset geometry**

Add an optional `offset: CGPoint = .zero` parameter to the anchored frame calculation. Compute the existing default frame first, translate its origin by the offset, then clamp both axes to the selected screen's visible frame.

```swift
let translated = CGRect(
    x: defaultFrame.minX + offset.x,
    y: defaultFrame.minY + offset.y,
    width: panel.width,
    height: panel.height
)
return clamp(translated, to: screen)
```

Use one private `clamp(_:to:)` helper for anchored and fallback placement so screen limiting remains consistent.

- [ ] **Step 4: Implement separate relative-offset persistence**

Extend `OverlayPositionPersistence` with:

```swift
func loadRelativeOffset() -> CGPoint?
func saveRelativeOffset(_ point: CGPoint)
func clearRelativeOffset()
```

Store the value under `QuotaOverlayPetRelativeOffset`. Keep `QuotaOverlayFallbackOrigin` unchanged for no-pet fallback behavior.

- [ ] **Step 5: Run geometry/controller tests**

```bash
swift test --disable-sandbox --scratch-path /tmp/codex-pet-offset-green --filter 'OverlayPlacementTests|OverlayWindowControllerTests'
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit placement persistence**

```bash
git add Sources/QuotaOverlayApp/Overlay/OverlayWindowController.swift Tests/QuotaOverlayTests/OverlayPlacementTests.swift Tests/QuotaOverlayTests/OverlayWindowControllerTests.swift
git commit -m "feat: persist pet-relative panel placement"
```

### Task 3: Make User Dragging Override Programmatic Following

**Files:**
- Modify: `Sources/QuotaOverlayApp/Overlay/OverlayWindowController.swift`
- Test: `Tests/QuotaOverlayTests/OverlayWindowControllerTests.swift`

- [ ] **Step 1: Add failing interaction tests**

Extend the fake panel so tests can emit `dragBegan`, `dragEnded`, and `resetRequested`. Cover these behaviors:

```swift
func testUserDragSavesOffsetAndPetMovementKeepsIt() async {
    // Start anchored, emit drag start, move fake panel, emit drag end.
    // Emit a new pet frame and assert the panel moves by the pet delta
    // while retaining the saved user offset.
}

func testTrackerUpdateDuringDragDoesNotMovePanel() async {
    // Emit drag start, then a new pet frame; assert no setFrame call until drag end.
}

func testResetRequestClearsOffsetAndReturnsToDefaultAnchor() async {
    // Begin with saved offset, emit reset request, assert persistence clears
    // and the panel immediately returns to OverlayPlacement's default frame.
}
```

- [ ] **Step 2: Run controller tests and confirm they fail**

```bash
swift test --disable-sandbox --scratch-path /tmp/codex-pet-drag-red --filter OverlayWindowControllerTests
```

Expected: failures because the panel protocol has no drag/reset callbacks and the controller has no drag state.

- [ ] **Step 3: Add explicit panel interaction callbacks**

Replace the move-only observer with an interaction installation API:

```swift
func installInteractionHandlers(
    dragBegan: @escaping @MainActor () -> Void,
    dragEnded: @escaping @MainActor () -> Void,
    resetRequested: @escaping @MainActor () -> Void
)
func removeInteractionHandlers()
```

Use AppKit window move/left-mouse notifications or a transparent content interaction view to report user drag start/end. Add a double-click recognizer on the panel content for reset. Programmatic `setFrame` must not emit user drag events.

- [ ] **Step 4: Coordinate dragging and following**

In `OverlayWindowController`:

- keep `currentPetFrame`, `currentScreens`, `relativeOffset`, and `isUserDragging`;
- ignore tracker-driven frame updates while `isUserDragging` is true, but retain the latest pet state;
- on drag end, compute `relativeOffset = panel.frame.origin - defaultAnchoredFrame.origin`, save it, then reapply the latest state;
- on reset, clear the offset and immediately apply the default anchored frame;
- in fallback mode, continue saving the absolute fallback origin.

- [ ] **Step 5: Run controller and full tests**

```bash
swift test --disable-sandbox --scratch-path /tmp/codex-pet-drag-green --filter OverlayWindowControllerTests
swift test --disable-sandbox --scratch-path /tmp/codex-pet-drag-full
```

Expected: controller tests pass; full suite has zero failures with only the opt-in live account test skipped.

- [ ] **Step 6: Commit drag coordination**

```bash
git add Sources/QuotaOverlayApp/Overlay/OverlayWindowController.swift Tests/QuotaOverlayTests/OverlayWindowControllerTests.swift
git commit -m "feat: drag quota panel relative to pet"
```

### Task 4: Validate, Publish, Install, and Observe

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document the interaction**

Add concise Chinese instructions: drag anywhere on the panel to adjust its pet-relative position; double-click to restore default; the relative position persists across restarts.

- [ ] **Step 2: Run release verification**

```bash
RUN_LIVE_CODEX_TESTS=1 swift test --disable-sandbox --scratch-path /tmp/codex-pet-drag-live --filter LiveAppServerTests
scripts/test-installation.sh
scripts/build-release.sh
plutil -lint 'dist/Codex Pet Quota.app/Contents/Info.plist'
lipo -archs 'dist/Codex Pet Quota.app/Contents/MacOS/QuotaOverlayApp'
git diff --check
```

Expected: live tests 2/2 pass, installation safety passes, release builds, plist is OK, binary reports `x86_64 arm64`, and diff check is clean.

- [ ] **Step 3: Commit documentation and push**

```bash
git add README.md docs/superpowers/specs/2026-07-13-draggable-pet-following-design.md docs/superpowers/plans/2026-07-13-draggable-pet-following.md
git commit -m "docs: explain draggable pet following"
git push
```

- [ ] **Step 4: Replace the installed application and relaunch**

Stop only the installed `QuotaOverlayApp` process, run `scripts/install.sh`, then open `~/Applications/Codex Pet Quota.app`. Verify the process is running and the panel window remains adjacent as the pet moves.
