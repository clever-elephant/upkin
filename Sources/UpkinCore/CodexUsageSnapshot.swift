import Foundation

public struct UsageWindow: Equatable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = min(100, max(0, usedPercent))
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double {
        min(100, max(0, 100 - self.usedPercent))
    }

    public var roundedRemainingPercent: Int {
        Int(self.remainingPercent.rounded())
    }

    public func resetText(relativeTo now: Date = Date()) -> String {
        guard let resetsAt else { return "reset unknown" }
        let interval = resetsAt.timeIntervalSince(now)
        guard interval.isFinite, interval < Double(Int.max) else { return "reset unknown" }
        let seconds = Int(max(0, interval))
        if seconds == 0 { return "resetting now" }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(max(1, minutes))m"
    }

}

public struct CodexUsageSnapshot: Equatable, Sendable {
    public let fiveHour: UsageWindow?
    public let weekly: UsageWindow?
    public let planType: String?
    public let fetchedAt: Date

    public init(
        fiveHour: UsageWindow?,
        weekly: UsageWindow?,
        planType: String?,
        fetchedAt: Date)
    {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.planType = planType
        self.fetchedAt = fetchedAt
    }

    public var availablePercent: Int? {
        [self.fiveHour, self.weekly].compactMap { $0?.roundedRemainingPercent }.min()
    }

    public var accessibilitySummary: String {
        self.availablePercent.map { "Codex usage: \($0)% available" }
            ?? "Codex usage unavailable"
    }

    public static func decodeRateLimits(from data: Data, fetchedAt: Date = Date()) throws -> CodexUsageSnapshot {
        let decoded = try JSONDecoder().decode(RPCRateLimitsResponse.self, from: data)
        return CodexUsageSnapshot(rateLimitsResponse: decoded, fetchedAt: fetchedAt)
    }

    init(rateLimitsResponse decoded: RPCRateLimitsResponse, fetchedAt: Date = Date()) {
        let windows = decoded.rateLimits.windowsByDuration
        self.init(
            fiveHour: UsageWindow(rpc: windows.short),
            weekly: UsageWindow(rpc: windows.long),
            planType: decoded.rateLimits.planType,
            fetchedAt: fetchedAt)
    }

}

private extension UsageWindow {
    init?(rpc: RPCRateLimitWindow?) {
        guard let rpc else { return nil }
        self.init(
            usedPercent: rpc.usedPercent,
            windowMinutes: rpc.windowDurationMins,
            resetsAt: rpc.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

}

struct RPCRateLimitsResponse: Decodable, Encodable {
    let rateLimits: RPCRateLimitSnapshot
}

struct RPCRateLimitSnapshot: Decodable, Encodable {
    let primary: RPCRateLimitWindow?
    let secondary: RPCRateLimitWindow?
    let planType: String?

    var windowsByDuration: (short: RPCRateLimitWindow?, long: RPCRateLimitWindow?) {
        let windows = [self.primary, self.secondary].compactMap { $0 }
        guard windows.allSatisfy({ ($0.windowDurationMins ?? 0) > 0 }) else {
            return (nil, nil)
        }
        if windows.count == 1, let window = windows.first {
            return (window.windowDurationMins! >= 10_080) ? (nil, window) : (window, nil)
        }
        guard windows.count == 2 else { return (nil, nil) }
        let sorted = windows.sorted { lhs, rhs in
            (lhs.windowDurationMins ?? Int.max) < (rhs.windowDurationMins ?? Int.max)
        }
        return (sorted[0], sorted[1])
    }
}

struct RPCRateLimitWindow: Decodable, Encodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?
}
