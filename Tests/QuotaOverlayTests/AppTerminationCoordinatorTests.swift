import AppKit
import Testing
@testable import QuotaOverlayApp

@MainActor
struct AppTerminationCoordinatorTests {
    @Test("termination waits for cleanup and replies once")
    func waitsForCleanup() async {
        var cleanupCount = 0
        var replies: [Bool] = []
        let gate = AsyncGate()
        let coordinator = AppTerminationCoordinator(cleanup: {
            cleanupCount += 1
            await gate.wait()
        }, reply: { replies.append($0) })

        #expect(coordinator.requestTermination() == .terminateLater)
        #expect(coordinator.requestTermination() == .terminateLater)
        #expect(cleanupCount == 0)
        #expect(replies.isEmpty)
        await gate.signal()
        await coordinator.waitForCleanupForTesting()
        #expect(cleanupCount == 1)
        #expect(replies == [true])
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false
    func wait() async { if open { return }; await withCheckedContinuation { continuation = $0 } }
    func signal() { open = true; continuation?.resume(); continuation = nil }
}
