import XCTest
@testable import QuotaOverlayApp

final class LiveAppServerTests: XCTestCase {
    func testTimeoutCancelsOperationAndAwaitsCleanupBeforeReturning() async {
        let state = LiveTimeoutTestState()
        do {
            _ = try await runWithDeadline(nanoseconds: 1_000_000) {
                while !(await state.cleanedUp) { await Task.yield() } // deliberately ignores cancellation
                await state.markOperationExited()
                return ()
            } onTimeout: {
                await state.markCleanedUp()
            }
            XCTFail("Expected timeout")
        } catch LiveTestError.timeout {}
        catch { XCTFail("Unexpected error type: \(type(of: error))") }

        let events = await state.events
        XCTAssertTrue(events.contains("cleaned-up"))
    }

    func testSignedInCodexRateLimitsDecodeWithoutInventingWindows() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_CODEX_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_CODEX_TESTS=1 to use the locally signed-in Codex account")
        }

        let client = AppServerClient()
        let response: GetAccountRateLimitsResponse
        do {
            response = try await runWithDeadline(nanoseconds: 15_000_000_000) {
                try await client.start()
                return try await client.readRateLimits()
            } onTimeout: {
                await client.stop()
            }
        } catch {
            await client.stop()
            throw error
        }
        let source = response.rateLimits
        let mapped = RateLimitMapper.map(snapshot: source)

        XCTAssertTrue(isTraceable(mapped.fiveHour, in: source))
        XCTAssertTrue(isTraceable(mapped.weekly, in: source))
        await client.stop()
    }

    private func isTraceable(_ mapped: QuotaWindow?, in source: RateLimitSnapshot) -> Bool {
        guard let mapped else { return true }
        let candidates = [source.primary, source.secondary].compactMap { $0 }
        return candidates.contains {
            $0.windowDurationMins == mapped.sourceDurationMins
                && 100 - min(100, max(0, $0.usedPercent)) == mapped.remainingPercent
        }
    }

}

private enum LiveTestError: Error {
    case timeout
}

private actor LiveTimeoutTestState {
    private(set) var events: [String] = []
    var cleanedUp: Bool { events.contains("cleaned-up") }
    func markOperationExited() { events.append("operation-exited") }
    func markCleanedUp() { events.append("cleaned-up") }
}

private actor DeadlineRace<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?
    private var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var finished = false
    private var timedOut = false

    func installContinuation(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func installOperation(_ operation: Task<Void, Never>) {
        self.operation = operation
    }

    func installTimeout(_ timeout: Task<Void, Never>) {
        if finished { timeout.cancel() } else { self.timeout = timeout }
    }

    func resolveOperation(_ result: Result<T, Error>) {
        guard !timedOut else { return }
        resolve(result)
    }

    func resolve(_ result: Result<T, Error>) {
        guard !finished else { return }
        finished = true
        operation?.cancel()
        timeout?.cancel()
        continuation?.resume(with: result)
        continuation = nil
        operation = nil
        timeout = nil
    }

    func beginTimeout() {
        timedOut = true
        operation?.cancel()
    }
}

private func runWithDeadline<T: Sendable>(
    nanoseconds: UInt64,
    operation: @escaping @Sendable () async throws -> T,
    onTimeout: @escaping @Sendable () async -> Void
) async throws -> T {
    let race = DeadlineRace<T>()
    return try await withCheckedThrowingContinuation { continuation in
        Task {
            await race.installContinuation(continuation)
            let operationTask = Task {
                do { await race.resolveOperation(.success(try await operation())) }
                catch { await race.resolveOperation(.failure(error)) }
            }
            await race.installOperation(operationTask)
            let timeoutTask = Task {
                do { try await Task.sleep(nanoseconds: nanoseconds) }
                catch { return }
                await race.beginTimeout()
                await onTimeout()
                await race.resolve(.failure(LiveTestError.timeout))
            }
            await race.installTimeout(timeoutTask)
        }
    }
}
