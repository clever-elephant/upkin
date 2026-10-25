import Darwin
import Foundation

public enum ITermConversationLauncher {
    public enum LaunchError: LocalizedError {
        case invalidConversation, missingDirectory, executableNotFound(String), automation(String)

        public var errorDescription: String? {
            switch self {
            case .invalidConversation: "此会话缺少有效的会话 ID。"
            case .missingDirectory: "项目目录已不存在，请先恢复目录后重试。"
            case .executableNotFound(let name): "未找到 \(name) CLI，请先安装对应工具。"
            case .automation(let message): "打开 iTerm 失败，请检查系统设置 → 隐私与安全性 → 自动化。\n" + message
            }
        }
    }

    public static func sessionID(for conversation: Conversation) -> String? {
        let prefix = (conversation.provider?.rawValue ?? "codex") + ":"
        guard conversation.id.hasPrefix(prefix) else { return nil }
        let id = String(conversation.id.dropFirst(prefix.count))
        return UUID(uuidString: id) == nil ? nil : id
    }

    public static func command(sessionID: String, cwd: String, executable: String, provider: CodingAgent? = nil) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let arguments = provider == nil ? "resume --no-daemon" : "--resume"
        return "cd -- \(quote(cwd)) && \(quote(executable)) \(arguments) \(quote(sessionID))"
    }

    public static func matchingTTYs(in processes: String, sessionID: String, provider: CodingAgent? = nil) -> [String] {
        processes.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 4, fields[0] != "??" else { return nil }
            let name = provider?.rawValue ?? "codex"
            let executable = URL(fileURLWithPath: fields[1]).lastPathComponent
            let script = fields.count > 4 ? fields[2] : ""
            let isAgent = executable == name || (executable == "node" &&
                (URL(fileURLWithPath: script).lastPathComponent == name + ".js" ||
                 (provider == .claude && script.hasSuffix("/@anthropic-ai/claude-code/cli.js"))))
            let flags = provider == .grok ? ["--resume", "-r", "--session-id", "-s"] : ["--resume", "-r", "--session-id"]
            let matchesID = provider == nil
                ? fields.contains("resume") && fields.contains(where: { $0.caseInsensitiveCompare(sessionID) == .orderedSame })
                : fields.indices.dropLast().contains(where: {
                    flags.contains(fields[$0]) && fields[$0 + 1].caseInsensitiveCompare(sessionID) == .orderedSame
                })
            guard isAgent, matchesID else { return nil }
            return "/dev/" + fields[0]
        }
    }

    public static func matchingClaudeTTYs(in processes: String, sessions: [Data], sessionID: String) -> [String] {
        struct Session: Decodable {
            let pid: Int
            let sessionId: String
            let procStart: String
            let kind: String
        }
        let matches = sessions.compactMap { try? JSONDecoder().decode(Session.self, from: $0) }
            .filter { $0.kind == "interactive" && $0.sessionId.caseInsensitiveCompare(sessionID) == .orderedSame }
        return processes.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 8, let pid = Int(fields[0]), fields[1].hasPrefix("ttys"),
                  URL(fileURLWithPath: fields[7]).lastPathComponent == "claude",
                  matches.contains(where: {
                      $0.pid == pid && $0.procStart.split(whereSeparator: \.isWhitespace).map(String.init) == Array(fields[2...6])
                  }) else { return nil }
            return "/dev/" + fields[1]
        }
    }

    public static func open(_ conversation: Conversation) async throws {
        try await Task.detached {
            guard let id = self.sessionID(for: conversation) else { throw LaunchError.invalidConversation }
            let processes = try self.run("/bin/ps", arguments: ["-axo", "tty=,args="])
            var ttys = self.matchingTTYs(in: processes, sessionID: id, provider: conversation.provider)
            if conversation.provider == .claude {
                let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude"
                let directory = URL(fileURLWithPath: home).appendingPathComponent("sessions")
                let sessions = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "json" }.compactMap { try? Data(contentsOf: $0) }
                // Claude records procStart in UTC; verify it to reject stale records after PID reuse.
                let live = try self.run("/usr/bin/env", arguments: ["TZ=UTC", "/bin/ps", "-axo", "pid=,tty=,lstart=,comm="])
                ttys = self.matchingClaudeTTYs(in: live, sessions: sessions, sessionID: id) + ttys
            }
            // Focus first: restoring a moved/deleted project is only necessary for a new tab.
            let name = conversation.provider?.rawValue ?? "codex"
            let marker = name + ":" + id.lowercased()
            if try self.run("/usr/bin/osascript", arguments: ["-", "focus", marker] + ttys, input: self.script).contains("focused") { return }
            var isDirectory: ObjCBool = false
            guard let cwd = conversation.cwd, FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else { throw LaunchError.missingDirectory }
            let paths = CodexExecutableLocator.effectivePath(environment: ProcessInfo.processInfo.environment).split(separator: ":").map { String($0) + "/" + name }
                + (conversation.provider == .grok ? [NSHomeDirectory() + "/.grok/bin/grok"] : [])
            guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
                ?? (conversation.provider == nil ? CodexExecutableLocator.resolve() : nil) else {
                throw LaunchError.executableNotFound(conversation.provider?.name ?? "Codex")
            }
            let command = self.command(sessionID: id, cwd: cwd, executable: executable, provider: conversation.provider)
            _ = try self.run("/usr/bin/osascript", arguments: ["-", "open", marker, command] + ttys, input: self.script)
        }.value
    }

    package static func run(_ executable: String, arguments: [String], input: String? = nil,
                            timeout: TimeInterval = 35) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = output
        if input != nil {
            guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw LaunchError.automation(String(cString: strerror(errno)))
            }
            process.standardInput = stdin
        }
        try process.run()
        let deadline = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer {
            deadline.cancel()
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        if let input {
            try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw LaunchError.automation(text) }
        return text
    }

    private static let script = """
    on run argv
        set mode to item 1 of argv
        set marker to item 2 of argv
        set targetTTYs to {}
        set firstTTY to 3
        if mode is "open" then set firstTTY to 4
        if (count argv) ≥ firstTTY then set targetTTYs to items firstTTY thru -1 of argv
        with timeout of 30 seconds
            tell application "iTerm"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            set tagged to false
                            try
                                set tagged to (variable s named "user.upkinConversation") is marker
                            end try
                            if not tagged then
                                try
                                    set tagged to (variable s named "user.codexLimitBarConversation") is marker
                                end try
                            end if
                            if tagged and (is at shell prompt of s) then set tagged to false
                            if tagged or (tty of s is in targetTTYs) then
                                select t
                                select s
                                set index of w to 1
                                activate
                                return "focused"
                            end if
                        end repeat
                    end repeat
                end repeat
                if mode is "focus" then return "missing"
                if (count windows) is 0 then
                    set w to create window with default profile
                    set s to current session of w
                else
                    set t to create tab with default profile in current window
                    set s to current session of t
                end if
                tell s
                    write text (item 3 of argv)
                    set variable named "user.upkinConversation" to marker
                end tell
                activate
                return "opened"
            end tell
        end timeout
    end run
    """
}
