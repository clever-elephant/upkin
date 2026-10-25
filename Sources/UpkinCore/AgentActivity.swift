import Foundation

public enum CodingAgent: String, Codable, CaseIterable, Sendable {
    case grok, claude

    public var name: String { self == .grok ? "Grok Build" : "Claude Code" }
}

public enum AgentTaskPhase: String, Codable, Sendable {
    case idle, thinking, working, waiting, completed, error, unknown

    public var label: String {
        switch self {
        case .idle: "待机"
        case .thinking: "思考"
        case .working: "工作"
        case .waiting: "等待输入"
        case .completed: "完成"
        case .error: "出错"
        case .unknown: "状态待确认"
        }
    }

    public var isRunning: Bool { self == .thinking || self == .working }
}

public struct AgentTask: Codable, Equatable, Sendable {
    public let provider: CodingAgent
    public let sessionID: String
    public var phase: AgentTaskPhase
    public let startedAt: TimeInterval?
    public var turnStartedAt: TimeInterval?
    public var title: String?
    public var cwd: String?
    public let updatedAt: TimeInterval

    public init(provider: CodingAgent, sessionID: String, phase: AgentTaskPhase, updatedAt: TimeInterval, startedAt: TimeInterval? = nil, turnStartedAt: TimeInterval? = nil, title: String? = nil, cwd: String? = nil) {
        self.turnStartedAt = turnStartedAt
        self.title = title
        self.cwd = cwd
        self.provider = provider
        self.sessionID = sessionID
        self.phase = phase
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

public struct AgentActivitySnapshot: Equatable, Sendable {
    public let tasks: [AgentTask]

    public init(tasks: [AgentTask] = []) { self.tasks = tasks }

    public var conversations: [Conversation] {
        self.tasks.map { Conversation(id: $0.provider.rawValue + ":" + $0.sessionID, provider: $0.provider,
                                     title: $0.title, cwd: $0.cwd, phase: $0.phase, updatedAt: $0.updatedAt, startedAt: $0.startedAt, turnStartedAt: $0.turnStartedAt ?? $0.startedAt) }
    }

    public var runningCount: Int { self.tasks.filter { $0.phase.isRunning }.count }
    public var waitingCount: Int { self.tasks.filter { $0.phase == .waiting }.count }
    public var errorCount: Int { self.tasks.filter { $0.phase == .error }.count }
    public var unknownCount: Int { self.tasks.filter { $0.phase == .unknown }.count }

    public var summary: String {
        "运行 \(self.runningCount) · 等待 \(self.waitingCount) · 错误 \(self.errorCount) · 待确认 \(self.unknownCount)"
    }
}

public actor AgentActivityStore {
    public nonisolated static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Upkin/activity", isDirectory: true)
    }

    private let directory: URL
    private let home: URL
    private var records: [URL: AgentTask] = [:]

    public init(directory: URL = AgentActivityStore.directory, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
        self.home = home
    }

    public func fetch(changedFiles: Set<URL>? = nil, now: Date = Date()) -> AgentActivitySnapshot {
        let files: Set<URL>
        if let changedFiles {
            files = Set(changedFiles.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        } else {
            let listed = (try? FileManager.default.contentsOfDirectory(at: self.directory,
                includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            files = Set(listed.map { $0.resolvingSymlinksInPath().standardizedFileURL })
            self.records = self.records.filter { files.contains($0.key) }
        }
        for file in files where file.pathExtension == "json" && file.deletingLastPathComponent().path == self.directory.path {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 16_384, let data = try? Data(contentsOf: file), data.count <= 16_384,
                  let task = try? JSONDecoder().decode(AgentTask.self, from: data),
                  !task.sessionID.isEmpty, task.sessionID.utf8.count <= 800,
                  task.sessionID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  task.startedAt.map({ $0.isFinite && $0 <= now.timeIntervalSince1970 + 60 }) ?? true,
                  task.turnStartedAt.map({ $0.isFinite && $0 > 0 && $0 <= now.timeIntervalSince1970 + 60 }) ?? true,
                  task.updatedAt.isFinite, task.updatedAt <= now.timeIntervalSince1970 + 60 else {
                self.records.removeValue(forKey: file)
                continue
            }
            var enriched = task
            let metadata = ConversationMetadata.agent(task, home: self.home)
            enriched.title = metadata.title ?? task.title
            enriched.cwd = metadata.cwd ?? task.cwd
            self.records[file] = enriched
        }
        // shortcut: silent/crashed sessions become unknown after one hour; add a process lease if needed.
        let recent = self.records.values.filter { now.timeIntervalSince1970 - $0.updatedAt < 86_400 }
        let tasks: [AgentTask] = recent.map { record -> AgentTask in
            var task = record
            let age = now.timeIntervalSince1970 - task.updatedAt
            if age > 3_600 && (task.phase.isRunning || task.phase == .waiting) { task.phase = .unknown }
            return task
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.sessionID < $1.sessionID : $0.updatedAt > $1.updatedAt }
        return AgentActivitySnapshot(tasks: tasks)
    }
}
