import Darwin
import Foundation

public enum CodexUsageFetchError: LocalizedError, Sendable {
    case codexNotFound
    case launchFailed(String)
    case requestFailed(String)
    case malformedResponse(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "Could not find Codex CLI. Install Codex or the desktop app."
        case let .launchFailed(message):
            return "Could not start Codex app-server: \(message)"
        case let .requestFailed(message):
            return "Codex request failed: \(message)"
        case let .malformedResponse(message):
            return "Codex returned invalid data: \(message)"
        case let .timeout(method):
            return "Timed out waiting for \(method)."
        }
    }
}

public struct CodexRPCUsageFetcher: Sendable {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func fetch() async throws -> CodexUsageSnapshot {
        guard let executablePath = CodexExecutableLocator.resolve(environment: self.environment) else {
            throw CodexUsageFetchError.codexNotFound
        }
        return try await self.fetch(using: executablePath)
    }

    private func fetch(using executablePath: String) async throws -> CodexUsageSnapshot {
        let client = try CodexRPCClient(
            executablePath: executablePath,
            arguments: ["-s", "read-only", "-a", "on-request", "app-server"],
            environment: self.environment)
        defer { client.shutdown() }

        try await client.initialize()
        let limits: RPCRateLimitsResponse = try await client.requestDecoded(method: "account/rateLimits/read", timeout: 15)
        return CodexUsageSnapshot(rateLimitsResponse: limits)
    }

    // Compare identity, not refresh tokens: token rotation must not launch another RPC.
    public static func accountID(from url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 65_536, let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any] else { return nil }
        return tokens["account_id"] as? String
    }
}

public enum CodexExecutableLocator {
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String?
    {
        let paths = self.effectivePath(environment: environment).split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { String($0) + "/codex" }
        return (paths + self.knownAppExecutablePaths()).first(where: fileExists)
    }

    public static func effectivePath(environment: [String: String]) -> String {
        let defaults = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let local = "\(NSHomeDirectory())/.local/bin"
        let existing = environment["PATH"].flatMap { $0.isEmpty ? nil : $0 }
        return [existing, local, defaults].compactMap { $0 }.joined(separator: ":")
    }

    private static func knownAppExecutablePaths() -> [String] {
        [
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(NSHomeDirectory())/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "\(NSHomeDirectory())/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        ]
    }
}

final class CodexRPCClient: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lineStream: AsyncThrowingStream<Data, Error>
    private let lineContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private var nextID = 1
    private let jsonRPC: Bool

    init(executablePath: String, arguments: [String], environment: [String: String], jsonRPC: Bool = false) throws {
        self.jsonRPC = jsonRPC
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, override in override }
        env["PATH"] = CodexExecutableLocator.effectivePath(environment: environment)

        let stream = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        self.lineStream = stream.stream
        self.lineContinuation = stream.continuation

        // A CLI can exit between launch and write; keep EPIPE local to this pipe.
        guard fcntl(self.stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw CodexUsageFetchError.launchFailed(String(cString: strerror(errno)))
        }

        self.process.executableURL = URL(fileURLWithPath: executablePath)
        self.process.arguments = arguments
        self.process.environment = env
        self.process.standardInput = self.stdinPipe
        self.process.standardOutput = self.stdoutPipe
        self.process.standardError = self.stderrPipe

        do {
            try self.process.run()
        } catch {
            throw CodexUsageFetchError.launchFailed(error.localizedDescription)
        }

        let buffer = LineBuffer()
        self.stdoutPipe.fileHandleForReading.readabilityHandler = { [lineContinuation] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                lineContinuation.finish()
                return
            }
            do {
                for line in try buffer.appendAndDrainLines(data) {
                    if case .dropped = lineContinuation.yield(line) {
                        throw CodexUsageFetchError.malformedResponse("too many pending RPC messages")
                    }
                }
            } catch {
                handle.readabilityHandler = nil
                lineContinuation.finish(throwing: error)
            }
        }

        self.stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
    }

    func initialize() async throws {
        _ = try await self.request(
            method: "initialize",
            params: ["clientInfo": ["name": "Upkin", "version": UpkinVersion.current]],
            timeout: 8)
        try self.sendNotification(method: "initialized")
    }

    func requestDecoded<T: Decodable>(
        method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval = 4) async throws -> T
    {
        let data = try await self.requestData(method: method, params: params, timeout: timeout)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func requestData(method: String, params: [String: Any] = [:], timeout: TimeInterval = 4) async throws -> Data {
        let message = try await self.request(method: method, params: params, timeout: timeout)
        guard let result = message["result"] else {
            throw CodexUsageFetchError.malformedResponse("missing result")
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
    }

    func shutdown() {
        self.lineContinuation.finish()
        self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        self.stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? self.stdinPipe.fileHandleForWriting.close()
        if self.process.isRunning {
            self.process.terminate()
            // A broken CLI may ignore SIGTERM; do not keep it alive after a timeout.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [process] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    private func request(
        method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval) async throws -> [String: Any]
    {
        let id = self.nextID
        self.nextID += 1
        try self.sendRequest(id: id, method: method, params: params)

        return try await withThrowingTaskGroup(of: SendableJSONMessage.self) { group in
            group.addTask {
                while true {
                    let message = try await self.readNextMessage()
                    if message["id"] == nil { continue }
                    guard Self.jsonID(message["id"]) == id else { continue }
                    if let error = message["error"] as? [String: Any],
                       let message = error["message"] as? String
                    {
                        throw CodexUsageFetchError.requestFailed(message)
                    }
                    return SendableJSONMessage(value: message)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CodexUsageFetchError.timeout(method)
            }

            guard let result = try await group.next() else {
                throw CodexUsageFetchError.timeout(method)
            }
            group.cancelAll()
            return result.value
        }
    }

    private func sendRequest(id: Int, method: String, params: [String: Any]) throws {
        try self.sendPayload(["id": id, "method": method, "params": params])
    }

    private func sendNotification(method: String) throws {
        try self.sendPayload(["method": method, "params": [:]])
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        var payload = payload
        if self.jsonRPC { payload["jsonrpc"] = "2.0" }
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        do {
            try self.stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw CodexUsageFetchError.requestFailed(error.localizedDescription)
        }
    }

    private func readNextMessage() async throws -> [String: Any] {
        for try await line in self.lineStream {
            if let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] {
                return message
            }
        }
        throw CodexUsageFetchError.malformedResponse("app-server closed stdout")
    }

    private static func jsonID(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number as? Int
    }

}

private struct SendableJSONMessage: @unchecked Sendable {
    let value: [String: Any]
}

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func appendAndDrainLines(_ chunk: Data) throws -> [Data] {
        self.lock.lock()
        defer { self.lock.unlock() }

        self.data.append(chunk)
        var lines: [Data] = []
        while let newline = self.data.firstIndex(of: 0x0A) {
            guard self.data.distance(from: self.data.startIndex, to: newline) <= 1_048_576 else {
                throw CodexUsageFetchError.malformedResponse("RPC message exceeds 1 MiB")
            }
            let line = Data(self.data[..<newline])
            self.data.removeSubrange(...newline)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        guard self.data.count <= 1_048_576 else {
            throw CodexUsageFetchError.malformedResponse("RPC message exceeds 1 MiB")
        }
        return lines
    }
}
