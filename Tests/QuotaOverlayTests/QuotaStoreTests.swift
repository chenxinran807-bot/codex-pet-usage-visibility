import Foundation
import XCTest
@testable import QuotaOverlayApp

@MainActor
final class QuotaStoreTests: XCTestCase {
    func testSignedOutAccountDoesNotReadRateLimits() async {
        let client = StoreClient(account: .init(account: nil, requiresOpenaiAuth: true), reads: [.success(response(used: 10))])
        let store = QuotaStore(clientFactory: { client }, sleeper: NoSleep(), ticker: QuietTicker())
        await store.start()
        XCTAssertEqual(store.connectionStatus, .signedOut)
        XCTAssertNil(store.fiveHour)
        let readCount = await client.readCount
        XCTAssertEqual(readCount, 0)
        await store.stop()
    }

    func testAccountOptionalForNonOpenAIAuthMode() async {
        let client = StoreClient(account: .init(account: nil, requiresOpenaiAuth: false), reads: [.success(response(used: 10))])
        let store = QuotaStore(clientFactory: { client }, sleeper: NoSleep(), ticker: QuietTicker())
        await store.start()
        XCTAssertEqual(store.connectionStatus, .connected)
        XCTAssertEqual(store.fiveHour?.remainingPercent, 90)
        await store.stop()
    }

    func testResetCrossingRefreshesOnceAndNewResetCanRefreshAgain() async {
        let ticker = ManualTicker()
        let firstReset = Date(timeIntervalSince1970: 100)
        let secondReset = Date(timeIntervalSince1970: 200)
        let client = StoreClient(reads: [
            .success(response(used: 10, resetAt: firstReset)),
            .success(response(used: 20, resetAt: secondReset)),
            .success(response(used: 30, resetAt: Date(timeIntervalSince1970: 300)))
        ])
        let store = QuotaStore(clientFactory: { client }, clock: { Date(timeIntervalSince1970: 50) }, sleeper: NoSleep(), ticker: ticker)
        await store.start()
        await ticker.minute(firstReset)
        await eventually { await client.readCount == 2 }
        await ticker.minute(firstReset.addingTimeInterval(60))
        await Task.yield()
        let readCount = await client.readCount
        XCTAssertEqual(readCount, 2)
        await ticker.minute(secondReset)
        await eventually { await client.readCount == 3 }
        await store.stop()
    }

    func testFiveHourAndWeeklyCrossingTogetherCoalesceOneRefresh() async {
        let ticker = ManualTicker()
        let fiveHourReset = Date(timeIntervalSince1970: 90)
        let weeklyReset = Date(timeIntervalSince1970: 100)
        let client = StoreClient(reads: [
            .success(responseWithBothWindows(used: 10, fiveHourResetAt: fiveHourReset, weeklyResetAt: weeklyReset)),
            .success(responseWithBothWindows(used: 20, fiveHourResetAt: Date(timeIntervalSince1970: 190), weeklyResetAt: Date(timeIntervalSince1970: 200)))
        ])
        let store = QuotaStore(clientFactory: { client }, clock: { Date(timeIntervalSince1970: 50) }, sleeper: NoSleep(), ticker: ticker)
        await store.start()
        await ticker.minute(weeklyReset)
        await eventually { await client.readCount == 2 }
        await Task.yield()
        let reads = await client.readCount
        XCTAssertEqual(reads, 2)
        await store.stop()
    }

    func testResetCrossingJoinsManualRefreshAlreadyInFlight() async {
        let ticker = ManualTicker()
        let reset = Date(timeIntervalSince1970: 100)
        let client = StoreClient(
            reads: [.success(response(used: 10, resetAt: reset)), .success(response(used: 20, resetAt: Date(timeIntervalSince1970: 200)))],
            suspendSecondRead: true
        )
        let store = QuotaStore(clientFactory: { client }, clock: { Date(timeIntervalSince1970: 50) }, sleeper: NoSleep(), ticker: ticker)
        await store.start()
        let manual = Task { await store.refresh() }
        await eventually { await client.isReadSuspended }
        await ticker.minute(reset)
        await Task.yield()
        let reads = await client.readCount
        let overlap = await client.maximumConcurrentReads
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(overlap, 1)
        await client.resumeRead()
        await manual.value
        await eventually { !store.isRefreshing }
        await store.stop()
    }

    func testStopCancelsResetTriggeredRefreshAndPreventsMutation() async {
        let ticker = ManualTicker()
        let reset = Date(timeIntervalSince1970: 100)
        let client = StoreClient(
            reads: [.success(response(used: 10, resetAt: reset)), .success(response(used: 99, resetAt: Date(timeIntervalSince1970: 200)))],
            suspendSecondRead: true
        )
        let store = QuotaStore(clientFactory: { client }, clock: { Date(timeIntervalSince1970: 50) }, sleeper: NoSleep(), ticker: ticker)
        await store.start()
        await ticker.minute(reset)
        await eventually { await client.isReadSuspended }
        await store.stop()
        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(store.fiveHour?.remainingPercent, 90)
        let cancellations = await client.cancelledReadCount
        XCTAssertEqual(cancellations, 1)
    }

    func testFailedResetRefreshRetriesSameCurrentResetOnLaterMinuteTick() async {
        let ticker = ManualTicker()
        let reset = Date(timeIntervalSince1970: 100)
        let client = StoreClient(reads: [
            .success(response(used: 10, resetAt: reset)),
            .failure(TestError.failed), .failure(TestError.failed), .failure(TestError.failed),
            .success(response(used: 20, resetAt: Date(timeIntervalSince1970: 200)))
        ])
        let store = QuotaStore(clientFactory: { client }, clock: { Date(timeIntervalSince1970: 50) }, sleeper: NoSleep(), ticker: ticker)
        await store.start()
        await ticker.minute(reset)
        await eventually { await client.readCount == 4 }
        XCTAssertEqual(store.connectionStatus, .stale)

        await ticker.minute(reset.addingTimeInterval(60))
        await eventually { await client.readCount == 5 }
        XCTAssertEqual(store.connectionStatus, .connected)
        XCTAssertEqual(store.fiveHour?.remainingPercent, 80)
        await store.stop()
    }
    func testStartupPrefersCodexBucketAndRefreshes() async {
        let client = StoreClient(reads: [.success(response(used: 80, fallback: 10)), .success(response(used: 40))])
        let store = QuotaStore(clientFactory: { client }, clock: { Date(timeIntervalSince1970: 123) }, sleeper: NoSleep(), ticker: QuietTicker())
        await store.start()
        XCTAssertEqual(store.fiveHour?.remainingPercent, 20)
        XCTAssertEqual(store.connectionStatus, .connected)
        XCTAssertEqual(store.lastSuccessfulUpdate, Date(timeIntervalSince1970: 123))
        await store.refresh()
        XCTAssertEqual(store.fiveHour?.remainingPercent, 60)
        let reads = await client.readCount; XCTAssertEqual(reads, 2)
        await store.stop()
    }

    func testFallbackAndNotificationMapping() async {
        let client = StoreClient(reads: [.success(response(used: 25, includeCodex: false))])
        let store = QuotaStore(clientFactory: { client }, sleeper: NoSleep(), ticker: QuietTicker())
        await store.start()
        XCTAssertEqual(store.fiveHour?.remainingPercent, 75)
        await client.sendUpdate(snapshot(used: 60))
        await eventually { store.fiveHour?.remainingPercent == 40 }
        await store.stop()
    }

    func testPollingReadsAndMinuteTickOnlyChangesClock() async {
        let ticker = ManualTicker()
        let client = StoreClient(reads: [.success(response(used: 10)), .success(response(used: 20))])
        let store = QuotaStore(clientFactory: { client }, clock: { Date(timeIntervalSince1970: 7) }, sleeper: NoSleep(), ticker: ticker)
        await store.start()
        await ticker.minute(Date(timeIntervalSince1970: 99))
        await eventually { store.now == Date(timeIntervalSince1970: 99) }
        let reads = await client.readCount; XCTAssertEqual(reads, 1)
        await ticker.poll()
        await eventually { await client.readCount == 2 }
        await store.stop()
    }

    func testRetriesThenUnavailableAndUsesOneTwoSecondDelays() async {
        let sleeper = RecordingSleeper()
        let client = StoreClient(startResults: [.failure(TestError.failed), .failure(TestError.failed), .failure(TestError.failed)])
        let store = QuotaStore(clientFactory: { client }, sleeper: sleeper, ticker: QuietTicker())
        await store.start()
        XCTAssertEqual(store.connectionStatus, .unavailable)
        let starts = await client.startCount; let delays = await sleeper.delays
        XCTAssertEqual(starts, 3); XCTAssertEqual(delays, [1, 2])
    }

    func testFailurePreservesStaleDataAndStreamEndUsesFreshClient() async {
        let first = StoreClient(reads: [.success(response(used: 10)), .failure(TestError.failed), .failure(TestError.failed), .failure(TestError.failed)])
        let second = StoreClient(reads: [.success(response(used: 30))])
        let factory = ClientFactory([first, second])
        let store = QuotaStore(clientFactory: { await factory.make() }, sleeper: NoSleep(), ticker: QuietTicker())
        await store.start()
        await store.refresh()
        XCTAssertEqual(store.connectionStatus, .stale)
        XCTAssertEqual(store.fiveHour?.remainingPercent, 90)
        await first.finishUpdates()
        await eventually { store.fiveHour?.remainingPercent == 70 }
        let count = await factory.count; XCTAssertEqual(count, 2)
        await store.stop()
    }

    func testConcurrentRefreshesDoNotOverlapAndStopIsIdempotent() async {
        let client = StoreClient(reads: [.success(response(used: 10)), .success(response(used: 20))], suspendSecondRead: true)
        let store = QuotaStore(clientFactory: { client }, sleeper: NoSleep(), ticker: QuietTicker())
        await store.start()
        async let a: Void = store.refresh(); async let b: Void = store.refresh()
        await eventually { await client.isReadSuspended }
        let maxReads = await client.maximumConcurrentReads; XCTAssertEqual(maxReads, 1)
        await client.resumeRead()
        _ = await (a, b)
        await store.stop(); await store.stop()
        let stops = await client.stopCount; XCTAssertEqual(stops, 1)
        await client.sendUpdate(snapshot(used: 99))
        XCTAssertEqual(store.fiveHour?.remainingPercent, 80)
    }

    func testReconnectCancelsOldReadAndFreshClientDataWins() async {
        let first = StoreClient(reads: [.success(response(used: 10)), .success(response(used: 99))], suspendSecondRead: true)
        let second = StoreClient(reads: [.success(response(used: 30))])
        let factory = ClientFactory([first, second])
        let store = QuotaStore(clientFactory: { await factory.make() }, sleeper: NoSleep(), ticker: QuietTicker())
        await store.start()
        let oldRefresh = Task { await store.refresh() }
        await eventually { await first.readCount == 2 }
        await first.finishUpdates()
        await eventually { await second.readCount == 1 }
        XCTAssertEqual(store.fiveHour?.remainingPercent, 70)
        await first.resumeRead()
        await oldRefresh.value
        XCTAssertEqual(store.fiveHour?.remainingPercent, 70)
        await store.stop()
    }

    func testConnectionRetriesUseFreshClients() async {
        let clients = [StoreClient(startResults: [.failure(TestError.failed)]), StoreClient(startResults: [.failure(TestError.failed)]), StoreClient(startResults: [.failure(TestError.failed)])]
        let factory = ClientFactory(clients)
        let store = QuotaStore(clientFactory: { await factory.make() }, sleeper: NoSleep(), ticker: QuietTicker())
        await store.start()
        let count = await factory.count
        XCTAssertEqual(count, 3)
        for client in clients { let starts = await client.startCount; XCTAssertEqual(starts, 1) }
    }

    func testReadRetriesThreeTimesWithBackoffAndRefreshingState() async {
        let sleeper = RecordingSleeper()
        let client = StoreClient(reads: [.failure(TestError.failed), .failure(TestError.failed), .failure(TestError.failed)])
        let store = QuotaStore(clientFactory: { client }, sleeper: sleeper, ticker: QuietTicker())
        await store.start()
        let reads = await client.readCount; let delays = await sleeper.delays
        XCTAssertEqual(reads, 3); XCTAssertEqual(delays, [1, 2]); XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(store.connectionStatus, .unavailable)
    }

    func testStopDuringBlockedReadCancelsAndPreventsMutation() async {
        let client = StoreClient(reads: [.success(response(used: 10)), .success(response(used: 99))], suspendSecondRead: true)
        let store = QuotaStore(clientFactory: { client }, sleeper: NoSleep(), ticker: QuietTicker())
        await store.start()
        let refresh = Task { await store.refresh() }
        await eventually { await client.isReadSuspended }
        XCTAssertTrue(store.isRefreshing)
        await store.stop()
        XCTAssertFalse(store.isRefreshing)
        await client.resumeRead(); await refresh.value
        XCTAssertEqual(store.fiveHour?.remainingPercent, 90)
    }

    func testCancellationDuringConnectDoesNotClassifyFailure() async {
        let client = StoreClient(suspendStart: true)
        let store = QuotaStore(clientFactory: { client }, sleeper: NoSleep(), ticker: QuietTicker())
        let start = Task { await store.start() }
        await eventually { await client.startCount == 1 }
        start.cancel(); await start.value
        XCTAssertEqual(store.connectionStatus, .connecting)
        XCTAssertNil(store.lastSuccessfulUpdate)
        await store.stop()
    }

    func testCancellationDuringBackoffDoesNotClassifyFailure() async {
        let sleeper = BlockingSleeper()
        let client = StoreClient(startResults: [.failure(TestError.failed)])
        let store = QuotaStore(clientFactory: { client }, sleeper: sleeper, ticker: QuietTicker())
        let start = Task { await store.start() }
        await eventually { await sleeper.didBegin }
        start.cancel(); await start.value
        XCTAssertEqual(store.connectionStatus, .connecting)
        XCTAssertNil(store.lastSuccessfulUpdate)
        await store.stop()
    }

    func testCancelledRefreshRetiresNoncooperativeReadWithoutLateMutation() async {
        let client = StoreClient(reads: [.success(response(used: 10)), .success(response(used: 99))], suspendSecondRead: true, cooperativeReadCancellation: false)
        let store = QuotaStore(clientFactory: { client }, clock: { Date(timeIntervalSince1970: 5) }, sleeper: NoSleep(), ticker: QuietTicker())
        await store.start()
        let refresh = Task { await store.refresh() }
        await eventually { await client.isReadSuspended }
        refresh.cancel()
        await client.resumeRead(); await refresh.value
        XCTAssertEqual(store.fiveHour?.remainingPercent, 90)
        XCTAssertEqual(store.lastSuccessfulUpdate, Date(timeIntervalSince1970: 5))
        XCTAssertEqual(store.connectionStatus, .connected)
        XCTAssertFalse(store.isRefreshing)
        await store.stop()
    }

    func testCancelledCoalescedWaiterDoesNotCancelReadNeededByActiveWaiter() async {
        let client = StoreClient(reads: [.success(response(used: 10)), .success(response(used: 30))], suspendSecondRead: true)
        let store = QuotaStore(clientFactory: { client }, sleeper: NoSleep(), ticker: QuietTicker())
        await store.start()
        let owner = Task { await store.refresh() }
        await eventually { await client.isReadSuspended }
        let coalesced = Task { await store.refresh() }; await Task.yield(); coalesced.cancel()
        await client.resumeRead(); await owner.value; await coalesced.value
        XCTAssertEqual(store.fiveHour?.remainingPercent, 70)
        let cancellations = await client.cancelledReadCount; XCTAssertEqual(cancellations, 0)
        await store.stop()
    }

    func testCancelledStartStopsNoncooperativeClientWithoutConnectedMutation() async {
        let client = StoreClient(reads: [.success(response(used: 10))], suspendStart: true, cooperativeStartCancellation: false)
        let store = QuotaStore(clientFactory: { client }, sleeper: NoSleep(), ticker: QuietTicker())
        let start = Task { await store.start() }
        await eventually { await client.isStartSuspended }
        start.cancel(); await client.resumeStart(); await start.value
        XCTAssertEqual(store.connectionStatus, .connecting)
        XCTAssertNil(store.lastSuccessfulUpdate)
        let stops = await client.stopCount; XCTAssertEqual(stops, 1)
        await store.stop()
    }

    func testStopThenStartUsesFreshClientAndPreservesUntilFreshSuccess() async {
        let first = StoreClient(reads: [.success(response(used: 10))])
        let second = StoreClient(reads: [.success(response(used: 30))])
        let factory = ClientFactory([first, second])
        let store = QuotaStore(clientFactory: { await factory.make() }, sleeper: NoSleep(), ticker: QuietTicker())
        await store.start(); await store.stop()
        XCTAssertEqual(store.fiveHour?.remainingPercent, 90)
        await store.start()
        XCTAssertEqual(store.fiveHour?.remainingPercent, 70)
        let count = await factory.count; XCTAssertEqual(count, 2)
        await store.stop()
    }

    func testFailedStartCanBeRetried() async {
        let failed = StoreClient(startResults: [.failure(TestError.failed)])
        let good = StoreClient(reads: [.success(response(used: 20))])
        let factory = ClientFactory([failed, failed, failed, good])
        let store = QuotaStore(clientFactory: { await factory.make() }, sleeper: NoSleep(), ticker: QuietTicker())
        await store.start(); XCTAssertEqual(store.connectionStatus, .unavailable)
        await store.start(); XCTAssertEqual(store.fiveHour?.remainingPercent, 80)
        await store.stop()
    }

    func testStopTerminatesTickerStreamsOncePerLifecycle() async {
        let ticker = TerminationTicker()
        let clients = [StoreClient(reads: [.success(response(used: 10))]), StoreClient(reads: [.success(response(used: 20))])]
        let factory = ClientFactory(clients)
        let store = QuotaStore(clientFactory: { await factory.make() }, sleeper: NoSleep(), ticker: ticker)
        await store.start(); await store.stop()
        await eventually { await ticker.terminations == 2 }
        await store.start(); await store.stop()
        await eventually { await ticker.terminations == 4 }
    }
}

private enum TestError: Error { case failed }
private actor ClientFactory {
    var clients: [StoreClient]; var count = 0
    init(_ clients: [StoreClient]) { self.clients = clients }
    func make() -> any AppServerClientProtocol { defer { count += 1 }; return clients[min(count, clients.count - 1)] }
}
private actor StoreClient: AppServerClientProtocol {
    nonisolated let rateLimitUpdates: AsyncStream<AccountRateLimitsUpdatedNotification>
    private let continuation: AsyncStream<AccountRateLimitsUpdatedNotification>.Continuation
    var starts: [Result<Void, Error>]; var reads: [Result<GetAccountRateLimitsResponse, Error>]
    var startCount = 0, readCount = 0, stopCount = 0, concurrentReads = 0, maximumConcurrentReads = 0
    var suspended: CheckedContinuation<Void, Never>?; var startSuspended: CheckedContinuation<Void, Never>?
    var cancelledReadCount = 0
    let account: GetAccountResponse
    let suspendSecondRead: Bool; let suspendStart: Bool; let cooperativeReadCancellation: Bool; let cooperativeStartCancellation: Bool
    init(startResults: [Result<Void, Error>] = [.success(())], account: GetAccountResponse = .init(account: .init(), requiresOpenaiAuth: true), reads: [Result<GetAccountRateLimitsResponse, Error>] = [], suspendSecondRead: Bool = false, suspendStart: Bool = false, cooperativeReadCancellation: Bool = true, cooperativeStartCancellation: Bool = true) {
        var c: AsyncStream<AccountRateLimitsUpdatedNotification>.Continuation!
        rateLimitUpdates = AsyncStream { c = $0 }; continuation = c; starts = startResults; self.account = account; self.reads = reads; self.suspendSecondRead = suspendSecondRead; self.suspendStart = suspendStart; self.cooperativeReadCancellation = cooperativeReadCancellation; self.cooperativeStartCancellation = cooperativeStartCancellation
    }
    func readAccount() async throws -> GetAccountResponse { account }
    func start() async throws {
        let i = min(startCount, starts.count - 1); startCount += 1
        if suspendStart {
            if cooperativeStartCancellation { try await Task.sleep(for: .seconds(3600)) }
            else { await withCheckedContinuation { startSuspended = $0 } }
        }
        try starts[i].get()
    }
    func readRateLimits() async throws -> GetAccountRateLimitsResponse {
        concurrentReads += 1; maximumConcurrentReads = max(maximumConcurrentReads, concurrentReads); defer { concurrentReads -= 1 }
        let i = min(readCount, reads.count - 1); readCount += 1
        if suspendSecondRead && readCount == 2 {
            if cooperativeReadCancellation {
                await withTaskCancellationHandler { await withCheckedContinuation { suspended = $0 } } onCancel: { Task { await self.cancelRead() } }
                try Task.checkCancellation()
            } else { await withCheckedContinuation { suspended = $0 } }
        }
        return try reads[i].get()
    }
    func stop() async { stopCount += 1 }
    func sendUpdate(_ value: RateLimitSnapshot) { continuation.yield(.init(rateLimits: value)) }
    func finishUpdates() { continuation.finish() }
    func resumeRead() { suspended?.resume(); suspended = nil }
    func cancelRead() { cancelledReadCount += 1; resumeRead() }
    func resumeStart() { startSuspended?.resume(); startSuspended = nil }
    var isReadSuspended: Bool { suspended != nil }
    var isStartSuspended: Bool { startSuspended != nil }
}
private struct NoSleep: QuotaSleeper { func sleep(seconds: TimeInterval) async throws {} }
private actor RecordingSleeper: QuotaSleeper { var delays: [TimeInterval] = []; func sleep(seconds: TimeInterval) async throws { delays.append(seconds) } }
private actor BlockingSleeper: QuotaSleeper { var didBegin = false; func sleep(seconds: TimeInterval) async throws { didBegin = true; try await Task.sleep(for: .seconds(3600)) } }
private actor TerminationTicker: QuotaTicker {
    var terminations = 0
    nonisolated func pollTicks() -> AsyncStream<Void> { makeStream() }
    nonisolated func minuteTicks() -> AsyncStream<Date> { makeStream() }
    nonisolated private func makeStream<T: Sendable>() -> AsyncStream<T> {
        AsyncStream { continuation in continuation.onTermination = { _ in Task { await self.terminated() } } }
    }
    private func terminated() { terminations += 1 }
}
private struct QuietTicker: QuotaTicker {
    func pollTicks() -> AsyncStream<Void> { AsyncStream { _ in } }
    func minuteTicks() -> AsyncStream<Date> { AsyncStream { _ in } }
}
private actor ManualTicker: QuotaTicker {
    nonisolated let pollStream: AsyncStream<Void>, minuteStream: AsyncStream<Date>
    nonisolated let pollContinuation: AsyncStream<Void>.Continuation, minuteContinuation: AsyncStream<Date>.Continuation
    init() { var p: AsyncStream<Void>.Continuation!; var m: AsyncStream<Date>.Continuation!; pollStream = AsyncStream { p = $0 }; minuteStream = AsyncStream { m = $0 }; pollContinuation = p; minuteContinuation = m }
    nonisolated func pollTicks() -> AsyncStream<Void> { pollStream }; nonisolated func minuteTicks() -> AsyncStream<Date> { minuteStream }
    func poll() async { pollContinuation.yield(()) }; func minute(_ date: Date) async { minuteContinuation.yield(date) }
}
private func response(used: Int, fallback: Int? = nil, includeCodex: Bool = true, resetAt: Date? = nil) -> GetAccountRateLimitsResponse {
    let base = snapshot(used: fallback ?? used, resetAt: resetAt); return .init(rateLimits: base, rateLimitsByLimitId: includeCodex ? ["codex": snapshot(used: used, resetAt: resetAt)] : nil)
}
private func responseWithBothWindows(used: Int, fiveHourResetAt: Date, weeklyResetAt: Date) -> GetAccountRateLimitsResponse {
    let value = RateLimitSnapshot(
        credits: nil, limitId: nil, limitName: nil, planType: nil,
        primary: .init(usedPercent: used, resetsAt: Int64(fiveHourResetAt.timeIntervalSince1970), windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: .init(usedPercent: used, resetsAt: Int64(weeklyResetAt.timeIntervalSince1970), windowDurationMins: 10_080)
    )
    return .init(rateLimits: value, rateLimitsByLimitId: ["codex": value])
}
private func snapshot(used: Int, resetAt: Date? = nil) -> RateLimitSnapshot { .init(credits: nil, limitId: nil, limitName: nil, planType: nil, primary: .init(usedPercent: used, resetsAt: resetAt.map { Int64($0.timeIntervalSince1970) }, windowDurationMins: 300), rateLimitReachedType: nil, secondary: nil) }
@MainActor private func eventually(_ condition: @escaping @MainActor () async -> Bool) async { for _ in 0..<100 { if await condition() { return }; await Task.yield() }; XCTFail("condition not reached") }
