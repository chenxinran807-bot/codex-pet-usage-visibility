import AppKit
import SwiftUI

enum AppMetadata {
    static let name = "Quota Overlay"
}

@MainActor
final class AppTerminationCoordinator {
    typealias Cleanup = @MainActor () async -> Void
    typealias Reply = @MainActor (Bool) -> Void
    private let cleanup: Cleanup
    private let reply: Reply
    private var cleanupTask: Task<Void, Never>?

    init(cleanup: @escaping Cleanup, reply: @escaping Reply) {
        self.cleanup = cleanup
        self.reply = reply
    }

    func requestTermination() -> NSApplication.TerminateReply {
        guard cleanupTask == nil else { return .terminateLater }
        cleanupTask = Task { @MainActor [cleanup, reply] in
            await cleanup()
            reply(true)
        }
        return .terminateLater
    }

    func waitForCleanupForTesting() async { await cleanupTask?.value }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: QuotaStore?
    private var overlay: OverlayWindowController?
    private var terminationCoordinator: AppTerminationCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let store = QuotaStore(clientFactory: { AppServerClient() })
        let overlay = OverlayWindowController(store: store)
        self.store = store; self.overlay = overlay
        terminationCoordinator = AppTerminationCoordinator(cleanup: { [weak self] in
            self?.overlay?.stop()
            if let store = self?.store { await store.stop() }
        }, reply: { NSApp.reply(toApplicationShouldTerminate: $0) })
        overlay.start()
        Task { await store.start() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationCoordinator?.requestTermination() ?? .terminateNow
    }
}

@main
struct QuotaOverlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
