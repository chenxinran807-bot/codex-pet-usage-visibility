import Foundation
import SwiftUI

enum QuotaRowSeverity: Equatable, Sendable {
    case normal
    case warning
    case critical
    case stale
    case unavailable
}

enum QuotaForegroundToken: Equatable, Sendable {
    case white
    case orange
    case red
    case gray
    case secondary
}

struct QuotaRowStyleToken: Equatable, Sendable {
    let foreground: QuotaForegroundToken
    let opacity: Double

    static func make(for severity: QuotaRowSeverity) -> Self {
        switch severity {
        case .normal: Self(foreground: .white, opacity: 1)
        case .warning: Self(foreground: .orange, opacity: 1)
        case .critical: Self(foreground: .red, opacity: 1)
        case .stale: Self(foreground: .gray, opacity: 0.6)
        case .unavailable: Self(foreground: .secondary, opacity: 0.55)
        }
    }
}

struct QuotaRowPresentation: Equatable, Sendable {
    let kind: QuotaKind
    let percentageText: String
    let countdownText: String
    let severity: QuotaRowSeverity
    let accessibilityLabel: String
    let customText: String?

    var style: QuotaRowStyleToken { .make(for: severity) }

    var text: String {
        if let customText { return customText }
        return "\(kind.symbol) \(kind.shortLabel) \(percentageText) · \(countdownText)"
    }
}

struct QuotaPanelModel: Equatable, Sendable {
    let rows: [QuotaRowPresentation]
    let accessibilityLabel: String
    let accessibilityHint: String

    static func make(
        fiveHour: QuotaWindow?,
        weekly: QuotaWindow?,
        status: QuotaConnectionStatus,
        now: Date
    ) -> Self {
        if status == .signedOut {
            let row = QuotaRowPresentation(kind: .fiveHour, percentageText: "", countdownText: "", severity: .unavailable, accessibilityLabel: "请先登录 Codex", customText: "请先登录 Codex")
            return Self(rows: [row], accessibilityLabel: row.accessibilityLabel, accessibilityHint: "点击刷新额度")
        }
        let rows = [
            QuotaPanelPresentation.make(kind: .fiveHour, window: fiveHour, status: status, now: now),
            QuotaPanelPresentation.make(kind: .weekly, window: weekly, status: status, now: now)
        ]
        return Self(
            rows: rows,
            accessibilityLabel: rows.map(\.accessibilityLabel).joined(separator: "；"),
            accessibilityHint: "点击刷新额度"
        )
    }
}

struct QuotaCountdown: Equatable, Sendable {
    static func format(resetAt: Date?, now: Date) -> String {
        guard let resetAt else { return "暂不可用" }
        let seconds = Int(resetAt.timeIntervalSince(now))
        guard seconds > 0 else { return "正在更新" }
        let minutes = seconds / 60
        if seconds < 3_600 { return "\(minutes)m" }
        let hours = seconds / 3_600
        if seconds < 86_400 { return "\(hours)h\(minutes % 60)m" }
        return "\(hours / 24)d\(hours % 24)h"
    }
}

struct QuotaPanelPresentation: Equatable, Sendable {
    static func make(window: QuotaWindow, status: QuotaConnectionStatus, now: Date) -> QuotaRowPresentation {
        make(kind: window.kind, window: window, status: status, now: now)
    }

    static func make(kind: QuotaKind, window: QuotaWindow?, status: QuotaConnectionStatus, now: Date) -> QuotaRowPresentation {
        guard let window else {
            return QuotaRowPresentation(
                kind: kind,
                percentageText: "--",
                countdownText: "暂不可用",
                severity: .unavailable,
                accessibilityLabel: "\(kind.accessibilityName)额度，暂不可用",
                customText: nil
            )
        }

        let percentage = window.remainingPercent
        let countdown = QuotaCountdown.format(resetAt: window.resetAt, now: now)
        let isStale = status == .stale
        let severity: QuotaRowSeverity = isStale ? .stale : severity(for: percentage)
        let offlineSuffix = isStale ? "，离线数据" : ""
        return QuotaRowPresentation(
            kind: kind,
            percentageText: "\(percentage)%",
            countdownText: countdown,
            severity: severity,
            accessibilityLabel: "\(kind.accessibilityName)额度，剩余 \(percentage)%，重置时间\(countdown)\(offlineSuffix)",
            customText: nil
        )
    }

    private static func severity(for percentage: Int) -> QuotaRowSeverity {
        if percentage >= 20 { return .normal }
        if percentage >= 10 { return .warning }
        return .critical
    }
}

@MainActor
final class QuotaPanelRefreshCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    private let action: @MainActor () async -> Void
    private var task: Task<Void, Never>?
    private var operationID: UUID?

    init(_ action: @escaping @MainActor () async -> Void) {
        self.action = action
    }

    func trigger() {
        guard task == nil else { return }
        let id = UUID()
        operationID = id
        isRunning = true
        task = Task { @MainActor [weak self, action] in
            await action()
            self?.finish(id: id)
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func finish(id: UUID) {
        guard operationID == id else { return }
        task = nil
        operationID = nil
        isRunning = false
    }

    deinit {
        task?.cancel()
    }
}

@MainActor
struct QuotaPanelView: View {
    @ObservedObject private var store: QuotaStore
    @StateObject private var refreshCoordinator: QuotaPanelRefreshCoordinator

    init(store: QuotaStore, refreshCoordinator: QuotaPanelRefreshCoordinator? = nil) {
        self.store = store
        _refreshCoordinator = StateObject(
            wrappedValue: refreshCoordinator ?? QuotaPanelRefreshCoordinator { await store.refresh() }
        )
    }

    var refreshCoordinatorStorage: StateObject<QuotaPanelRefreshCoordinator> { _refreshCoordinator }

    var body: some View {
        let model = QuotaPanelModel.make(
            fiveHour: store.fiveHour,
            weekly: store.weekly,
            status: store.connectionStatus,
            now: store.now
        )

        Button {
            refreshCoordinator.trigger()
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                        Text(row.text)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(color(for: row.style.foreground))
                            .opacity(row.style.opacity)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)

                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.65)
                        .frame(width: 8, height: 8)
                        .padding(4)
                }
            }
            .fixedSize()
            .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(refreshCoordinator.isRunning || store.isRefreshing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityHint(model.accessibilityHint)
        .onDisappear { refreshCoordinator.cancel() }
    }

    private func color(for token: QuotaForegroundToken) -> Color {
        switch token {
        case .white: .white
        case .orange: .orange
        case .red: .red
        case .gray: .gray
        case .secondary: .secondary
        }
    }
}

private extension QuotaKind {
    var symbol: String { self == .fiveHour ? "⏱" : "📅" }
    var shortLabel: String { self == .fiveHour ? "5h" : "周" }
    var accessibilityName: String { self == .fiveHour ? "五小时" : "每周" }
}
