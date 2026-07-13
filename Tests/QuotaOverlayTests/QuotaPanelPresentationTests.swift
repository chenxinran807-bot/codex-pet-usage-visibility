import Foundation
import SwiftUI
import XCTest
@testable import QuotaOverlayApp

final class QuotaPanelPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testExactExampleRows() {
        let fiveHour = window(.fiveHour, 72, after: 2 * 3600 + 18 * 60)
        let weekly = window(.weekly, 41, after: 3 * 86_400 + 9 * 3600)

        XCTAssertEqual(QuotaPanelPresentation.make(window: fiveHour, status: .connected, now: now).text, "⏱ 5h 72% · 2h18m")
        XCTAssertEqual(QuotaPanelPresentation.make(window: weekly, status: .connected, now: now).text, "📅 周 41% · 3d9h")
    }

    func testCountdownBoundaries() {
        XCTAssertEqual(QuotaCountdown.format(resetAt: now.addingTimeInterval(59 * 60), now: now), "59m")
        XCTAssertEqual(QuotaCountdown.format(resetAt: now.addingTimeInterval(60 * 60), now: now), "1h0m")
        XCTAssertEqual(QuotaCountdown.format(resetAt: now.addingTimeInterval(23 * 3600 + 59 * 60), now: now), "23h59m")
        XCTAssertEqual(QuotaCountdown.format(resetAt: now.addingTimeInterval(24 * 3600), now: now), "1d0h")
        XCTAssertEqual(QuotaCountdown.format(resetAt: now, now: now), "正在更新")
        XCTAssertEqual(QuotaCountdown.format(resetAt: now.addingTimeInterval(-1), now: now), "正在更新")
        XCTAssertEqual(QuotaCountdown.format(resetAt: nil, now: now), "暂不可用")
    }

    func testSeverityThresholds() {
        XCTAssertEqual(row(20).severity, .normal)
        XCTAssertEqual(row(19).severity, .warning)
        XCTAssertEqual(row(10).severity, .warning)
        XCTAssertEqual(row(9).severity, .critical)
        XCTAssertEqual(row(0).severity, .critical)
    }

    func testStyleTokensMatchEveryVisualState() {
        XCTAssertEqual(QuotaRowStyleToken.make(for: .normal), .init(foreground: .white, opacity: 1))
        XCTAssertEqual(QuotaRowStyleToken.make(for: .warning), .init(foreground: .orange, opacity: 1))
        XCTAssertEqual(QuotaRowStyleToken.make(for: .critical), .init(foreground: .red, opacity: 1))
        XCTAssertEqual(QuotaRowStyleToken.make(for: .unavailable), .init(foreground: .secondary, opacity: 0.55))
        XCTAssertEqual(QuotaRowStyleToken.make(for: .stale), .init(foreground: .gray, opacity: 0.6))
    }

    func testPresentationTypesAreSendableAndEquatable() {
        assertSendableAndEquatable(QuotaRowPresentation.self)
        assertSendableAndEquatable(QuotaRowStyleToken.self)
        assertSendableAndEquatable(QuotaPanelModel.self)
        assertSendableAndEquatable(QuotaRowSeverity.self)
        assertSendableAndEquatable(QuotaCountdown.self)
        assertSendableAndEquatable(QuotaPanelPresentation.self)
    }

    func testUnavailableNeverInventsPercentage() {
        let result = QuotaPanelPresentation.make(kind: .fiveHour, window: nil, status: .unavailable, now: now)
        XCTAssertEqual(result.text, "⏱ 5h -- · 暂不可用")
        XCTAssertEqual(result.percentageText, "--")
        XCTAssertEqual(result.severity, .unavailable)
        XCTAssertEqual(result.accessibilityLabel, "五小时额度，暂不可用")
    }

    func testSignedOutUsesOneExactCompactMessage() {
        let model = QuotaPanelModel.make(fiveHour: nil, weekly: nil, status: .signedOut, now: now)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows.first?.text, "请先登录 Codex")
        XCTAssertEqual(model.accessibilityLabel, "请先登录 Codex")
    }

    func testStalePreservesValuesAndAddsOfflineSemantics() {
        let result = QuotaPanelPresentation.make(window: window(.weekly, 41, after: 3600), status: .stale, now: now)
        XCTAssertEqual(result.text, "📅 周 41% · 1h0m")
        XCTAssertEqual(result.severity, .stale)
        XCTAssertEqual(result.style.opacity, 0.6)
        XCTAssertEqual(result.accessibilityLabel, "每周额度，剩余 41%，重置时间1h0m，离线数据")
    }

    func testPanelAlwaysBuildsTwoRowsAndExactCombinedAccessibility() {
        let model = QuotaPanelModel.make(
            fiveHour: window(.fiveHour, 72, after: 2 * 3600 + 18 * 60),
            weekly: nil,
            status: .unavailable,
            now: now
        )

        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.rows.map(\.text), ["⏱ 5h 72% · 2h18m", "📅 周 -- · 暂不可用"])
        XCTAssertEqual(model.accessibilityLabel, "五小时额度，剩余 72%，重置时间2h18m；每周额度，暂不可用")
        XCTAssertEqual(model.accessibilityHint, "点击刷新额度")

        let normal = QuotaPanelModel.make(
            fiveHour: window(.fiveHour, 72, after: 2 * 3600 + 18 * 60),
            weekly: window(.weekly, 41, after: 3 * 86_400 + 9 * 3600),
            status: .connected,
            now: now
        )
        XCTAssertEqual(normal.accessibilityLabel, "五小时额度，剩余 72%，重置时间2h18m；每周额度，剩余 41%，重置时间3d9h")

        let stale = QuotaPanelModel.make(
            fiveHour: window(.fiveHour, 72, after: 3600),
            weekly: window(.weekly, 41, after: 3600),
            status: .stale,
            now: now
        )
        XCTAssertEqual(stale.accessibilityLabel, "五小时额度，剩余 72%，重置时间1h0m，离线数据；每周额度，剩余 41%，重置时间1h0m，离线数据")
    }

    func testExpiredResetAndAccessibilityContent() {
        let result = QuotaPanelPresentation.make(window: window(.fiveHour, 72, after: 0), status: .connected, now: now)
        XCTAssertEqual(result.countdownText, "正在更新")
        XCTAssertEqual(result.accessibilityLabel, "五小时额度，剩余 72%，重置时间正在更新")
    }

    @MainActor
    func testViewCoordinatorCoalescesRapidActivationAndTracksLifecycle() async {
        let gate = RefreshGate()
        let store = QuotaStore(clientFactory: { NeverClient() })
        let coordinator = QuotaPanelRefreshCoordinator { await gate.run() }
        let view = QuotaPanelView(store: store, refreshCoordinator: coordinator)
        assertStateObject(view.refreshCoordinatorStorage)

        coordinator.trigger()
        coordinator.trigger()
        await gate.waitUntilStarted()

        XCTAssertTrue(coordinator.isRunning)
        let startCount = await gate.startCount
        XCTAssertEqual(startCount, 1)

        await gate.finish()
        await eventually { !coordinator.isRunning }
        XCTAssertFalse(coordinator.isRunning)
    }

    @MainActor
    func testCoordinatorCancellationReleasesTaskAndAllowsLaterTrigger() async {
        let gate = RefreshGate()
        var coordinator: QuotaPanelRefreshCoordinator? = QuotaPanelRefreshCoordinator { await gate.run() }
        weak var weakCoordinator = coordinator

        coordinator?.trigger()
        await gate.waitUntilStarted()
        coordinator?.cancel()
        await eventually { !(coordinator?.isRunning ?? true) }

        coordinator?.trigger()
        await gate.waitForStartCount(2)
        XCTAssertTrue(coordinator?.isRunning ?? false)
        coordinator?.cancel()
        coordinator = nil
        await Task.yield()

        XCTAssertNil(weakCoordinator)
    }

    @MainActor
    func testCancellationWaitsForNoncooperativeActionBeforeRetriggering() async {
        let gate = NoncooperativeRefreshGate()
        let coordinator = QuotaPanelRefreshCoordinator { await gate.run() }

        coordinator.trigger()
        await gate.waitForStartCount(1)
        coordinator.cancel()
        coordinator.trigger()

        XCTAssertTrue(coordinator.isRunning)
        var starts = await gate.currentStartCount()
        var overlap = await gate.maximumOverlap()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(overlap, 1)

        await gate.releaseOne()
        await eventually { !coordinator.isRunning }
        coordinator.trigger()
        await gate.waitForStartCount(2)

        starts = await gate.currentStartCount()
        overlap = await gate.maximumOverlap()
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(overlap, 1)
        await gate.releaseOne()
    }


    private func assertSendableAndEquatable<T: Sendable & Equatable>(_: T.Type) {}
    private func assertStateObject<T: ObservableObject>(_: StateObject<T>) {}

    @MainActor
    private func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<50 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("condition did not become true")
    }

    private func row(_ percentage: Int) -> QuotaRowPresentation {
        QuotaPanelPresentation.make(window: window(.fiveHour, percentage, after: 3600), status: .connected, now: now)
    }

    private func window(_ kind: QuotaKind, _ percentage: Int, after interval: TimeInterval) -> QuotaWindow {
        QuotaWindow(kind: kind, remainingPercent: percentage, resetAt: now.addingTimeInterval(interval), sourceDurationMins: nil)
    }
}

private actor NoncooperativeRefreshGate {
    private var starts = 0
    private var active = 0
    private var maxActive = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func run() async {
        starts += 1
        active += 1
        maxActive = max(maxActive, active)
        await withCheckedContinuation { continuations.append($0) }
        active -= 1
    }

    func waitForStartCount(_ count: Int) async {
        while starts < count { await Task.yield() }
    }
    func currentStartCount() -> Int { starts }
    func maximumOverlap() -> Int { maxActive }
    func releaseOne() { continuations.removeFirst().resume() }
}

private actor RefreshGate {
    private(set) var startCount = 0
    private var finishContinuations: [CheckedContinuation<Void, Never>] = []

    func run() async {
        startCount += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { finishContinuations.append($0) }
        } onCancel: {
            Task { await self.finish() }
        }
    }

    func waitUntilStarted() async { await waitForStartCount(1) }
    func waitForStartCount(_ count: Int) async {
        while startCount < count { await Task.yield() }
    }
    func finish() {
        let continuations = finishContinuations
        finishContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor NeverClient: AppServerClientProtocol {
    nonisolated var rateLimitUpdates: AsyncStream<AccountRateLimitsUpdatedNotification> { AsyncStream { $0.finish() } }
    func start() async throws {}
    func readAccount() async throws -> GetAccountResponse { .init(account: .init(), requiresOpenaiAuth: true) }
    func readRateLimits() async throws -> GetAccountRateLimitsResponse { throw CancellationError() }
    func stop() async {}
}
