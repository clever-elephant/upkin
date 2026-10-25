import Foundation

public struct GrokUsageSnapshot: Equatable, Sendable {
    public let window: UsageWindow
    public let periodLabel: String
    public let fetchedAt: Date

    public static func decode(from data: Data, fetchedAt: Date = Date()) throws -> Self {
        struct Response: Decodable {
            struct Config: Decodable {
                struct Period: Decodable {
                    let type: String
                    let start: String
                    let end: String
                }
                let creditUsagePercent: Double
                let currentPeriod: Period
            }
            let config: Config
        }
        let config = try JSONDecoder().decode(Response.self, from: data).config
        let formatter = ISO8601DateFormatter()
        func date(_ value: String) -> Date? {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }
        guard config.creditUsagePercent.isFinite, (0...100).contains(config.creditUsagePercent),
              let start = date(config.currentPeriod.start), let end = date(config.currentPeriod.end),
              end > start, end.timeIntervalSince(start) <= 366 * 86_400 else {
            throw CodexUsageFetchError.malformedResponse("Grok billing period or percentage")
        }
        let label: String
        switch config.currentPeriod.type {
        case "USAGE_PERIOD_TYPE_WEEKLY": label = "每周"
        case "USAGE_PERIOD_TYPE_MONTHLY": label = "每月"
        case "USAGE_PERIOD_TYPE_DAILY": label = "每日"
        default: label = "当前周期"
        }
        return Self(window: UsageWindow(usedPercent: config.creditUsagePercent,
                                       windowMinutes: Int(end.timeIntervalSince(start) / 60), resetsAt: end),
                    periodLabel: label, fetchedAt: fetchedAt)
    }
}

public struct GrokUsageFetcher: Sendable {
    public init() {}

    public func fetch() async throws -> GrokUsageSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [home + "/.grok/bin/grok", home + "/.local/bin/grok", "/opt/homebrew/bin/grok", "/usr/local/bin/grok"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CodexUsageFetchError.requestFailed("请先安装并登录 Grok Build")
        }
        let client = try CodexRPCClient(executablePath: path, arguments: ["agent", "stdio"],
                                        environment: [:], jsonRPC: true)
        defer { client.shutdown() }
        struct Initialized: Decodable {}
        let _: Initialized = try await client.requestDecoded(method: "initialize", params: [
            "protocolVersion": 1, "clientCapabilities": [:] as [String: String],
            "clientInfo": ["name": "Upkin", "version": UpkinVersion.current],
        ], timeout: 20)
        // ACP extension methods use an underscore on the wire; no session or prompt is created.
        let data = try await client.requestData(method: "_x.ai/billing", timeout: 20)
        return try GrokUsageSnapshot.decode(from: data)
    }
}
