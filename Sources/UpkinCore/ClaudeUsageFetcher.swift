import LocalAuthentication
import CryptoKit
import Foundation
import Security

public enum ClaudeUsageFetchError: LocalizedError, Sendable {
    case connectionRequired
    case loginRequired
    case keychainLocked
    case keychainFailed(Int32)
    case requestFailed(Int)
    case rateLimited(until: Date)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .connectionRequired: "请连接 Claude 额度以授权读取本机登录凭据"
        case .loginRequired: "请先在 Claude Code 登录订阅账号，再刷新额度"
        case .keychainLocked: "钥匙串访问受限，请解锁钥匙串或点击重试完成系统授权"
        case let .keychainFailed(status):
            switch status {
            case errSecAuthFailed: "Claude 钥匙串认证失败（\(status)），请重新连接并使用 Mac 登录密码完成授权"
            case errSecUserCanceled: "Claude 钥匙串授权已取消，请点击连接 Claude 额度重试"
            default: "Claude 凭据读取失败（钥匙串错误 \(status)），请刷新重试"
            }
        case let .rateLimited(until):
            "Claude 请求过于频繁（HTTP 429），\(until.formatted(date: .omitted, time: .shortened)) 后可重试"
        case .requestFailed(403): "Claude 额度访问被拒绝（HTTP 403），请检查账号权限或网络后重试"
        case let .requestFailed(status): "Claude 额度请求失败（HTTP \(status)），请稍后刷新"
        case .malformedResponse: "Claude 返回的额度数据格式异常"
        }
    }
}

public struct ClaudeUsageSnapshot: Equatable, Sendable {
    public let fiveHour: UsageWindow?
    public let weekly: UsageWindow?
    public let fetchedAt: Date

    public static func decode(from data: Data, fetchedAt: Date = Date()) throws -> Self {
        struct Window: Decodable {
            let utilization: Double
            let resets_at: String?

            func usage(minutes: Int) throws -> UsageWindow {
                guard utilization.isFinite, (0...100).contains(utilization) else {
                    throw ClaudeUsageFetchError.malformedResponse
                }
                var reset: Date?
                if let resets_at {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    reset = formatter.date(from: resets_at)
                    if reset == nil {
                        formatter.formatOptions = [.withInternetDateTime]
                        reset = formatter.date(from: resets_at)
                    }
                    guard reset != nil else { throw ClaudeUsageFetchError.malformedResponse }
                }
                return UsageWindow(usedPercent: utilization, windowMinutes: minutes, resetsAt: reset)
            }
        }
        struct Response: Decodable {
            let five_hour: Window?
            let seven_day: Window?
        }
        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            let short = try response.five_hour?.usage(minutes: 300)
            let weekly = try response.seven_day?.usage(minutes: 10_080)
            guard short != nil || weekly != nil else { throw ClaudeUsageFetchError.malformedResponse }
            return Self(fiveHour: short, weekly: weekly, fetchedAt: fetchedAt)
        } catch { throw ClaudeUsageFetchError.malformedResponse }
    }
}

public actor ClaudeUsageFetcher {
    private let defaults: UserDefaults
    public static let consentKey = "claudeUsageAccessGranted"
    private let credentials: @Sendable (Bool) throws -> Data
    private let credentialRevision: @Sendable () -> Data?
    private var cachedCredentials: (data: Data, revision: Data, readAt: Date)?
    private let loader: @Sendable (URLRequest) async throws -> ClaudeUsageSnapshot
    private var cached: ClaudeUsageSnapshot?
    private var cacheKey: String?
    private var inFlight: Task<ClaudeUsageSnapshot, Error>?

    public init(defaults: UserDefaults = .standard,
                credentials: (@Sendable (Bool) throws -> Data)? = nil,
                credentialRevision: (@Sendable () -> Data?)? = nil,
                loader: (@Sendable (URLRequest) async throws -> ClaudeUsageSnapshot)? = nil) {
        self.defaults = defaults
        self.credentials = credentials ?? { try Self.readCredentials(allowInteraction: $0) }
        self.credentialRevision = credentialRevision ?? { Self.readCredentialRevision() }
        self.loader = loader ?? { try await Self.load(request: $0) }
    }

    public func fetch(now: Date = Date(), allowInteraction: Bool = false) async throws -> ClaudeUsageSnapshot {
        guard self.defaults.bool(forKey: Self.consentKey) else {
            self.clearCache()
            throw ClaudeUsageFetchError.connectionRequired
        }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.fetchCached(now: now, allowInteraction: allowInteraction) }
        self.inFlight = task
        defer { self.inFlight = nil }
        return try await task.value
    }

    public func clearCache() {
        self.cachedCredentials = nil
        self.cached = nil
        self.cacheKey = nil
    }

    private func credentialData(now: Date, allowInteraction: Bool) async throws -> Data {
        let probe = self.credentialRevision
        let revision = await Task.detached { probe() }.value
        if !allowInteraction, let saved = self.cachedCredentials, revision == saved.revision,
           (0..<1800).contains(now.timeIntervalSince(saved.readAt)),
           (try? Self.request(credentials: saved.data, now: now)) != nil {
            return saved.data
        }
        self.cachedCredentials = nil
        let reader = self.credentials
        let data = try await Task.detached { try reader(allowInteraction) }.value
        _ = try Self.request(credentials: data, now: now)
        // Do not cache a payload if its source changed during the read.
        if let revision, await Task.detached(operation: { probe() }).value == revision {
            self.cachedCredentials = (data, revision, now)
        }
        return data
    }

    private func fetchCached(now: Date, allowInteraction: Bool) async throws -> ClaudeUsageSnapshot {
        let request: URLRequest
        do {
            let credentials = try await self.credentialData(now: now, allowInteraction: allowInteraction)
            request = try Self.request(credentials: credentials, now: now)
        } catch {
            self.clearCache()
            throw error
        }
        // Persist only a credential fingerprint, never the bearer token or quota body.
        let key = "claudeUsageRetryAfter." + SHA256.hash(data: Data(request.value(forHTTPHeaderField: "Authorization")!.utf8))
            .map { String(format: "%02x", $0) }.joined()
        if self.cacheKey != key { self.cached = nil; self.cacheKey = key }
        if let cached, (0..<900).contains(now.timeIntervalSince(cached.fetchedAt)) { return cached }
        let until = Date(timeIntervalSince1970: self.defaults.double(forKey: key))
        if until > now {
            if let cached { return cached }
            throw ClaudeUsageFetchError.rateLimited(until: until)
        }
        self.defaults.removeObject(forKey: key)
        do {
            let snapshot = try await self.loader(request)
            self.cached = snapshot
            return snapshot
        } catch {
            if case let ClaudeUsageFetchError.rateLimited(until) = error {
                self.defaults.set(until.timeIntervalSince1970, forKey: key)
            }
            if let error = error as? ClaudeUsageFetchError {
                switch error {
                case .loginRequired, .requestFailed(403): self.clearCache()
                default: break
                }
            }
            if error is CancellationError { throw error }
            if let cached { return cached }
            throw error
        }
    }

    private static func load(request: URLRequest) async throws -> ClaudeUsageSnapshot {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return try Self.snapshot(data: data, statusCode: http?.statusCode ?? 0,
                                 retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
    }

    public static func request(credentials: Data, now: Date = Date()) throws -> URLRequest {
        struct Credentials: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                let expiresAt: Double?
            }
            let claudeAiOauth: OAuth?
        }
        guard credentials.count <= 1_048_576,
              let oauth = (try? JSONDecoder().decode(Credentials.self, from: credentials))?.claudeAiOauth,
              !oauth.accessToken.isEmpty, oauth.accessToken.utf8.count <= 16_384,
              oauth.accessToken.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0)
                  && !CharacterSet.controlCharacters.contains($0) }),
              oauth.expiresAt.map({ $0.isFinite && $0 / 1000 > now.timeIntervalSince1970 }) ?? true else {
            throw ClaudeUsageFetchError.loginRequired
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(oauth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public static func snapshot(data: Data, statusCode: Int, retryAfter: String? = nil,
                                now: Date = Date()) throws -> ClaudeUsageSnapshot {
        if statusCode == 429 {
            throw ClaudeUsageFetchError.rateLimited(until: retryDate(retryAfter: retryAfter, now: now))
        }
        if statusCode == 401 { throw ClaudeUsageFetchError.loginRequired }
        guard statusCode == 200 else { throw ClaudeUsageFetchError.requestFailed(statusCode) }
        guard data.count <= 1_048_576 else { throw ClaudeUsageFetchError.malformedResponse }
        return try ClaudeUsageSnapshot.decode(from: data)
    }

    public static func retryDate(retryAfter: String?, now: Date = Date()) -> Date {
        if let value = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let seconds = Double(value), seconds.isFinite, seconds > 0 {
                let date = now.addingTimeInterval(seconds)
                if date.timeIntervalSince1970.isFinite { return date }
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: value), date > now { return date }
        }
        return now.addingTimeInterval(600)
    }

    private static func credentialFile() throws -> Data {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_048_576, let data = try? Data(contentsOf: file),
              !data.isEmpty, data.count <= 1_048_576 else {
            throw ClaudeUsageFetchError.loginRequired
        }
        return data
    }

    private static let keychainLock = NSLock()

    private static func copyKeychainItem(_ query: [String: Any], allowInteraction: Bool,
                                         result: inout CFTypeRef?) -> OSStatus {
        // Legacy keychain ACL prompts ignore LAContext; serialize the process-wide switch.
        self.keychainLock.lock()
        defer { self.keychainLock.unlock() }
        var previous: DarwinBoolean = true
        let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
        guard readStatus == errSecSuccess else { return readStatus }
        let setStatus = SecKeychainSetUserInteractionAllowed(allowInteraction)
        guard setStatus == errSecSuccess else { return setStatus }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return SecItemCopyMatching(query as CFDictionary, &result)
    }

    private static func readCredentialRevision() -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        let status = Self.copyKeychainItem(query, allowInteraction: false, result: &result)
        if status == errSecItemNotFound {
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let modified = attributes[.modificationDate] as? Date,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber else { return nil }
            return Data("file:\(inode):\(size):\(modified.timeIntervalSince1970)".utf8)
        }
        guard status == errSecSuccess, let attributes = result as? [String: Any],
              let reference = attributes[kSecValuePersistentRef as String] as? Data,
              let modified = attributes[kSecAttrModificationDate as String] as? Date else { return nil }
        return reference + Data(modified.timeIntervalSince1970.description.utf8)
    }

    private static func readCredentials(allowInteraction: Bool) throws -> Data {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        let status = Self.copyKeychainItem(query, allowInteraction: allowInteraction, result: &result)
        if status == errSecItemNotFound { return try Self.credentialFile() }
        if status == errSecInteractionNotAllowed { throw ClaudeUsageFetchError.keychainLocked }
        guard status == errSecSuccess else { throw ClaudeUsageFetchError.keychainFailed(status) }
        guard let data = result as? Data, !data.isEmpty, data.count <= 1_048_576 else {
            throw ClaudeUsageFetchError.loginRequired
        }
        return data
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    // Keep the bearer token on the fixed Anthropic endpoint, even if it redirects.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
