import Foundation

struct GetAccountResponse: Codable, Equatable, Sendable {
    let account: AccountDetails?
    let requiresOpenaiAuth: Bool
}

/// Account fields are intentionally opaque: quota visibility only needs reliable presence.
struct AccountDetails: Codable, Equatable, Sendable {
    init() {}
}

struct GetAccountRateLimitsResponse: Codable, Equatable, Sendable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?

    enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitId
    }
}

struct AccountRateLimitsUpdatedNotification: Codable, Equatable, Sendable {
    let rateLimits: RateLimitSnapshot

    enum CodingKeys: String, CodingKey {
        case rateLimits
    }
}

struct RateLimitSnapshot: Codable, Equatable, Sendable {
    let credits: CreditsSnapshot?
    let limitId: String?
    let limitName: String?
    let planType: PlanType?
    let primary: RateLimitWindow?
    let rateLimitReachedType: RateLimitReachedType?
    let secondary: RateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case credits
        case limitId
        case limitName
        case planType
        case primary
        case rateLimitReachedType
        case secondary
    }
}

struct RateLimitWindow: Codable, Equatable, Sendable {
    let usedPercent: Int
    let resetsAt: Int64?
    let windowDurationMins: Int64?

    enum CodingKeys: String, CodingKey {
        case usedPercent
        case resetsAt
        case windowDurationMins
    }
}

struct CreditsSnapshot: Codable, Equatable, Sendable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits
        case unlimited
        case balance
    }
}

enum PlanType: Codable, Equatable, Sendable {
    case free
    case go
    case plus
    case pro
    case prolite
    case team
    case selfServeBusinessUsageBased
    case business
    case enterpriseCbpUsageBased
    case enterprise
    case edu
    case unknown
    case unrecognized(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = switch value {
        case "free": .free
        case "go": .go
        case "plus": .plus
        case "pro": .pro
        case "prolite": .prolite
        case "team": .team
        case "self_serve_business_usage_based": .selfServeBusinessUsageBased
        case "business": .business
        case "enterprise_cbp_usage_based": .enterpriseCbpUsageBased
        case "enterprise": .enterprise
        case "edu": .edu
        case "unknown": .unknown
        default: .unrecognized(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var rawValue: String {
        switch self {
        case .free: "free"
        case .go: "go"
        case .plus: "plus"
        case .pro: "pro"
        case .prolite: "prolite"
        case .team: "team"
        case .selfServeBusinessUsageBased: "self_serve_business_usage_based"
        case .business: "business"
        case .enterpriseCbpUsageBased: "enterprise_cbp_usage_based"
        case .enterprise: "enterprise"
        case .edu: "edu"
        case .unknown: "unknown"
        case .unrecognized(let value): value
        }
    }
}

enum RateLimitReachedType: Codable, Equatable, Sendable {
    case rateLimitReached
    case workspaceOwnerCreditsDepleted
    case workspaceMemberCreditsDepleted
    case workspaceOwnerUsageLimitReached
    case workspaceMemberUsageLimitReached
    case unrecognized(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = switch value {
        case "rate_limit_reached": .rateLimitReached
        case "workspace_owner_credits_depleted": .workspaceOwnerCreditsDepleted
        case "workspace_member_credits_depleted": .workspaceMemberCreditsDepleted
        case "workspace_owner_usage_limit_reached": .workspaceOwnerUsageLimitReached
        case "workspace_member_usage_limit_reached": .workspaceMemberUsageLimitReached
        default: .unrecognized(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var rawValue: String {
        switch self {
        case .rateLimitReached: "rate_limit_reached"
        case .workspaceOwnerCreditsDepleted: "workspace_owner_credits_depleted"
        case .workspaceMemberCreditsDepleted: "workspace_member_credits_depleted"
        case .workspaceOwnerUsageLimitReached: "workspace_owner_usage_limit_reached"
        case .workspaceMemberUsageLimitReached: "workspace_member_usage_limit_reached"
        case .unrecognized(let value): value
        }
    }
}
