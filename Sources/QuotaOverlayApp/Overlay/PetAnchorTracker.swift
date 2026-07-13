import AppKit
import CoreGraphics

struct PetAnchorState: Equatable, Sendable {
    let codexRunning: Bool
    let petFrame: CGRect?
    let visibleScreenFrames: [CGRect]
}

protocol PetAnchorTracking: Sendable { func states() -> AsyncStream<PetAnchorState> }
protocol PetAnchorTicking: Sendable { func ticks() -> AsyncStream<Void> }
protocol PetWindowSourcing: Sendable { func snapshot() async -> PetWindowSnapshot }

struct PetWindowSnapshot: Sendable { let appRunning: Bool; let windows: [PetWindow]; let screens: [CGRect] }
struct PetWindow: Equatable, Sendable {
    let owner: String; let bundleID: String?; let title: String; let frame: CGRect; let layer: Int; let onScreen: Bool; let windowID: Int
}

enum PetAnchorSelection {
    private static let quotaOverlayBundleID = "com.chenxinran.codexpetquota"
    static func state(appRunning: Bool, windows: [PetWindow], screens: [CGRect]) -> PetAnchorState {
        .init(codexRunning: appRunning, petFrame: appRunning ? select(from: windows)?.frame : nil, visibleScreenFrames: screens)
    }
    // Pet windows are expected to be small, elevated, visible Codex-owned overlays.
    // Stable window id breaks ties and duplicate metadata deterministically.
    static func select(from windows: [PetWindow]) -> PetWindow? {
        let plausible = windows.filter { $0.onScreen && $0.layer > 0 && $0.frame.width >= 48 && $0.frame.height >= 48 && $0.frame.width <= 400 && $0.frame.height <= 400 && isCodex($0) }
        let unique = plausible.sorted { $0.windowID < $1.windowID }.reduce(into: [PetWindow]()) { result, candidate in
            if !result.contains(where: { $0.frame == candidate.frame }) { result.append(candidate) }
        }
        let explicit = unique.filter { $0.title.localizedCaseInsensitiveContains("pet") }
        if explicit.count == 1 { return explicit[0] }
        return unique.count == 1 ? unique[0] : nil
    }
    private static func isCodex(_ window: PetWindow) -> Bool {
        if window.bundleID == quotaOverlayBundleID { return false }
        return window.owner.localizedCaseInsensitiveContains("codex") || window.bundleID?.localizedCaseInsensitiveContains("codex") == true
    }
}

struct SystemPetAnchorTicker: PetAnchorTicking {
    func ticks() -> AsyncStream<Void> { AsyncStream { continuation in
        let task = Task { while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(500)); guard !Task.isCancelled else { break }; continuation.yield(()) }; continuation.finish() }
        continuation.onTermination = { _ in task.cancel() }
    } }
}

struct SystemPetWindowSource: PetWindowSourcing {
    func snapshot() async -> PetWindowSnapshot { await MainActor.run {
        let apps = NSWorkspace.shared.runningApplications
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let codex = apps.filter {
            $0.processIdentifier != currentPID &&
            ($0.bundleIdentifier?.localizedCaseInsensitiveContains("codex") == true || $0.localizedName?.localizedCaseInsensitiveContains("codex") == true)
        }
        let pids = Set(codex.map(\.processIdentifier))
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = info.compactMap { item -> PetWindow? in
            guard let pid = item[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let bounds = item[kCGWindowBounds as String] as? [String: Any], let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            let app = codex.first { $0.processIdentifier == pid }
            // Quartz uses a top-left Y axis; AppKit screen/window placement uses bottom-left.
            let appKitFrame = CGRect(x: frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY, width: frame.width, height: frame.height)
            return PetWindow(owner:item[kCGWindowOwnerName as String] as? String ?? "", bundleID:app?.bundleIdentifier, title:item[kCGWindowName as String] as? String ?? "", frame:appKitFrame, layer:item[kCGWindowLayer as String] as? Int ?? 0, onScreen:item[kCGWindowIsOnscreen as String] as? Bool ?? false, windowID:item[kCGWindowNumber as String] as? Int ?? 0)
        }
        return .init(appRunning: !codex.isEmpty, windows: windows, screens: NSScreen.screens.map(\.visibleFrame))
    } }
}

struct PetAnchorTracker: PetAnchorTracking {
    let source: any PetWindowSourcing; let ticker: any PetAnchorTicking
    init(source: any PetWindowSourcing = SystemPetWindowSource(), ticker: any PetAnchorTicking = SystemPetAnchorTicker()) { self.source=source; self.ticker=ticker }
    func states() -> AsyncStream<PetAnchorState> { AsyncStream { continuation in
        let task = Task { let first = await source.snapshot(); var previous = PetAnchorSelection.state(appRunning:first.appRunning, windows:first.windows, screens:first.screens); continuation.yield(previous)
            for await _ in ticker.ticks() { guard !Task.isCancelled else { break }; let s=await source.snapshot(); let next=PetAnchorSelection.state(appRunning:s.appRunning,windows:s.windows,screens:s.screens); if next != previous { continuation.yield(next); previous=next } }; continuation.finish() }
        continuation.onTermination = { _ in task.cancel() }
    } }
}
