import Foundation

public struct ActivityHookConfiguration {
    public enum Status: String { case missing = "未配置", outdated = "需更新", configured = "已配置" }
    private let home: URL
    private let script: URL
    private let python: String
    private static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "StopFailure",
        "StopCancelled", "SessionEnd", "PreCompact", "PostCompact"]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, script: URL,
                python: String = "/usr/bin/python3") {
        self.home = home
        self.script = script
        self.python = python
    }

    private func paths(for provider: CodingAgent) -> [URL] {
        (provider == .claude ? [".claude/settings.json"]
            : [".grok/hooks/upkin-activity.json", ".grok/hooks/codex-limit-bar-activity.json"])
            .map { self.home.appendingPathComponent($0) }
    }

    private func read(_ path: URL) throws -> (Data?, [String: Any]) {
        guard FileManager.default.fileExists(atPath: path.path) else { return (nil, [:]) }
        let data = try Data(contentsOf: path)
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              config["hooks"] == nil || config["hooks"] is [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (data, config)
    }

    private func isOurs(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        return command.range(of: #"/(?:upkin-activity|codex-limit-bar-activity)\.py(?:['"\s]|$)"#,
                             options: .regularExpression) != nil
    }

    private func command(for provider: CodingAgent) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "\(quote(self.python)) \(quote(self.script.path)) \(provider.rawValue)"
    }

    private func updated(_ config: [String: Any], provider: CodingAgent, install: Bool) throws -> [String: Any] {
        var result = config
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        for event in Set(hooks.keys).union(Self.events) {
            guard hooks[event] == nil || hooks[event] is [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
            var entries: [[String: Any]] = []
            for var entry in hooks[event] as? [[String: Any]] ?? [] {
                guard let commands = entry["hooks"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
                let remaining = commands.filter { !self.isOurs($0) }
                if !remaining.isEmpty { entry["hooks"] = remaining; entries.append(entry) }
            }
            if install && Self.events.contains(event) && !(provider == .claude && event == "StopCancelled") {
                entries.append(["hooks": [["type": "command", "command": self.command(for: provider), "timeout": 2]]])
            }
            hooks[event] = entries.isEmpty ? nil : entries
        }
        result["hooks"] = hooks
        return result
    }

    public func status(for provider: CodingAgent) throws -> Status {
        var found = false
        var current = true
        for (index, path) in self.paths(for: provider).enumerated() {
            let (_, config) = try self.read(path)
            let hooks = config["hooks"] as? [String: Any] ?? [:]
            found = found || hooks.values.contains { entries in
                (entries as? [[String: Any]] ?? []).contains { entry in
                    (entry["hooks"] as? [[String: Any]] ?? []).contains(where: self.isOurs)
                }
            }
            // An absent legacy file is already clean.
            if index > 0 && !FileManager.default.fileExists(atPath: path.path) { continue }
            let expected = try self.updated(config, provider: provider, install: index == 0)
            current = current && (config as NSDictionary).isEqual(to: expected)
        }
        guard found else { return .missing }
        return current && FileManager.default.fileExists(atPath: self.script.path)
            && FileManager.default.isExecutableFile(atPath: self.python) ? .configured : .outdated
    }

    public func configure(_ provider: CodingAgent, install: Bool) throws {
        if install && (!FileManager.default.fileExists(atPath: self.script.path)
            || !FileManager.default.isExecutableFile(atPath: self.python)) { throw CocoaError(.fileNoSuchFile) }
        let changes = try self.paths(for: provider).enumerated().map { index, path in
            let (original, config) = try self.read(path)
            return (path, original, try self.updated(config, provider: provider, install: install && index == 0))
        }
        for (path, original, config) in changes {
            guard original != nil || install && path == self.paths(for: provider)[0] else { continue }
            let current = FileManager.default.fileExists(atPath: path.path) ? try Data(contentsOf: path) : nil
            guard current == original else { throw CocoaError(.fileWriteFileExists) }
            if let original, (try JSONSerialization.jsonObject(with: original) as? NSDictionary)?.isEqual(to: config) == true { continue }
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let permissions = (try? FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions]) ?? 0o600
            try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path.path)
        }
        guard try self.status(for: provider) == (install ? .configured : .missing) else { throw CocoaError(.fileWriteUnknown) }
    }
}
