import Foundation
import AppKit

struct RateLimitInfo {
    let tokensLimit: Int
    let tokensRemaining: Int
    let tokensReset: Date
    let requestsLimit: Int
    let requestsRemaining: Int
    let requestsReset: Date

    var remainingPercentage: Double {
        guard tokensLimit > 0 else { return 0 }
        return Double(tokensRemaining) / Double(tokensLimit) * 100
    }

    var displayPercentage: Int {
        return max(0, min(100, Int(remainingPercentage)))
    }

    var batteryColor: BatteryColor {
        switch displayPercentage {
        case 51...100:
            return .green
        case 21...50:
            return .yellow
        default:
            return .red
        }
    }
}

enum BatteryColor {
    case green
    case yellow
    case red

    var nsColor: NSColor {
        switch self {
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .red: return .systemRed
        }
    }
}

struct ClaudeCredentials: Codable {
    let claudeAiOauth: OAuthInfo

    struct OAuthInfo: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Int64
        let subscriptionType: String?
        let rateLimitTier: String?
    }
}

struct WeeklyLimitInfo {
    let weeklyTokensUsed: Int
    let weeklyTokensLimit: Int
    let weeklyResetDate: Date

    var weeklyRemainingPercentage: Double {
        guard weeklyTokensLimit > 0 else { return 100 }
        let remaining = weeklyTokensLimit - weeklyTokensUsed
        return Double(remaining) / Double(weeklyTokensLimit) * 100
    }
}
