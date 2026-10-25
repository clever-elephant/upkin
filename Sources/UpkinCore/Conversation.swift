import Foundation

public enum ConversationSource: String, Sendable {
    case desktop, terminal, unknown

    public static func codex(originator: String?, source: String?) -> Self {
        if originator == "Codex Desktop" { return .desktop }
        if source == "cli" || source == "exec" { return .terminal }
        return .unknown
    }
}

public struct Conversation: Equatable, Sendable, Identifiable {
    public let id: String
    public let provider: CodingAgent?
    public let title: String?
    public let cwd: String?
    public let source: ConversationSource
    public let isSubagent: Bool
    public let isStale: Bool
    public let parentConversationID: String?
    public let phase: AgentTaskPhase
    public let updatedAt: TimeInterval
    public let startedAt: TimeInterval?
    public var turnStartedAt: TimeInterval?

    public init(id: String, provider: CodingAgent? = nil, title: String? = nil, cwd: String? = nil,
                phase: AgentTaskPhase, updatedAt: TimeInterval, startedAt: TimeInterval? = nil,
                turnStartedAt: TimeInterval? = nil, source: ConversationSource = .unknown, isSubagent: Bool = false, parentConversationID: String? = nil, isStale: Bool = false) {
        self.turnStartedAt = turnStartedAt.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.isStale = isStale
        self.parentConversationID = provider == nil ? parentConversationID : nil
        self.isSubagent = isSubagent
        self.source = source
        self.id = id
        self.provider = provider
        self.title = Self.displayText(title)
        if let cwd, cwd.hasPrefix("/"), cwd.utf8.count <= 4096,
           !cwd.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            self.cwd = cwd
        } else {
            self.cwd = nil
        }
        self.phase = phase
        self.updatedAt = updatedAt
        self.startedAt = startedAt.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    public func runningDuration(at now: Date = Date()) -> String? {
        guard !self.isStale, self.phase.isRunning, let startedAt, now.timeIntervalSince1970.isFinite,
              startedAt <= now.timeIntervalSince1970 else { return nil }
        let elapsedMinutes = (now.timeIntervalSince1970 - startedAt) / 60
        guard elapsedMinutes < Double(Int.max) else { return nil }
        let minutes = Int(elapsedMinutes)
        if minutes < 1 { return "不足 1 分钟" }
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60) 小时" + (minutes % 60 > 0 ? " \(minutes % 60) 分钟" : "")
    }

    public static func visible(_ conversations: [Conversation]) -> [Conversation] {
        var completed = 0
        return conversations.filter { $0.group != nil }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
            .filter {
                guard $0.phase == .completed else { return true }
                completed += 1
                return completed <= 10
            }
    }

    public func launchTarget(in conversations: [Conversation]) -> Conversation? {
        var target = self
        var visited: Set<String> = []
        while target.isSubagent || target.parentConversationID != nil {
            guard visited.insert(target.id).inserted, let parentID = target.parentConversationID,
                  let parent = conversations.first(where: { $0.id == parentID && $0.provider == nil }) else { return nil }
            target = parent
        }
        return target
    }

    public struct TreeRow {
        public let conversation: Conversation
        public let depth: Int
        public let group: ConversationGroup
    }

    public static func tree(_ conversations: [Conversation]) -> [TreeRow] {
        let sorted = conversations.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        let byID = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let children = Dictionary(grouping: sorted.filter { $0.parentConversationID != nil }, by: { $0.parentConversationID! })
        var visited: Set<String> = []
        func collect(_ conversation: Conversation, depth: Int) -> [TreeRow] {
            guard visited.insert(conversation.id).inserted else { return [] }
            return [TreeRow(conversation: conversation, depth: depth, group: .completed)]
                + (children[conversation.id] ?? []).flatMap { collect($0, depth: depth + 1) }
        }
        var trees: [[TreeRow]] = []
        for item in sorted where item.parentConversationID.flatMap({ byID[$0] }) == nil {
            trees.append(collect(item, depth: 0))
        }
        // Malformed cycles stay visible once instead of recursing forever or hiding tasks.
        for item in sorted where !visited.contains(item.id) { trees.append(collect(item, depth: 0)) }
        trees.removeAll(where: \.isEmpty)
        trees.sort {
            let left = $0.map { $0.conversation.updatedAt }.max() ?? 0
            let right = $1.map { $0.conversation.updatedAt }.max() ?? 0
            return left == right ? $0[0].conversation.id < $1[0].conversation.id : left > right
        }
        var completed = 0
        return trees.flatMap { rows -> [TreeRow] in
            let groups = Set(rows.compactMap { $0.conversation.group })
            guard let group = ConversationGroup.allCases.first(where: { groups.contains($0) }) else { return [] }
            if group == .completed {
                completed += 1
                guard completed <= 10 else { return [] }
            }
            return rows.map { TreeRow(conversation: $0.conversation, depth: $0.depth, group: group) }
        }
    }

    public var desktopURL: URL? {
        guard self.provider == nil, self.source == .desktop,
              let id = ITermConversationLauncher.sessionID(for: self) else { return nil }
        return URL(string: "codex://threads/" + id)
    }

    public var displayTitle: String { self.title ?? "未命名会话" }
    public var project: String? { self.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } }
    public var statusLabel: String { self.isStale ? "状态已过期" : self.phase.label }
    public var group: ConversationGroup? {
        guard !self.isStale else { return nil }
        return switch self.phase {
        case .waiting, .error, .unknown: .attention
        case .thinking, .working: .running
        case .completed: .completed
        case .idle: nil
        }
    }
    public var emotion: GrokBallEmotion {
        guard !self.isStale else { return .unknown }
        return switch self.phase {
        case .thinking: .thinking
        case .working: .working
        case .waiting: .waiting
        case .completed: .completed
        case .error: .error
        case .unknown: .unknown
        case .idle: .idle
        }
    }

    static func displayText(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(500))
    }
}

public enum ConversationGroup: String, CaseIterable, Sendable {
    case attention = "待处理", running = "运行中", completed = "已完成"
}

// Read metadata only; never use prompts or replies as invented conversation titles.
enum ConversationMetadata {
    static func lines(at url: URL) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        var result: [[String: Any]] = []
        // shortcut: metadata must be in the first/last 64 KiB; add an index if a provider moves it deeper.
        for offset in Set([UInt64(0), size > 65_536 ? size - 65_536 : 0]).sorted() {
            try? handle.seek(toOffset: offset)
            guard let bytes = try? handle.read(upToCount: 65_536) else { continue }
            for line in bytes.split(separator: 10) {
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { result.append(object) }
            }
        }
        return result
    }

    static func agent(_ task: AgentTask, home: URL) -> (title: String?, cwd: String?) {
        // A session ID is an opaque filename component, not a path supplied by a hook.
        guard !task.sessionID.contains("/"), task.sessionID != ".", task.sessionID != ".." else { return (nil, nil) }
        let base = home.appendingPathComponent(task.provider == .claude ? ".claude/projects" : ".grok/sessions")
        let folders = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            if task.provider == .grok {
                let url = folder.appendingPathComponent(task.sessionID).appendingPathComponent("summary.json")
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536,
                      let data = try? Data(contentsOf: url),
                      let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let info = summary["info"] as? [String: Any], info["id"] as? String == task.sessionID else { continue }
                return (summary["generated_title"] as? String, info["cwd"] as? String)
            }
            let entries = self.lines(at: folder.appendingPathComponent(task.sessionID + ".jsonl"))
                .filter { $0["sessionId"] as? String == task.sessionID }
            if !entries.isEmpty {
                let title = entries.reversed().compactMap { $0["customTitle"] as? String }.first
                    ?? entries.reversed().compactMap { $0["aiTitle"] as? String }.first
                return (title, entries.reversed().compactMap { $0["cwd"] as? String }.first)
            }
        }
        return (nil, nil)
    }
}
