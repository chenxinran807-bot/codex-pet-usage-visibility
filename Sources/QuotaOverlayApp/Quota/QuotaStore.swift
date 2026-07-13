import Combine
import Foundation

enum QuotaConnectionStatus: Equatable, Sendable { case idle, connecting, connected, stale, unavailable, signedOut }

protocol QuotaSleeper: Sendable { func sleep(seconds: TimeInterval) async throws }
protocol QuotaTicker: Sendable {
    func pollTicks() -> AsyncStream<Void>
    func minuteTicks() -> AsyncStream<Date>
}

struct SystemQuotaSleeper: QuotaSleeper {
    func sleep(seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }
}
struct SystemQuotaTicker: QuotaTicker {
    func pollTicks() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { break }
                    guard !Task.isCancelled else { break }; continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func minuteTicks() -> AsyncStream<Date> { ticks(every: 60) }
    private func ticks(every seconds: TimeInterval) -> AsyncStream<Date> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { break }
                    guard !Task.isCancelled else { break }
                    continuation.yield(Date())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var fiveHour: QuotaWindow?
    @Published private(set) var weekly: QuotaWindow?
    @Published private(set) var connectionStatus: QuotaConnectionStatus = .idle
    @Published private(set) var lastSuccessfulUpdate: Date?
    @Published private(set) var now: Date
    @Published private(set) var isRefreshing = false

    private let clientFactory: @Sendable () async -> any AppServerClientProtocol
    private let clock: @Sendable () -> Date
    private let sleeper: any QuotaSleeper
    private let ticker: any QuotaTicker
    private var client: (any AppServerClientProtocol)?
    private var pollTask: Task<Void, Never>?, tickTask: Task<Void, Never>?, updateTask: Task<Void, Never>?, reconnectTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var readWaiters: Set<UUID> = []
    private var readGeneration: Int?
    private var stopped = false, started = false
    private var clientGeneration = 0
    private var refreshedResetDates: Set<Date> = []
    private var pendingResetDates: Set<Date> = []

    init(clientFactory: @escaping @Sendable () async -> any AppServerClientProtocol,
         clock: @escaping @Sendable () -> Date = Date.init,
         sleeper: any QuotaSleeper = SystemQuotaSleeper(), ticker: any QuotaTicker = SystemQuotaTicker()) {
        self.clientFactory = clientFactory; self.clock = clock; self.sleeper = sleeper; self.ticker = ticker; now = clock()
    }

    func start() async {
        guard !started else { return }; started = true; stopped = false
        connectionStatus = .connecting
        await connectWithRetry()
        guard !stopped, client != nil else { started = false; return }
        startBackgroundTasks()
        await refresh()
    }

    func refresh() async {
        guard !stopped, let client else { return }
        let waiter = UUID(); readWaiters.insert(waiter)
        let task: Task<Void, Never>; let operationGeneration: Int
        if let readTask { task = readTask; operationGeneration = readGeneration ?? clientGeneration }
        else {
            isRefreshing = true
            let generation = clientGeneration
            task = Task { @MainActor [weak self] in if let self { await self.performRead(client: client, generation: generation) } }
            readTask = task; readGeneration = generation; operationGeneration = generation
        }
        await withTaskCancellationHandler { await task.value } onCancel: {
            Task { @MainActor [weak self] in self?.cancelReadWaiter(waiter) }
        }
        finishReadWaiter(waiter, generation: operationGeneration)
    }

    func stop() async {
        guard !stopped else { return }; stopped = true
        clientGeneration += 1
        pollTask?.cancel(); tickTask?.cancel(); updateTask?.cancel(); reconnectTask?.cancel()
        let pendingRead = readTask; pendingRead?.cancel(); await pendingRead?.value
        pollTask = nil; tickTask = nil; updateTask = nil; reconnectTask = nil; readTask = nil; isRefreshing = false
        let old = client; client = nil
        await old?.stop(); started = false
    }

    private func connectWithRetry() async {
        for attempt in 0..<3 {
            guard !stopped, !Task.isCancelled else { return }
            let candidate = await clientFactory()
            do {
                try await candidate.start()
                guard !stopped, !Task.isCancelled else { await candidate.stop(); return }
                client = candidate; clientGeneration += 1; connectionStatus = .connected; return
            }
            catch is CancellationError { await candidate.stop(); return }
            catch { await candidate.stop(); if attempt < 2 { do { try await sleeper.sleep(seconds: TimeInterval(1 << attempt)) } catch { return } } }
        }
        if !stopped { connectionStatus = lastSuccessfulUpdate == nil ? .unavailable : .stale }
    }

    private func performRead(client: any AppServerClientProtocol, generation: Int) async {
        for attempt in 0..<3 {
            guard !stopped, !Task.isCancelled else { return }
            do {
                let account = try await client.readAccount()
                guard !stopped, !Task.isCancelled, generation == clientGeneration else { return }
                guard account.account != nil || !account.requiresOpenaiAuth else {
                    fiveHour = nil; weekly = nil; connectionStatus = .signedOut
                    return
                }
                let response = try await client.readRateLimits()
                guard !stopped, !Task.isCancelled, generation == clientGeneration else { return }
                apply(response.rateLimitsByLimitId?["codex"] ?? response.rateLimits)
                return
            } catch is CancellationError { return }
            catch { if attempt < 2 { do { try await sleeper.sleep(seconds: TimeInterval(1 << attempt)) } catch { return } } }
        }
        if !stopped { connectionStatus = lastSuccessfulUpdate == nil ? .unavailable : .stale }
    }

    private func apply(_ snapshot: RateLimitSnapshot) {
        guard !stopped else { return }; let mapped = RateLimitMapper.map(snapshot: snapshot)
        fiveHour = mapped.fiveHour; weekly = mapped.weekly; lastSuccessfulUpdate = clock(); now = clock(); connectionStatus = .connected
        let currentResets = Set([fiveHour?.resetAt, weekly?.resetAt].compactMap { $0 })
        refreshedResetDates.formIntersection(currentResets)
    }

    private func cancelReadWaiter(_ waiter: UUID) {
        guard readWaiters.remove(waiter) != nil else { return }
        if readWaiters.isEmpty { readTask?.cancel() }
    }
    private func finishReadWaiter(_ waiter: UUID, generation: Int) {
        readWaiters.remove(waiter)
        guard readWaiters.isEmpty, readGeneration == generation else { return }
        readTask = nil; readGeneration = nil
        if !stopped { isRefreshing = false }
    }

    private func startBackgroundTasks() {
        pollTask = Task { @MainActor [weak self, ticker] in for await _ in ticker.pollTicks() { guard let self, !Task.isCancelled, !self.stopped else { break }; await self.refresh() } }
        tickTask = Task { @MainActor [weak self, ticker] in
            for await date in ticker.minuteTicks() {
                guard let self, !Task.isCancelled, !self.stopped else { break }
                self.now = date
                let crossed = Set([self.fiveHour?.resetAt, self.weekly?.resetAt].compactMap { $0 })
                    .filter {
                        $0 <= date
                            && !self.refreshedResetDates.contains($0)
                            && !self.pendingResetDates.contains($0)
                    }
                guard !crossed.isEmpty else { continue }
                self.pendingResetDates.formUnion(crossed)
                await self.refresh()
                self.pendingResetDates.subtract(crossed)
                guard !self.stopped, !Task.isCancelled,
                      self.connectionStatus == .connected || self.connectionStatus == .signedOut
                else { continue }
                let currentResets = Set([self.fiveHour?.resetAt, self.weekly?.resetAt].compactMap { $0 })
                self.refreshedResetDates.formUnion(crossed.intersection(currentResets))
            }
        }
        listenForUpdates()
    }
    private func listenForUpdates() {
        guard let client else { return }
        updateTask = Task { @MainActor [weak self] in
            for await update in client.rateLimitUpdates { guard let self, !Task.isCancelled, !self.stopped else { return }; self.apply(update.rateLimits) }
            guard let self, !Task.isCancelled, !self.stopped else { return }; self.scheduleReconnect()
        }
    }
    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.clientGeneration += 1
            let oldRead = self.readTask; oldRead?.cancel(); await oldRead?.value
            guard !self.stopped, !Task.isCancelled else { return }
            self.readTask = nil; self.isRefreshing = false
            let old = self.client; self.client = nil; await old?.stop()
            self.connectionStatus = .connecting; await self.connectWithRetry()
            guard !self.stopped, self.client != nil else { self.reconnectTask = nil; return }
            self.listenForUpdates(); await self.refresh(); self.reconnectTask = nil
        }
    }
}
