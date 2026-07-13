import Foundation
import Testing
@testable import QuotaOverlayApp

@Test("account/read decodes both signed-in and signed-out responses")
func accountReadResponses() throws {
    let signedIn = try JSONDecoder().decode(GetAccountResponse.self, from: Data(#"{"account":{"type":"chatgpt","email":"pet@example.com","planType":"plus"},"requiresOpenaiAuth":true}"#.utf8))
    #expect(signedIn.account != nil)
    #expect(signedIn.requiresOpenaiAuth)
    let signedOut = try JSONDecoder().decode(GetAccountResponse.self, from: Data(#"{"account":null,"requiresOpenaiAuth":true}"#.utf8))
    #expect(signedOut.account == nil)
}

struct ProtocolTypesTests {
    private let decoder = JSONDecoder()

    private func requireSendable<T: Sendable>(_: T.Type) {}

    @Test func protocolModelsAreSendable() {
        requireSendable(GetAccountRateLimitsResponse.self)
        requireSendable(AccountRateLimitsUpdatedNotification.self)
        requireSendable(RateLimitSnapshot.self)
        requireSendable(RateLimitWindow.self)
        requireSendable(CreditsSnapshot.self)
        requireSendable(PlanType.self)
        requireSendable(RateLimitReachedType.self)
    }

    @Test func decodesPrimaryAndSecondaryWindows() throws {
        let snapshot = try decoder.decode(RateLimitSnapshot.self, from: Data(#"""
        {
          "limitId": "codex",
          "limitName": "Codex usage",
          "planType": "plus",
          "primary": { "usedPercent": 42, "resetsAt": 1735689600, "windowDurationMins": 300 },
          "secondary": { "usedPercent": 7, "resetsAt": 1735776000, "windowDurationMins": 10080 },
          "rateLimitReachedType": "rate_limit_reached"
        }
        """#.utf8))

        #expect(snapshot.limitId == "codex")
        #expect(snapshot.limitName == "Codex usage")
        #expect(snapshot.planType == .plus)
        #expect(snapshot.primary == RateLimitWindow(usedPercent: 42, resetsAt: 1_735_689_600, windowDurationMins: 300))
        #expect(snapshot.secondary == RateLimitWindow(usedPercent: 7, resetsAt: 1_735_776_000, windowDurationMins: 10_080))
        #expect(snapshot.rateLimitReachedType == .rateLimitReached)
    }

    @Test func decodesMultiBucketResponse() throws {
        let response = try decoder.decode(GetAccountRateLimitsResponse.self, from: Data(#"""
        {
          "rateLimits": { "primary": { "usedPercent": 10 } },
          "rateLimitsByLimitId": {
            "codex": { "limitId": "codex", "primary": { "usedPercent": 20 } },
            "reviews": { "limitId": "reviews", "primary": { "usedPercent": 30 } }
          }
        }
        """#.utf8))

        #expect(response.rateLimits.primary?.usedPercent == 10)
        #expect(response.rateLimitsByLimitId?.count == 2)
        #expect(response.rateLimitsByLimitId?["reviews"]?.primary?.usedPercent == 30)
    }

    @Test func decodesUpdatedNotification() throws {
        let notification = try decoder.decode(AccountRateLimitsUpdatedNotification.self, from: Data(#"""
        { "rateLimits": { "planType": "team", "primary": { "usedPercent": 85 } } }
        """#.utf8))

        #expect(notification.rateLimits.planType == .team)
        #expect(notification.rateLimits.primary?.usedPercent == 85)
    }

    @Test func decodesCredits() throws {
        let snapshot = try decoder.decode(RateLimitSnapshot.self, from: Data(#"""
        { "credits": { "hasCredits": true, "unlimited": false, "balance": "12.50" } }
        """#.utf8))

        #expect(snapshot.credits == CreditsSnapshot(hasCredits: true, unlimited: false, balance: "12.50"))
    }

    @Test func preservesUnknownPlanType() throws {
        let snapshot = try decoder.decode(RateLimitSnapshot.self, from: Data(#"""
        { "planType": "future_plan" }
        """#.utf8))

        #expect(snapshot.planType == .unrecognized("future_plan"))
    }

    @Test func preservesSchemaUnknownPlanValueAsKnownCase() throws {
        let snapshot = try decoder.decode(RateLimitSnapshot.self, from: Data(#"""
        { "planType": "unknown" }
        """#.utf8))

        #expect(snapshot.planType == .unknown)
    }

    @Test func preservesUnknownReachedType() throws {
        let snapshot = try decoder.decode(RateLimitSnapshot.self, from: Data(#"""
        { "rateLimitReachedType": "future_reached_reason" }
        """#.utf8))

        #expect(snapshot.rateLimitReachedType == .unrecognized("future_reached_reason"))
    }

    @Test func unrecognizedEnumValuesRoundTripLosslessly() throws {
        let encoder = JSONEncoder()

        let plan = PlanType.unrecognized("future_plan")
        let encodedPlan = try encoder.encode(plan)
        #expect(String(decoding: encodedPlan, as: UTF8.self) == #""future_plan""#)
        #expect(try decoder.decode(PlanType.self, from: encodedPlan) == plan)

        let reached = RateLimitReachedType.unrecognized("future_reason")
        let encodedReached = try encoder.encode(reached)
        #expect(String(decoding: encodedReached, as: UTF8.self) == #""future_reason""#)
        #expect(try decoder.decode(RateLimitReachedType.self, from: encodedReached) == reached)
    }

    @Test func roundTripsExplicitCamelCaseKeys() throws {
        let original = Data(#"""
        {
          "rateLimits": {
            "credits": { "hasCredits": true, "unlimited": false, "balance": "3.00" },
            "limitId": "codex",
            "limitName": "Codex",
            "planType": "unknown",
            "primary": { "usedPercent": 91, "resetsAt": 1735689600, "windowDurationMins": 300 },
            "rateLimitReachedType": "workspace_member_usage_limit_reached",
            "secondary": { "usedPercent": 22 }
          },
          "rateLimitsByLimitId": {
            "codex": { "limitId": "codex", "primary": { "usedPercent": 91 } }
          }
        }
        """#.utf8)
        let response = try decoder.decode(GetAccountRateLimitsResponse.self, from: original)
        let encoded = try JSONEncoder().encode(response)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let rateLimits = try #require(json["rateLimits"] as? [String: Any])
        let primary = try #require(rateLimits["primary"] as? [String: Any])
        let credits = try #require(rateLimits["credits"] as? [String: Any])

        #expect(json["rateLimitsByLimitId"] != nil)
        #expect(rateLimits["limitId"] as? String == "codex")
        #expect(rateLimits["rateLimitReachedType"] as? String == "workspace_member_usage_limit_reached")
        #expect(primary["usedPercent"] as? Int == 91)
        #expect(primary["resetsAt"] as? Int == 1_735_689_600)
        #expect(primary["windowDurationMins"] as? Int == 300)
        #expect(credits["hasCredits"] as? Bool == true)

        let roundTripped = try decoder.decode(GetAccountRateLimitsResponse.self, from: encoded)
        #expect(roundTripped == response)
    }
}
