import Foundation
import SQLite3

public struct CodexSessionActivitySnapshot: Equatable, Sendable {
    public let activeThreadCount: Int
    public let loadedThreadCount: Int
    public let conversations: [Conversation]

    public init(
        activeThreadCount: Int,
        loadedThreadCount: Int,
        conversations: [Conversation] = [])
    {
        self.conversations = conversations
        self.activeThreadCount = activeThreadCount
        self.loadedThreadCount = loadedThreadCount
    }

    public var hasActiveSession: Bool {
        self.activeThreadCount > 0
    }

}

public actor CodexSessionActivityFetcher {
    private let sessionsURL: URL
    private var rollouts: [URL: RolloutState] = [:]
    private var titles: [String: String] = [:]
    private var indexModified: Date?

    private struct RolloutState {
        var offset: UInt64 = 0
        var pending = Data()
        var active: Bool?
        var phase: AgentTaskPhase?
        var updatedAt: TimeInterval?
        var id: String?
        var cwd: String?
        var source: ConversationSource = .unknown
        var parentConversationID: String?
        var isSubagent = false
        var fallbackTitle: String?
        var startedAt: TimeInterval?
        var turnStartedAt: TimeInterval?
        var didReadStart = false
        var modified: Date?
        var identity: NSObject?
    }

    public init(sessionsURL: URL = CodexStateWatcher.rootURL.appendingPathComponent("sessions")) {
        self.sessionsURL = sessionsURL.resolvingSymlinksInPath().standardizedFileURL
    }

    public func fetch(changedFiles: Set<URL>? = nil, now: Date = Date()) async -> CodexSessionActivitySnapshot {
        // Drain temporary Foundation parsing objects before this actor's worker thread returns to idle.
        return autoreleasepool {
            self.readTitles()
            let files: Set<URL>
            if let changedFiles {
                files = Set(changedFiles.map { $0.resolvingSymlinksInPath().standardizedFileURL })
            } else {
                files = CodexRolloutFiles.recent(in: self.sessionsURL, now: now)
                self.rollouts = self.rollouts.filter { files.contains($0.key) }
            }
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileResourceIdentifierKey, .fileSizeKey]
            for var file in files {
                file.removeAllCachedResourceValues()
                guard let values = try? file.resourceValues(forKeys: keys),
                      let modified = values.contentModificationDate,
                      let size = values.fileSize,
                      self.lastRolloutTaskIsActive(in: file, size: UInt64(size),
                        modified: modified, identity: values.fileResourceIdentifier as? NSObject,
                        readStart: now.timeIntervalSince(modified) < 3_600) != nil else {
                    self.rollouts.removeValue(forKey: file)
                    continue
                }
            }
            // Activity expires independently; retain recent history to keep session trees intact.
            let recent = self.rollouts.filter { now.timeIntervalSince($0.value.modified ?? .distantPast) < 3_600 }
            let names = self.readNames()
            let states = recent.values.compactMap(\.active)
            let conversations: [Conversation] = self.rollouts.compactMap { file, state in
                    guard let active = state.active else { return nil }
                    let indexedTitle = state.id.flatMap { self.titles[$0] }
                    let title = state.id.flatMap { names[$0] }
                        ?? (indexedTitle?.hasPrefix("Codex Companion Task:") == true ? "Codex 辅助任务" : indexedTitle)
                        ?? state.fallbackTitle
                    return Conversation(id: "codex:" + (state.id ?? file.path), title: title, cwd: state.cwd,
                        phase: active ? (state.phase ?? .working) : (state.phase == .unknown ? .unknown : .completed),
                        updatedAt: state.updatedAt ?? state.modified?.timeIntervalSince1970 ?? 0, startedAt: recent[file] == nil ? nil : state.startedAt, turnStartedAt: recent[file] == nil ? nil : state.turnStartedAt, source: state.source, isSubagent: state.isSubagent, parentConversationID: state.parentConversationID,
                        isStale: state.phase != .completed && now.timeIntervalSince(state.modified ?? .distantPast) >= 3_600)
                }.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
            return CodexSessionActivitySnapshot(activeThreadCount: states.filter { $0 }.count,
                loadedThreadCount: states.count, conversations: conversations)
        }
    }

    private func lastRolloutTaskIsActive(
        in file: URL, size: UInt64, modified: Date, identity: NSObject?, readStart: Bool) -> Bool?
    {
        var state = self.rollouts[file] ?? RolloutState()
        if state.modified == modified, state.identity == identity, state.offset == size {
            return state.active
        }
        // ponytail: rollouts append in place; arbitrary growing in-place rewrites need identity/version tracking.
        // Replacements, truncation and same-size rewrites restart parsing.
        if state.identity != identity || size < state.offset
            || (size == state.offset && state.modified != modified)
        {
            state = RolloutState()
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        do {
            if state.modified == nil || (readStart && !state.didReadStart) {
                state = try Self.initialRolloutState(handle: handle, size: size, readStart: readStart)
                if let metadata = ConversationMetadata.lines(at: file).first(where: { $0["type"] as? String == "session_meta" })?["payload"] as? [String: Any] {
                    state.id = metadata["id"] as? String
                    state.cwd = metadata["cwd"] as? String
                    let spawn = ((metadata["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
                    state.isSubagent = (metadata["source"] as? [String: Any])?["subagent"] != nil
                        || metadata["thread_source"] as? String == "subagent"
                    if state.isSubagent, let parentID = metadata["parent_thread_id"] as? String ?? spawn?["parent_thread_id"] as? String,
                       !parentID.isEmpty {
                        state.parentConversationID = "codex:" + parentID
                    }
                    state.source = .codex(originator: metadata["originator"] as? String,
                                          source: metadata["source"] as? String)
                    if let source = metadata["source"] as? [String: Any],
                       let subagent = source["subagent"] as? [String: Any],
                       let spawn = subagent["thread_spawn"] as? [String: Any] {
                        let nickname = Conversation.displayText(spawn["agent_nickname"] as? String)
                        state.fallbackTitle = nickname.map { "子代理 · " + $0 } ?? "Codex 子代理"
                    } else if metadata["source"] as? String == "exec" {
                        state.fallbackTitle = "Codex 命令行任务"
                    }
                }
            }
            try handle.seek(toOffset: state.offset)
            while state.offset < size {
                let count = Int(min(size - state.offset, 65_536))
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { return nil }
                state.offset += UInt64(chunk.count)
                var start = chunk.startIndex
                for newline in chunk.indices where chunk[newline] == 10 {
                    state.pending.append(contentsOf: chunk[start..<newline])
                    if let phase = Self.phase(in: state.pending) {
                        if phase.isRunning && state.phase == .waiting {
                            state.turnStartedAt = Self.eventTimestamp(in: state.pending) ?? state.turnStartedAt
                        }
                        state.phase = phase
                        state.updatedAt = Self.eventTimestamp(in: state.pending)
                    }
                    if let active = Self.taskActivity(in: state.pending) {
                        state.active = active
                        if active, let start = Self.eventTimestamp(in: state.pending) {
                            state.startedAt = start
                            state.turnStartedAt = start
                        }
                    }
                    state.pending.removeAll(keepingCapacity: state.pending.count <= 65_536)
                    start = chunk.index(after: newline)
                }
                state.pending.append(contentsOf: chunk[start...])
            }
        } catch {
            return nil
        }
        state.modified = modified
        state.identity = identity
        self.rollouts[file] = state
        return state.active
    }

    private static func initialRolloutState(handle: FileHandle, size: UInt64, readStart: Bool) throws -> RolloutState {
        var state = RolloutState()
        state.didReadStart = readStart
        state.offset = size
        var offset = size
        var fragments: [Data] = []
        var isIncompleteLastLine = true
        var runningAt: TimeInterval?
        func line() -> Data {
            var data = Data()
            for fragment in fragments.reversed() { data.append(fragment) }
            fragments.removeAll(keepingCapacity: true)
            return data
        }
        while offset > 0 {
            let count = Int(min(offset, 65_536))
            offset -= UInt64(count)
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: count), chunk.count == count else {
                throw CocoaError(.fileReadUnknown)
            }
            var end = chunk.endIndex
            for newline in chunk.indices.reversed() where chunk[newline] == 10 {
                fragments.append(Data(chunk[chunk.index(after: newline)..<end]))
                let data = line()
                if isIncompleteLastLine {
                    state.pending = data
                    isIncompleteLastLine = false
                } else {
                    let phase = state.phase == nil || state.turnStartedAt == nil ? Self.phase(in: data) : nil
                    let active = Self.taskActivity(in: data)
                    if let phase, state.turnStartedAt == nil {
                        if phase.isRunning { runningAt = Self.eventTimestamp(in: data) }
                        else if phase == .waiting, let runningAt { state.turnStartedAt = runningAt }
                        else { runningAt = nil }
                    }
                    if state.turnStartedAt == nil, active == true { state.turnStartedAt = Self.eventTimestamp(in: data) }
                    if state.phase == nil, let phase {
                        state.phase = phase
                        state.updatedAt = Self.eventTimestamp(in: data)
                    }
                    if let active {
                        if state.active == nil { state.active = active }
                        // History only needs the last state, not a backward scan to the turn's start.
                        if !readStart, state.phase != nil { return state }
                        if active {
                            state.startedAt = Self.eventTimestamp(in: data)
                            return state
                        }
                    }
                }
                end = newline
            }
            fragments.append(Data(chunk[..<end]))
        }
        let data = line()
        if isIncompleteLastLine {
            state.pending = data
        } else {
            if state.phase == nil {
                state.phase = Self.phase(in: data)
                state.updatedAt = Self.eventTimestamp(in: data)
            }
            if state.active == nil { state.active = Self.taskActivity(in: data) }
            state.startedAt = Self.startTimestamp(in: data)
            state.turnStartedAt = state.turnStartedAt ?? state.startedAt
        }
        return state
    }

    private func readNames() -> [String: String] {
        let root = self.sessionsURL.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let databases = files.filter {
            $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite"
                && Int($0.deletingPathExtension().lastPathComponent.dropFirst(6)) != nil
        }.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        guard let file = databases.first else { return [:] }
        var database: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return [:]
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        // The desktop name is metadata; threads.title can contain the entire first prompt.
        guard sqlite3_prepare_v2(database, "SELECT name FROM threads WHERE id = ?", -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var names: [String: String] = [:]
        for id in self.rollouts.values.compactMap(\.id) {
            sqlite3_reset(statement)
            let name: String? = id.withCString { value in
                guard sqlite3_bind_text(statement, 1, value, -1, nil) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_ROW,
                      let text = sqlite3_column_text(statement, 0) else { return nil }
                return Conversation.displayText(String(cString: text))
            }
            if let name { names[id] = name }
        }
        return names
    }

    private func readTitles() {
        let url = self.sessionsURL.deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate, modified != self.indexModified,
              let size = values.fileSize, size <= 8_388_608, let data = try? Data(contentsOf: url) else { return }
        self.indexModified = modified
        self.titles.removeAll(keepingCapacity: true)
        for line in data.split(separator: 10) {
            guard let item = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = item["id"] as? String, let title = item["thread_name"] as? String else { continue }
            self.titles[id] = title
        }
    }

    private static func phase(in line: Data) -> AgentTaskPhase? {
        guard let text = String(data: line, encoding: .utf8),
              text.contains("\"payload\""),
              ["task_started", "turn_started", "user_message", "task_complete", "turn_aborted", "function_call", "custom_tool_call", "reasoning"].contains(where: text.contains),
              let item = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = item["payload"] as? [String: Any], let type = payload["type"] as? String else { return nil }
        if item["type"] as? String == "event_msg" {
            switch type {
            case "task_started", "turn_started", "user_message": return .thinking
            case "task_complete": return .completed
            case "turn_aborted": return .unknown
            default: return nil
            }
        }
        guard item["type"] as? String == "response_item" else { return nil }
        switch type {
        case "function_call", "custom_tool_call":
            return (payload["name"] as? String)?.hasSuffix("request_user_input") == true ? .waiting : .working
        case "function_call_output", "custom_tool_call_output", "reasoning": return .thinking
        default: return nil
        }
    }

    private static func eventTimestamp(in line: Data) -> TimeInterval? {
        guard let item = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let timestamp = item["timestamp"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: timestamp)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = date ?? formatter.date(from: timestamp), date.timeIntervalSinceNow <= 60 else { return nil }
        return date.timeIntervalSince1970
    }

    private static func startTimestamp(in line: Data) -> TimeInterval? {
        Self.taskActivity(in: line) == true ? Self.eventTimestamp(in: line) : nil
    }

    private static func taskActivity(in line: Data) -> Bool? {
        guard let text = String(data: line, encoding: .utf8),
              text.contains("\"payload\""),
              ["task_started", "turn_started", "user_message", "task_complete", "turn_aborted"].contains(where: text.contains),
              let event = try? JSONDecoder().decode(RolloutEvent.self, from: line) else { return nil }
        guard event.type == "event_msg" else { return nil }
        switch event.payload.type {
        case "task_started", "turn_started", "user_message": return true
        case "task_complete", "turn_aborted": return false
        default: return nil
        }
    }

}

private struct RolloutEvent: Decodable {
    let timestamp: String?
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String
    }
}

// Resumed sessions keep their original date folder; discover by modification time as well.
enum CodexRolloutFiles {
    static func recent(in root: URL, now: Date) -> Set<URL> {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        let folders = Set([0, -1].compactMap { offset in
            Calendar.current.date(byAdding: .day, value: offset, to: now)
                .map { root.appendingPathComponent(formatter.string(from: $0)).path }
        })
        guard let entries = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var files = Set<URL>()
        for case let entry as URL in entries {
            let file = entry.standardizedFileURL
            let parts = file.path.dropFirst(root.path.count + 1).split(separator: "/")
            guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey,
                .isSymbolicLinkKey, .contentModificationDateKey]) else { continue }
            if values.isDirectory == true {
                if parts.count > 3 || parts.last?.count != (parts.count == 1 ? 4 : 2)
                    || parts.last?.allSatisfy({ $0.isASCII && $0.isNumber }) != true
                    || values.isSymbolicLink == true { entries.skipDescendants() }
                continue
            }
            guard parts.count == 4, file.pathExtension == "jsonl", values.isSymbolicLink != true,
                  values.isRegularFile == true, let modified = values.contentModificationDate,
                  folders.contains(file.deletingLastPathComponent().path)
                    || now.timeIntervalSince(modified) < 172_800 else { continue }
            files.insert(file.standardizedFileURL)
        }
        return files
    }
}
