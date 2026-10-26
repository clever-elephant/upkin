import Foundation
import SQLite3
import UpkinCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Test failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}

func migratesLegacyPreferences() {
    let suite = "upkin-migration-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("current", forKey: "existing")
    UpkinPreferences.migrate(defaults: defaults, legacy: ["existing": "old", "characterSelections": ["codex": "my-pack"]])
    expect(defaults.string(forKey: "existing") == "current", "Migration preserves current preferences")
    expect(defaults.dictionary(forKey: "characterSelections") as? [String: String] == ["codex": "my-pack"], "Migration keeps legacy character choices")
    defaults.removeObject(forKey: "characterSelections")
    UpkinPreferences.migrate(defaults: defaults, legacy: ["characterSelections": ["codex": "my-pack"]])
    expect(defaults.object(forKey: "characterSelections") == nil, "Migration runs once and respects resets")
}

func decodesRateLimitWindows() throws {
    let payload = """
    {
      "rateLimits": {
        "primary": {
          "usedPercent": 15,
          "windowDurationMins": 300,
          "resetsAt": 1781242263
        },
        "secondary": {
          "usedPercent": 68,
          "windowDurationMins": 10080,
          "resetsAt": 1781255126
        },
        "credits": { "hasCredits": false, "unlimited": false, "balance": "0" },
        "planType": "pro"
      }
    }
    """.data(using: .utf8)!

    let snapshot = try CodexUsageSnapshot.decodeRateLimits(from: payload, fetchedAt: Date(timeIntervalSince1970: 1_781_232_000))

    expect(snapshot.planType == "pro", "plan type should decode")
    expect(snapshot.fiveHour?.windowMinutes == 300, "primary window should be 300 minutes")
    expect(snapshot.fiveHour?.usedPercent == 15, "primary used percent should decode")
    expect(snapshot.fiveHour?.remainingPercent == 85, "primary remaining percent should derive")
    expect(snapshot.weekly?.windowMinutes == 10080, "weekly window should be 10080 minutes")
    expect(snapshot.weekly?.usedPercent == 68, "weekly used percent should decode")
    expect(snapshot.weekly?.remainingPercent == 32, "weekly remaining percent should derive")
}

func decodesRateLimitWindowsByDuration() throws {
    let payload = """
    {
      "rateLimits": {
        "primary": {
          "usedPercent": 68,
          "windowDurationMins": 10080,
          "resetsAt": 1781255126
        },
        "secondary": {
          "usedPercent": 15,
          "windowDurationMins": 300,
          "resetsAt": 1781242263
        },
        "credits": { "hasCredits": false, "unlimited": false, "balance": "0" },
        "planType": "pro"
      }
    }
    """.data(using: .utf8)!

    let snapshot = try CodexUsageSnapshot.decodeRateLimits(from: payload, fetchedAt: Date(timeIntervalSince1970: 1_781_232_000))

    expect(snapshot.fiveHour?.windowMinutes == 300, "shorter window should map to 5h quota when RPC order changes")
    expect(snapshot.fiveHour?.usedPercent == 15, "shorter window should preserve its usage")
    expect(snapshot.weekly?.windowMinutes == 10080, "longer window should map to weekly quota when RPC order changes")
    expect(snapshot.weekly?.usedPercent == 68, "longer window should preserve its usage")
}

func classifiesSingleWeeklyRateLimitWindow() throws {
    let payload = """
    {
      "rateLimits": {
        "primary": {
          "usedPercent": 55,
          "windowDurationMins": 10080,
          "resetsAt": 1784951013
        },
        "secondary": null,
        "credits": { "hasCredits": false, "unlimited": false, "balance": "0" },
        "planType": "pro"
      }
    }
    """.data(using: .utf8)!

    let snapshot = try CodexUsageSnapshot.decodeRateLimits(from: payload)

    expect(snapshot.fiveHour == nil, "single weekly window should not be mislabeled as 5h")
    expect(snapshot.weekly?.remainingPercent == 45, "single weekly window should remain available")
}

func rejectsQuotaWindowsWithoutDuration() throws {
    for secondary in ["null", #"{"usedPercent":20,"windowDurationMins":10080}"#] {
        let payload = #"{"rateLimits":{"primary":{"usedPercent":10},"secondary":\#(secondary)}}"#
        let snapshot = try CodexUsageSnapshot.decodeRateLimits(from: Data(payload.utf8))
        expect(snapshot.fiveHour == nil && snapshot.weekly == nil,
            "missing duration must not guess quota windows from field order")
    }
}

func selectsAvailableQuota() {
    for (short, weekly, expected) in [(10, 80, 10), (80, 10, 10), (0, 80, 0), (100, 100, 100),
                                      (25, nil, 25), (nil, 40, 40), (nil, nil, nil)] as [(Int?, Int?, Int?)] {
        let snapshot = CodexUsageSnapshot(
            fiveHour: short.map { UsageWindow(usedPercent: Double(100 - $0), windowMinutes: 300, resetsAt: nil) },
            weekly: weekly.map { UsageWindow(usedPercent: Double(100 - $0), windowMinutes: 10_080, resetsAt: nil) },
            planType: nil, fetchedAt: Date())
        expect(snapshot.availablePercent == expected, "Available quota uses the lowest remaining window, including partial/missing data")
        expect(snapshot.accessibilitySummary == (expected.map { "Codex usage: \($0)% available" } ?? "Codex usage unavailable"),
               "Accessibility describes the same available quota as the menu bar")
    }
}

func clampsPercentages() {
    let over = UsageWindow(usedPercent: 130, windowMinutes: 300, resetsAt: nil)
    let under = UsageWindow(usedPercent: -10, windowMinutes: 300, resetsAt: nil)

    expect(over.usedPercent == 100, "used percent above 100 should clamp")
    expect(over.remainingPercent == 0, "remaining percent above 100 should clamp")
    expect(under.usedPercent == 0, "used percent below 0 should clamp")
    expect(under.remainingPercent == 100, "remaining percent below 0 should clamp")
}

func formatsResetTextInEnglish() {
    let now = Date(timeIntervalSince1970: 1_000)
    let later = UsageWindow(
        usedPercent: 10,
        windowMinutes: 300,
        resetsAt: Date(timeIntervalSince1970: 1_000 + 7_260))

    expect(later.resetText(relativeTo: now) == "2h 1m", "reset countdown should use English units")
}

func locatesCodexExecutables() {
    let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    let standalone = "/opt/homebrew/bin/codex"
    let sparse = ["PATH": "/usr/bin:/bin"]
    expect(CodexExecutableLocator.resolve(environment: sparse, fileExists: { $0 == standalone }) == standalone,
           "standalone CLI should be found even with a sparse GUI PATH")
    expect(CodexExecutableLocator.resolve(environment: sparse, fileExists: { $0 == bundled || $0 == standalone }) == standalone,
           "standalone CLI should take precedence over bundled CLI")
    for path in [bundled, "\(NSHomeDirectory())/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                 "/Applications/Codex.app/Contents/Resources/codex", "\(NSHomeDirectory())/Applications/Codex.app/Contents/Resources/codex",
                 "\(NSHomeDirectory())/.local/bin/codex", "/usr/local/bin/codex"] {
        expect(CodexExecutableLocator.resolve(environment: sparse, fileExists: { $0 == path }) == path,
               "CLI should be discoverable at \(path)")
    }
    let custom = "/custom/bin/codex"
    expect(CodexExecutableLocator.resolve(environment: ["PATH": "/custom/bin"], fileExists: { $0 == custom || $0 == standalone }) == custom,
           "explicit PATH order should be respected")
    expect(CodexExecutableLocator.resolve(environment: ["PATH": "relative/bin"], fileExists: { $0 == "relative/bin/codex" }) == nil,
           "relative PATH entries must not launch a project-local executable")
    expect(CodexExecutableLocator.resolve(environment: sparse, fileExists: { _ in false }) == nil,
           "missing CLI should return nil")
}

func reportsActiveSessionWhenAnyThreadIsActive() {
    let active = CodexSessionActivitySnapshot(activeThreadCount: 1, loadedThreadCount: 3)
    let idle = CodexSessionActivitySnapshot(activeThreadCount: 0, loadedThreadCount: 3)

    expect(active.hasActiveSession, "one active thread should mark session activity active")
    expect(!idle.hasActiveSession, "loaded but idle threads should not mark session activity active")
}

func readsRecentRolloutTaskState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy/MM/dd"
    let folder = root.appendingPathComponent(formatter.string(from: Date()))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("rollout-test.jsonl")
    let started = """
    {"type":"event_msg","payload":{"type":"task_started"}}
    """
    let padding = "{" + "\"padding\":\"" + String(repeating: "x", count: 70_000) + "\"}"
    try (started + "\n" + padding + "\n").write(to: file, atomically: true, encoding: .utf8)
    let fetcher = CodexSessionActivityFetcher(sessionsURL: root)
    let active = await fetcher.fetch()
    expect(active.hasActiveSession, "recent task_started should show working")
    try (started + "\n" + padding + "\n" +
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n")
        .write(to: file, atomically: true, encoding: .utf8)
    let idle = await fetcher.fetch()
    expect(!idle.hasActiveSession, "task_complete should return to idle")
}

@MainActor
func retainsResumedOldRolloutsAndBoundsWatchers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .resolvingSymlinksInPath().standardizedFileURL
    let sessions = root.appendingPathComponent("sessions")
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    let folder = sessions.appendingPathComponent("2020/01/01")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let resumed = folder.appendingPathComponent("resumed.jsonl")
    let started = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n".utf8)
    try started.write(to: resumed)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: resumed.path)
    let expired = folder.appendingPathComponent("expired.jsonl")
    try started.write(to: expired)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-172_801)], ofItemAtPath: expired.path)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked.jsonl"),
                                               withDestinationURL: resumed)
    let nested = folder.appendingPathComponent("extra")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try started.write(to: nested.appendingPathComponent("ignored.jsonl"))
    let fetcher = CodexSessionActivityFetcher(sessionsURL: sessions)
    let cold = await fetcher.fetch(now: now)
    expect(cold.activeThreadCount == 1 && cold.conversations.count == 1,
           "Cold discovery includes fresh writes in old date folders, not expired history")
    let event = await fetcher.fetch(changedFiles: [resumed], now: now)
    let rescanned = await fetcher.fetch(now: now)
    expect(event == cold && rescanned == cold, "Recovery never drops a resumed old-folder task")
    let watcher = try CodexStateWatcher(rootURL: root) { _, _ in }
    func watchedCount() -> Int {
        let sources = Mirror(reflecting: watcher).children.first { $0.label == "rolloutSources" }!.value
        return Mirror(reflecting: sources).children.count
    }
    expect(watchedCount() == 1, "Startup watches the resumed old-folder task, not expired files")
    for day in 1...5 {
        let date = now.addingTimeInterval(Double(day) * 86_400)
        let file = folder.appendingPathComponent("day-\(day).jsonl")
        try started.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        watcher.refreshRollouts(now: date)
        expect(watchedCount() == 2, "Recovery releases aged vnode sources while keeping the recent pair")
    }
    watcher.refreshRollouts(now: now.addingTimeInterval(8 * 86_400))
    expect(watchedCount() == 0, "Idle history leaves no vnode sources after retention expires")
    let empty = await fetcher.fetch(now: now.addingTimeInterval(8 * 86_400))
    expect(empty.conversations.isEmpty, "Fetcher and watcher expire the same historical files")
    let missing = root.appendingPathComponent("not-created/sessions")
    let absent = await CodexSessionActivityFetcher(sessionsURL: missing).fetch(now: now)
    expect(absent.conversations.isEmpty, "New installations tolerate an absent sessions directory")
    print("Resumed rollouts: old-folder cold/event/recovery parity, expiry and bounded vnode retention passed")
}

func incrementallyReadsRollouts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy/MM/dd"
    let folder = root.appendingPathComponent(formatter.string(from: Date()))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("incremental.jsonl")
    let started = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
    let completed = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n"
    let fetcher = CodexSessionActivityFetcher(sessionsURL: root)
    func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
    try started.write(to: file, atomically: true, encoding: .utf8)
    let initial = await fetcher.fetch()
    expect(initial.hasActiveSession, "initial scan should detect activity")
    for _ in 0..<5 {
        let cached = await fetcher.fetch()
        expect(cached == initial, "unchanged files should preserve cached activity")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
    if !FileManager.default.isReadableFile(atPath: file.path) {
        let unreadableCached = await fetcher.fetch()
        expect(unreadableCached == initial, "unchanged cached file must not be reopened")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try append(String(completed.dropLast()))
    let partial = await fetcher.fetch()
    expect(partial.hasActiveSession, "partial last line must wait for its newline")
    try append("\n")
    let finished = await fetcher.fetch()
    expect(!finished.hasActiveSession, "newline should finish an event buffered across polls")
    try started.write(to: file, atomically: false, encoding: .utf8)
    let truncated = await fetcher.fetch()
    expect(truncated.hasActiveSession, "truncation should discard cached offsets")
    try completed.write(to: file, atomically: true, encoding: .utf8)
    let replaced = await fetcher.fetch()
    expect(!replaced.hasActiveSession, "atomic replacement should restart parsing")
    let sameSizeStarted = String(started.dropLast()) + " \n"
    expect(sameSizeStarted.utf8.count == completed.utf8.count, "same-size rewrite fixture must match")
    try sameSizeStarted.write(to: file, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(0.5)], ofItemAtPath: file.path)
    let rewritten = await fetcher.fetch()
    expect(rewritten.hasActiveSession, "same-size in-place rewrite must invalidate cached activity")
    let clock = ContinuousClock()
    let large = "{\"padding\":\"" + String(repeating: "x", count: 8_000_000) + "\"}\n"
    try (started + large).write(to: file, atomically: true, encoding: .utf8)
    let firstStart = clock.now
    let largeSnapshot = await fetcher.fetch()
    let firstDuration = firstStart.duration(to: clock.now)
    expect(largeSnapshot.hasActiveSession, "large lines spanning blocks must preserve task state")
    let cachedStart = clock.now
    for _ in 0..<100 {
        let cached = await fetcher.fetch()
        expect(cached == largeSnapshot, "large unchanged rollout should reuse state")
    }
    print("Activity benchmark (8MB): initial=\(firstDuration), 100 cached polls=\(cachedStart.duration(to: clock.now))")
    try append(completed)
    let appended = await fetcher.fetch()
    expect(!appended.hasActiveSession, "completion appended after a large line should be detected")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_601)], ofItemAtPath: file.path)
    let stale = await fetcher.fetch()
    expect(stale.loadedThreadCount == 0, "cached state must expire with stale files")
    try FileManager.default.removeItem(at: file)
    let removed = await fetcher.fetch()
    expect(removed.loadedThreadCount == 0, "deleted files must leave the cache")
}

func detectsAccountIdentityWithoutTokenChurn() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    func write(_ id: String, _ token: String) throws {
        try Data("{\"tokens\":{\"account_id\":\"\(id)\",\"refresh_token\":\"\(token)\"}}".utf8)
            .write(to: file, options: .atomic)
    }
    try write("ACCOUNT_A", "TOKEN_A")
    let first = CodexRPCUsageFetcher.accountID(from: file)
    try write("ACCOUNT_A", "TOKEN_B")
    expect(CodexRPCUsageFetcher.accountID(from: file) == first, "token rotation must not change identity")
    try write("ACCOUNT_B", "TOKEN_B")
    expect(CodexRPCUsageFetcher.accountID(from: file) != first, "account switching must change identity")
    try Data("{}".utf8).write(to: file, options: .atomic)
    expect(CodexRPCUsageFetcher.accountID(from: file) == nil, "logout must clear identity")
    try Data(repeating: 32, count: 65_537).write(to: file)
    expect(CodexRPCUsageFetcher.accountID(from: file) == nil, "oversized auth files must be rejected")
}

@MainActor
func watchesOnlyCodexStateChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .resolvingSymlinksInPath().standardizedFileURL
    let sessions = root.appendingPathComponent("sessions/2026/10/07")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var received = Set<URL>()
    var batches = 0
    var watcher: CodexStateWatcher? = try CodexStateWatcher(rootURL: root) { files, _ in
        received.formUnion(files)
        batches += 1
    }
    expect(watcher != nil, "native event stream should start")
    try await Task.sleep(for: .seconds(1))
    received.removeAll(); batches = 0
    let appearance = root.appendingPathComponent(".codex-global-state.json")
    for _ in 0..<20 { try Data("{}".utf8).write(to: appearance, options: .atomic) }
    let auth = root.appendingPathComponent("auth.json")
    try Data("{}".utf8).write(to: auth, options: .atomic)
    let rollout = sessions.appendingPathComponent("fixture.jsonl")
    try Data("{}\n".utf8).write(to: rollout)
    let database = root.appendingPathComponent("state_5.sqlite")
    let wal = root.appendingPathComponent("state_5.sqlite-wal")
    for file in [database, wal] { try Data("fixture".utf8).write(to: file) }
    for _ in 0..<100 {
        if received.isSuperset(of: [auth, rollout, database, wal]) { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    expect(received.isSuperset(of: [auth, rollout, database, wal]), "Auth, rollouts and desktop-name database/WAL writes must trigger events")
    expect(!received.contains(appearance), "Removed avatar state must not trigger appearance work")
    let persistent = try FileHandle(forWritingTo: rollout)
    defer { try? persistent.close() }
    try persistent.seekToEnd()
    for attempt in 0..<10 {
        received.remove(rollout)
        try persistent.write(contentsOf: Data("{\"append\":\(attempt)}\n".utf8))
        for _ in 0..<30 {
            if received.contains(rollout) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        expect(received.contains(rollout), "Persistent open rollout writes must be observed before closing the writer")
    }

    expect(batches < 20, "burst writes must be coalesced")
    try await Task.sleep(for: .milliseconds(600))
    let before = batches
    try Data("ignored".utf8).write(to: root.appendingPathComponent("notes.txt"))
    try await Task.sleep(for: .seconds(1))
    expect(batches == before, "unrelated files and idle time must not trigger work")
    watcher = nil
    try persistent.write(contentsOf: Data("{}\n".utf8))
    try Data("{}".utf8).write(to: auth, options: .atomic)
    try await Task.sleep(for: .seconds(1))
    expect(batches == before, "releasing the watcher must stop callbacks")
    print("State events: recursive writes, persistent open writers, atomic replacement, burst coalescing, unrelated-file filtering, teardown passed")
}

func updatesOnlyChangedRollouts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
    let folder = root.appendingPathComponent(formatter.string(from: Date()))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let a = folder.appendingPathComponent("a.jsonl"), b = folder.appendingPathComponent("b.jsonl")
    let started = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n".utf8)
    let completed = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n".utf8)
    try started.write(to: a); try started.write(to: b)
    let fetcher = CodexSessionActivityFetcher(sessionsURL: root)
    let initial = await fetcher.fetch()
    expect(initial.activeThreadCount == 2, "initial scan should discover both sessions")
    try completed.write(to: a, options: .atomic)
    let changed = await fetcher.fetch(changedFiles: [a])
    expect(changed.activeThreadCount == 1 && changed.loadedThreadCount == 2, "a changed file must not erase other cached sessions")
    try FileManager.default.removeItem(at: b)
    let deleted = await fetcher.fetch(changedFiles: [b])
    expect(deleted.activeThreadCount == 0 && deleted.loadedThreadCount == 1, "deletion event must remove the cached session")
}


func tracksConcurrentAgentSessions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    func write(_ name: String, _ provider: CodingAgent, _ phase: AgentTaskPhase,
               age: TimeInterval = 0, session: String = "same") throws -> URL {
        let path = root.appendingPathComponent(name + ".json")
        try JSONEncoder().encode(AgentTask(provider: provider, sessionID: session,
            phase: phase, updatedAt: now.timeIntervalSince1970 - age)).write(to: path, options: .atomic)
        return path
    }
    let grok = try write("grok", .grok, .working)
    let claude = try write("claude", .claude, .thinking)
    _ = try write("waiting", .claude, .waiting, session: "other")
    let store = AgentActivityStore(directory: root)
    let active = await store.fetch(now: now)
    expect(active.runningCount == 2 && active.waitingCount == 1, "Sources and session IDs must count independently")
    _ = try write("grok", .grok, .completed)
    let completed = await store.fetch(changedFiles: [grok], now: now)
    expect(completed.runningCount == 1 && completed.waitingCount == 1,
        "One completion must not clear other sessions or waiting tasks")
    try Data("broken".utf8).write(to: claude)
    let corrupt = await store.fetch(changedFiles: [claude], now: now)
    expect(corrupt.runningCount == 0 && corrupt.tasks.count == 2, "Malformed changed record must leave other sessions intact")
    _ = try write("stale", .grok, .working, age: 3_601, session: "stale")
    _ = try write("old", .grok, .working, age: 86_401, session: "old")
    _ = try write("future", .grok, .working, age: -120, session: "future")
    _ = try write("control", .claude, .thinking, session: "bad\nname")
    let stale = await store.fetch(now: now)
    expect(stale.unknownCount == 1 && stale.runningCount == 0,
        "Silent sessions become unknown, never successful; old/future/control records are rejected")
    try FileManager.default.removeItem(at: grok)
    let deleted = await store.fetch(changedFiles: [grok], now: now)
    expect(!deleted.tasks.contains { $0.provider == .grok && $0.sessionID == "same" }, "Deleted records must leave the snapshot")
    print("Agent states: independent providers, concurrent tasks, waiting, completion isolation, malformed/stale records passed")
}


func testsMenuBarRules() {
    let now = Date(timeIntervalSince1970: 1000)
    func item(_ id: String, _ phase: AgentTaskPhase, _ time: TimeInterval,
              turn: TimeInterval? = nil, child: Bool = false, stale: Bool = false) -> Conversation {
        Conversation(id: id, provider: id == "A" ? .claude : .grok, phase: phase,
                     updatedAt: time, turnStartedAt: turn, isSubagent: child, isStale: stale)
    }
    let a = item("A", .working, 900, turn: 800)
    let b = item("B", .thinking, 950, turn: 900)
    let child = item("child", .working, 999, turn: 999, child: true)
    expect(MenuBarPresentation.focus(in: [a, b, child])?.id == "B", "Focus uses turn start, excluding subagents")
    expect(MenuBarPresentation.focus(in: [a, item("B", .error, 999, turn: 999)])?.id == "A", "Errors immediately yield focus")
    expect(MenuBarPresentation.focus(in: [a, item("B", .working, 999, turn: 999, stale: true)])?.id == "A", "Expired focus yields")
    expect(!MenuBarPresentation.hasWaiting(in: [item("child", .waiting, 999, child: true), item("old", .waiting, 999, stale: true)]), "Only live parent waits show a marker")

    var state = MenuBarPresentation()
    expect(state.update([a, b, child], now: now).isEmpty, "First read never emits events")
    expect(state.provider == .grok && state.emotion == .thinking, "Newest running task supplies its own action")
    expect(state.displayedConversation?.id == "B", "Without a cue, displayed object is focus B")
    _ = state.update([item("A", .working, 999, turn: 800), b], now: now)
    expect(state.provider == .grok, "Ordinary tool updates never steal focus")
    let doneA = item("A", .completed, 1000, turn: 800)
    let events = state.update([doneA, b], now: now)
    expect(events.count == 1 && events[0].kind == .completed && state.provider == .claude, "A completion interrupts B with A's character")
    expect(state.displayedConversation?.id == "A", "Displayed object is event A, not background focus B")
    _ = state.update([doneA, b, item("C", .working, 1001, turn: 1001)], now: now)
    expect(state.provider == .claude && state.emotion == .completed, "New work never interrupts a full prompt cycle")
    state.finishPlayback()
    expect(state.emotion == .working && MenuBarPresentation.focus(in: state.tracker.conversations)?.id == "C", "End of prompt picks latest running turn")

    var timeline = MenuBarPresentation()
    _ = timeline.update([a, b], now: now)
    _ = timeline.update([doneA, b], now: now)
    timeline.finishPlayback()
    expect(timeline.provider == .grok && timeline.emotion == .thinking, "A finishes and returns to B")
    let waitingB = item("B", .waiting, 1001, turn: 900)
    expect(timeline.update([doneA, waitingB], now: now).first?.kind == .waiting, "B wait emits once")
    expect(timeline.hasWaiting && timeline.emotion == .waiting, "Wait marker is independent of playback")
    timeline.finishPlayback()
    expect(timeline.provider == .grok && timeline.emotion == .idle && timeline.hasWaiting, "No running work keeps last character idle with marker")
    expect(timeline.update([doneA, waitingB], now: now).isEmpty, "Continuous waiting never repeats")
    _ = timeline.update([doneA, waitingB, item("C", .working, 1002, turn: 1002)], now: now)
    _ = timeline.update([doneA, item("B", .working, 1003, turn: 900), item("C", .working, 1002, turn: 1002)], now: now)
    expect(MenuBarPresentation.focus(in: timeline.tracker.conversations)?.id == "B", "Resumed B gets a new turn newer than C")
    expect(!timeline.hasWaiting && timeline.tracker.exitedWaiting == ["B"], "Resume clears marker and removes B wait notification")
    _ = timeline.update([doneA, item("B", .working, 1004, turn: 900), item("C", .working, 1002, turn: 1002)], now: now)
    expect(MenuBarPresentation.focus(in: timeline.tracker.conversations)?.turnStartedAt == 1003, "Ordinary updates preserve inferred resume timestamp")
    expect(timeline.update([doneA, item("B", .waiting, 1005), item("C", .working, 1002, turn: 1002)], now: now).count == 1, "Running re-arms wait")

    var tracker = ConversationEventTracker()
    expect(tracker.update([waitingB], now: now).isEmpty, "Startup waits do not notify")
    expect(MenuBarPresentation.hasWaiting(in: tracker.conversations), "Startup waits still show marker")
    _ = tracker.update([item("B", .error, 1002)], now: now)
    expect(tracker.exitedWaiting == ["B"], "Error removes wait notification")
    expect(tracker.update([item("B", .waiting, 1003)], now: now).isEmpty, "Error-to-wait does not re-arm a wait")
    _ = tracker.update([item("B", .working, 1004)], now: now)
    expect(tracker.update([item("B", .unknown, 1005)], now: now).isEmpty, "Esc abort emits no completion or wait")
    expect(tracker.update([item("B", .completed, 1006)], now: now).isEmpty, "Aborted round never becomes success")
    _ = tracker.update([item("child", .working, 999, child: true)], now: now)
    expect(tracker.update([item("child", .waiting, 1000, child: true)], now: now).isEmpty, "Subagent waits are silent")
    expect(tracker.update([item("child", .completed, 1001, child: true)], now: now).isEmpty, "Subagent completions are silent")
    for end: AgentTaskPhase in [.thinking, .working, .completed, .error, .unknown, .idle] {
        var waiting = ConversationEventTracker()
        _ = waiting.update([waitingB], now: now)
        _ = waiting.update([item("B", end, 1002)], now: now)
        expect(waiting.exitedWaiting == ["B"], "Every waiting exit removes its delivered notification")
    }
    for (end, expected) in [(TimeInterval(880), true), (1060, true), (879, false), (1061, false), (800, false)] {
        var window = ConversationEventTracker()
        _ = window.update([item("A", .working, 800)], now: now)
        expect(!window.update([item("A", .completed, end)], now: now).isEmpty == expected, "Completion enforces timestamp advancement and -60...120s window")
    }

    var burst = MenuBarPresentation()
    _ = burst.update([a, b, item("C", .working, 950, turn: 900), item("D", .working, 951, turn: 901)], now: now)
    _ = burst.update([doneA, b, item("C", .working, 950, turn: 900), item("D", .working, 951, turn: 901)], now: now)
    let burstEvents = burst.update([doneA, waitingB, item("C", .waiting, 1002, turn: 900), item("D", .completed, 1003, turn: 901)], now: now)
    expect(burstEvents.count == 3, "All burst events notify even when animations are skipped")
    expect(burst.playing?.conversation.id == "A" && burst.pending.waiting?.conversation.id == "C" && burst.pending.completed?.conversation.id == "D", "Pending slot retains latest waiting and completion independently")
    burst.finishPlayback()
    expect(burst.playing?.conversation.id == "C" && burst.pending.waiting == nil && burst.pending.completed == nil, "A completes fully before latest waiting cue")
    burst.finishPlayback()
    expect(burst.emotion == .idle && burst.hasWaiting, "Wait cues never loop after a full cycle")
    let event = ConversationEvent(conversation: doneA, kind: .completed)
    let newer = ConversationEvent(conversation: item("D", .completed, 1003, turn: 901), kind: .completed)
    var pending = ConversationPendingEvents()
    pending.receive(event)
    pending.receive(newer)
    pending.receive(event)
    expect(pending.completed == newer, "Newest completion survives out-of-order arrivals")
    let pendingWait = ConversationEvent(conversation: waitingB, kind: .waiting)
    pending.receive(pendingWait)
    expect(pending.next(in: [waitingB, newer.conversation]) == pendingWait, "Valid waiting wins over a newer completion")
    expect(pending.next(in: [newer.conversation]) == newer, "Invalid waiting falls back to retained completion")
    expect(pending.next(in: [item("D", .completed, 1005, turn: 1004)]) == nil, "Invalid waiting and superseded completion both discard")
    let latestWait = ConversationEvent(conversation: item("C", .waiting, 1002, turn: 900), kind: .waiting)
    pending.receive(latestWait)
    pending.receive(pendingWait)
    expect(pending.waiting == latestWait, "Newest waiting survives out-of-order arrivals")
    expect(pending.next(in: [waitingB, newer.conversation]) == newer, "An invalid latest wait does not replay an older wait")
    var fallback = MenuBarPresentation()
    let runningD = item("D", .working, 951, turn: 901)
    _ = fallback.update([a, b, runningD], now: now)
    _ = fallback.update([doneA, b, runningD], now: now)
    _ = fallback.update([doneA, waitingB, newer.conversation], now: now)
    _ = fallback.update([doneA, item("B", .working, 1004, turn: 1004), newer.conversation], now: now)
    var bothInvalid = fallback
    _ = bothInvalid.update([doneA, item("B", .working, 1004, turn: 1004), item("D", .working, 1005, turn: 1005)], now: now)
    bothInvalid.finishPlayback()
    expect(bothInvalid.playing == nil && bothInvalid.displayedConversation?.id == "D", "Both invalid pending kinds return to focus")
    fallback.finishPlayback()
    expect(fallback.playing?.conversation.id == "D" && fallback.playing?.kind == .completed,
           "finishPlayback falls back to completion when retained wait has resumed")
    expect(fallback.pending.waiting == nil && fallback.pending.completed == nil, "Playback selection clears both pending kinds, not a queue")
    fallback.finishPlayback()
    expect(fallback.playing == nil && fallback.displayedConversation?.id == "B", "Fallback completion finishes then returns to focus")
    expect(event.isValid(in: [doneA]), "Pending completion stays valid in the same round")
    expect(!event.isValid(in: [item("A", .completed, 1005, turn: 1004)]), "Completion from an old round is discarded even if new round already completed")
    expect(!event.isValid(in: []), "Missing pending task is discarded")
    var invalidated = MenuBarPresentation()
    _ = invalidated.update([a, b], now: now)
    _ = invalidated.update([doneA, b], now: now)
    _ = invalidated.update([doneA, waitingB], now: now)
    _ = invalidated.update([doneA, item("B", .working, 1002)], now: now)
    invalidated.finishPlayback()
    expect(invalidated.playing == nil && invalidated.emotion == .working, "Resumed pending wait is discarded before playback")
    let waitingEvent = ConversationEvent(conversation: waitingB, kind: .waiting)
    expect(waitingEvent.notificationID == "B.waiting" && event.notificationID == "A.completed", "Notification identifiers are task.kind, not random")
    print("Menu bar rules: focus/resume, event windows, startup/subagent/abort suppression, two-kind pending fallback, validation, waiting marker and timeline passed")
}

func readsTurnStartSignals() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("signals.jsonl")
    let base = floor(Date().timeIntervalSince1970) - 100
    func line(_ type: String, _ payload: [String: Any], at offset: TimeInterval) throws -> Data {
        let stamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: base + offset))
        var data = try JSONSerialization.data(withJSONObject: ["timestamp": stamp, "type": type, "payload": payload])
        data.append(10)
        return data
    }
    try line("event_msg", ["type": "task_started"], at: 0).write(to: file)
    let fetcher = CodexSessionActivityFetcher(sessionsURL: root)
    var result = await fetcher.fetch(changedFiles: [file])
    expect(result.conversations.first?.turnStartedAt == base, "Codex task_started is an explicit turn signal")
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    let injectedContext: [String: Any] = ["type": "message", "role": "user", "content": [
        ["type": "input_text", "text": "<environment_context>task_started user_message reasoning</environment_context>"]
    ]]
    let steps: [(String, [String: Any], TimeInterval, TimeInterval)] = [
        ("response_item", ["type": "function_call", "name": "exec"], 1, 0),
        ("response_item", injectedContext, 2, 0),
        ("event_msg", ["type": "user_message", "message": "fixture"], 2, 2),
        ("response_item", ["type": "message", "role": "user"], 3, 2),
        ("event_msg", ["type": "turn_started"], 4, 4),
        ("response_item", ["type": "function_call", "name": "request_user_input"], 5, 4),
        ("response_item", injectedContext, 6, 4),
        ("response_item", ["type": "function_call_output"], 6, 6),
        ("response_item", ["type": "reasoning"], 7, 6),
        ("event_msg", ["type": "task_complete"], 8, 6),
        ("response_item", injectedContext, 9, 6),
    ]
    for (type, payload, offset, expectedStart) in steps {
        try handle.seekToEnd()
        try handle.write(contentsOf: line(type, payload, at: offset))
        let previous = result
        result = await fetcher.fetch(changedFiles: [file])
        if type == "response_item", payload["type"] as? String == "message" {
            expect(result == previous, "Response-item user messages, including injected environment context, preserve phase, timestamps and activity")
        }
        expect(result.conversations.first?.turnStartedAt == base + expectedStart, "Codex user/turn/resume signal advances only at the defined boundary")
        let cold = await CodexSessionActivityFetcher(sessionsURL: root).fetch(changedFiles: [file])
        expect(cold == result, "Codex cold and incremental turn timestamps agree")
    }
    var completions = ConversationEventTracker()
    _ = completions.update(result.conversations, now: Date(timeIntervalSince1970: base + 9))
    for turn in 0..<50 {
        let start = TimeInterval(10 + turn * 2)
        try handle.seekToEnd()
        try handle.write(contentsOf: line("event_msg", ["type": "task_started"], at: start)
            + line("event_msg", ["type": "task_complete"], at: start + 1))
        result = await fetcher.fetch(changedFiles: [file])
        let now = Date(timeIntervalSince1970: base + start + 1)
        let events = completions.update(result.conversations, now: now)
        expect(events.count == 1 && events.first?.kind == .completed, "Every coalesced rollout turn reaches notification delivery")
        expect(completions.update(result.conversations, now: now).isEmpty, "Repeated reads never duplicate fast completions")
    }
    print("Notifications: 50 coalesced Codex turns emitted exactly once each")
    for provider in CodingAgent.allCases {
        let url = root.appendingPathComponent(provider.rawValue + ".json")
        let store = AgentActivityStore(directory: root, home: root)
        let task = AgentTask(provider: provider, sessionID: "fixture", phase: .working,
                             updatedAt: base + 9, startedAt: base, turnStartedAt: base + 2)
        try JSONEncoder().encode(task).write(to: url)
        var snapshot = await store.fetch(changedFiles: [url])
        expect(snapshot.conversations.first?.turnStartedAt == base + 2, "Provider prompt timestamp survives hook/store/conversation mapping")
        let legacy = AgentTask(provider: provider, sessionID: "fixture", phase: .thinking,
                               updatedAt: base + 10, startedAt: base + 3)
        try JSONEncoder().encode(legacy).write(to: url)
        snapshot = await store.fetch(changedFiles: [url])
        expect(snapshot.conversations.first?.turnStartedAt == base + 3, "Existing hooks preserve their UserPromptSubmit startedAt signal without installation")
    }
    var fallback = ConversationEventTracker()
    let waiting = Conversation(id: "grok:fixture", provider: .grok, phase: .waiting, updatedAt: base + 10)
    _ = fallback.update([waiting])
    let resumed = Conversation(id: waiting.id, provider: .grok, phase: .working, updatedAt: base + 11)
    _ = fallback.update([resumed])
    expect(fallback.conversations.first?.turnStartedAt == base + 11, "Missing Grok prompt signal degrades to nonrunning-to-running timestamp")
    let explicit = Conversation(id: waiting.id, provider: .grok, phase: .working, updatedAt: base + 14, turnStartedAt: base + 12)
    _ = fallback.update([waiting])
    _ = fallback.update([explicit])
    expect(fallback.conversations.first?.turnStartedAt == base + 12, "Known prompt/resume time is not replaced by a later tool update")
    print("Turn signals: Codex user/turn/resume cold+incremental, Claude/Grok record compatibility and missing-prompt fallback passed")
}

func tracksCodexStartWithoutCompletionStealing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("fixture.jsonl")
    let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 10)
    let timestamp = ISO8601DateFormatter().string(from: start)
    let started = "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
    let completed = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n"
    try (started + completed).write(to: file, atomically: true, encoding: .utf8)
    let fetcher = CodexSessionActivityFetcher(sessionsURL: root)
    let initial = await fetcher.fetch(changedFiles: [file])
    expect(initial.conversations.first?.startedAt == start.timeIntervalSince1970 && !initial.hasActiveSession,
           "Cold start must recover last start even after completion")
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    let nextStart = started.replacingOccurrences(of: timestamp, with: ISO8601DateFormatter().string(from: start.addingTimeInterval(2)))
    try handle.write(contentsOf: Data(nextStart.utf8))
    let active = await fetcher.fetch(changedFiles: [file])
    expect(active.conversations.first?.startedAt == start.timeIntervalSince1970 + 2,
           "A new Codex turn resets the per-conversation duration start")
    expect(active.hasActiveSession && active.conversations.first?.startedAt == start.timeIntervalSince1970 + 2,
           "Incremental start parsing must retain the event timestamp")
    try handle.write(contentsOf: Data(completed.utf8))
    try handle.close()
    let idle = await fetcher.fetch(changedFiles: [file])
    expect(!idle.hasActiveSession && idle.conversations.first?.startedAt == active.conversations.first?.startedAt,
           "Completion must not change the start timestamp")
}

func formatsRunningDuration() {
    let now = Date(timeIntervalSince1970: 1_792_751_000)
    func conversation(_ age: Double?, phase: AgentTaskPhase = .working) -> Conversation {
        Conversation(id: "duration", phase: phase, updatedAt: now.timeIntervalSince1970,
                     startedAt: age.map { now.timeIntervalSince1970 - $0 })
    }
    for (seconds, text) in [(0.0, "不足 1 分钟"), (59, "不足 1 分钟"),
                            (60, "1 分钟"), (3599, "59 分钟"),
                            (3600, "1 小时"), (3660, "1 小时 1 分钟"),
                            (90_000, "25 小时")] {
        expect(conversation(seconds).runningDuration(at: now) == text, "Format elapsed time from turn start")
    }
    expect(conversation(120, phase: .thinking).runningDuration(at: now) == "2 分钟", "Thinking counts as running")
    for phase in [AgentTaskPhase.waiting, .completed, .error, .unknown, .idle] {
        expect(conversation(120, phase: phase).runningDuration(at: now) == nil, "Only running rows show duration")
    }
    for age in [nil, -60, Double.nan, Double.infinity] as [Double?] {
        expect(conversation(age).runningDuration(at: now) == nil, "Missing or invalid starts must not use last activity time")
    }
    let task = AgentTask(provider: .claude, sessionID: "duration", phase: .working,
                         updatedAt: now.timeIntervalSince1970, startedAt: now.timeIntervalSince1970 - 120)
    expect(AgentActivitySnapshot(tasks: [task]).conversations.first?.runningDuration(at: now) == "2 分钟",
           "CLI task start reaches its conversation independently of recent tool updates")
    print("Running duration: minute/hour boundaries, missing starts, phases and CLI mapping passed")
}

func readsClaudeQuota() throws {
    let now = Date(timeIntervalSince1970: 1_792_751_000)
    let payload = Data(#"{"five_hour":{"utilization":84,"resets_at":"2026-10-23T13:40:00.795502+00:00"},"seven_day":{"utilization":33,"resets_at":"2026-10-29T14:00:00Z"},"seven_day_opus":null}"#.utf8)
    let snapshot = try ClaudeUsageSnapshot.decode(from: payload, fetchedAt: now)
    expect(snapshot.fiveHour?.roundedRemainingPercent == 16, "Claude utilization is used, not remaining percent")
    expect(snapshot.weekly?.roundedRemainingPercent == 67, "Claude weekly quota must remain separate from Codex")
    expect(snapshot.fiveHour?.windowMinutes == 300 && snapshot.weekly?.windowMinutes == 10_080,
        "Claude quota durations should match their API fields")
    expect(snapshot.fiveHour?.resetsAt != nil && snapshot.weekly?.resetsAt != nil,
        "Both fractional and whole-second ISO dates should decode")
    expect(snapshot.fetchedAt == now, "Claude timestamp should track the successful fetch")
    let partial = try ClaudeUsageSnapshot.decode(from: Data(#"{"five_hour":null,"seven_day":{"utilization":0,"resets_at":null}}"#.utf8))
    expect(partial.fiveHour == nil && partial.weekly?.roundedRemainingPercent == 100,
        "Missing windows must not turn into invented quota")
    let exhausted = try ClaudeUsageSnapshot.decode(from: Data(#"{"five_hour":{"utilization":100},"seven_day":null}"#.utf8))
    expect(exhausted.fiveHour?.roundedRemainingPercent == 0, "Exhausted Claude quota should show zero")
    func rejects(_ action: () throws -> Void, _ message: String) {
        do { try action(); expect(false, message) } catch { }
    }
    for invalid in ["{}", "broken", #"{"five_hour":{"utilization":-1}}"#,
                    #"{"five_hour":{"utilization":101}}"#, #"{"five_hour":{"utilization":"84"}}"#,
                    #"{"five_hour":{"utilization":10,"resets_at":"tomorrow"}}"#] {
        rejects({ _ = try ClaudeUsageSnapshot.decode(from: Data(invalid.utf8)) }, "Reject malformed Claude data")
    }
    let request = try ClaudeUsageFetcher.request(credentials: Data(#"{"claudeAiOauth":{"accessToken":"fixture-token","expiresAt":2000000000000}}"#.utf8), now: now)
    expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage", "Send Claude credentials only to the fixed usage endpoint")
    expect(request.httpMethod == "GET" && request.httpBody == nil, "Quota fetch must not upload activity")
    expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token", "Use Claude OAuth, not API billing")
    expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20", "Use Claude OAuth protocol header")
    expect(request.timeoutInterval == 20, "Claude fetch should have a bounded timeout")
    for invalid in ["{}", "broken", #"{"claudeAiOauth":{"accessToken":""}}"#,
                    #"{"claudeAiOauth":{"accessToken":"bad\ntoken"}}"#,
                    #"{"claudeAiOauth":{"accessToken":"fixture","expiresAt":1}}"#] {
        rejects({ _ = try ClaudeUsageFetcher.request(credentials: Data(invalid.utf8), now: now) }, "Reject absent, expired or unsafe credentials")
    }
    for status in [0, 302, 401, 403, 429, 500] {
        rejects({ _ = try ClaudeUsageFetcher.snapshot(data: payload, statusCode: status) }, "HTTP errors must never become quota")
    }
    expect(ClaudeUsageFetcher.retryDate(retryAfter: "120", now: now) == now.addingTimeInterval(120),
           "429 cooldown respects Retry-After seconds")
    let future = now.addingTimeInterval(3600)
    let httpDate = DateFormatter()
    httpDate.locale = Locale(identifier: "en_US_POSIX")
    httpDate.timeZone = TimeZone(secondsFromGMT: 0)
    httpDate.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    expect(ClaudeUsageFetcher.retryDate(retryAfter: httpDate.string(from: future), now: now) == future,
           "429 cooldown respects HTTP-date Retry-After")
    for invalid in [nil, "", "garbage", "-1", "0", "inf", "NaN", "1e309", httpDate.string(from: now.addingTimeInterval(-60))] {
        expect(ClaudeUsageFetcher.retryDate(retryAfter: invalid, now: now) == now.addingTimeInterval(600),
               "Missing or invalid Retry-After defaults to ten minutes")
    }
    do {
        _ = try ClaudeUsageFetcher.snapshot(data: payload, statusCode: 429, retryAfter: "120", now: now)
        expect(false, "429 must fail even with a valid quota body")
    } catch ClaudeUsageFetchError.rateLimited(let until) {
        expect(until == now.addingTimeInterval(120), "Typed 429 error carries the cooldown deadline")
        expect(ClaudeUsageFetchError.rateLimited(until: until).localizedDescription.contains("429"),
               "Rate-limit message preserves the HTTP status")
    }
    let success = try ClaudeUsageFetcher.snapshot(data: payload, statusCode: 200)
    expect(success.fiveHour?.roundedRemainingPercent == 16, "Only successful HTTP quota should be displayed")
    for output in [Data(), Data(repeating: 32, count: 1_048_577)] {
        rejects({ _ = try ClaudeUsageFetcher.request(credentials: output) },
                "Credential requests reject empty and oversized data")
    }
    expect(ClaudeUsageFetchError.keychainFailed(-25293).localizedDescription.contains("认证失败"),
           "Keychain authentication failure must not be mislabeled as a locked keychain")
    expect(ClaudeUsageFetchError.keychainFailed(-128).localizedDescription.contains("已取消"),
           "Cancelled keychain consent should offer retry, not an unlock instruction")
    expect(ClaudeUsageFetchError.keychainFailed(-50).localizedDescription.contains("-50"),
           "Unexpected keychain failures preserve the OS status for diagnosis")
    print("Claude quota: windows, dates, missing/invalid data, OAuth request, expiry and HTTP errors passed")
}

final class ClaudeCacheFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var token = "fixture-a"
    private var failure: ClaudeUsageFetchError?
    private var credentialFailure: ClaudeUsageFetchError?
    private var expiry: Double?
    private var count = 0
    private var interactions: [Bool] = []
    var credentialReads: [Bool] { lock.withLock { interactions } }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    var requests: Int { lock.withLock { count } }
    func configure(token: String = "fixture-a", failure: ClaudeUsageFetchError? = nil,
                   credentialFailure: ClaudeUsageFetchError? = nil, expiry: Double? = nil) {
        lock.withLock {
            self.token = token; self.failure = failure
            self.credentialFailure = credentialFailure; self.expiry = expiry
        }
    }
    var revision: Data { lock.withLock { Data(token.utf8) } }
    func credentials(allowInteraction: Bool) throws -> Data {
        try lock.withLock {
            interactions.append(allowInteraction)
            if let credentialFailure { throw credentialFailure }
            let expires = expiry.map { ",\"expiresAt\":\($0)" } ?? ""
            return Data("{\"claudeAiOauth\":{\"accessToken\":\"\(token)\"\(expires)}}".utf8)
        }
    }
    func load() throws -> ClaudeUsageSnapshot {
        try lock.withLock {
            count += 1
            if let failure { throw failure }
            return try ClaudeUsageSnapshot.decode(from: Data(#"{"five_hour":{"utilization":25}}"#.utf8), fetchedAt: now)
        }
    }
}

func cachesClaudeQuotaAndCooldown() async throws {
    let suite = "ClaudeUsageTests." + UUID().uuidString
    let fixture = ClaudeCacheFixture()
    func fetcher() -> ClaudeUsageFetcher {
        ClaudeUsageFetcher(defaults: UserDefaults(suiteName: suite)!,
                           credentials: { try fixture.credentials(allowInteraction: $0) }, credentialRevision: { nil }, loader: { _ in
            try await Task.sleep(for: .milliseconds(20))
            return try fixture.load()
        })
    }
    defer { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
    let client = fetcher()
    let now = fixture.now
    do {
        _ = try await client.fetch(now: now, allowInteraction: true)
        expect(false, "Explicit interaction still requires app consent")
    } catch ClaudeUsageFetchError.connectionRequired {}
    expect(fixture.requests == 0 && fixture.credentialReads.isEmpty, "Unconnected Claude must not read credentials or query quota")
    UserDefaults(suiteName: suite)!.set(true, forKey: ClaudeUsageFetcher.consentKey)
    async let first = client.fetch(now: now, allowInteraction: true)
    async let concurrent = client.fetch(now: now, allowInteraction: true)
    let (snapshot, other) = try await (first, concurrent)
    expect(snapshot == other && fixture.requests == 1, "Concurrent Claude refreshes share one request")
    let hit = try await client.fetch(now: now.addingTimeInterval(899))
    expect(hit == snapshot && fixture.requests == 1, "Successful quota is cached for fifteen minutes")
    expect(fixture.credentialReads == [true, false], "Only explicit connection allows credential interaction; refresh is silent")
    fixture.configure(failure: .requestFailed(500))
    let stale = try await client.fetch(now: now.addingTimeInterval(900))
    expect(stale == snapshot && fixture.requests == 2, "Transient failures retain the original quota timestamp")
    let until = now.addingTimeInterval(3600)
    fixture.configure(failure: .rateLimited(until: until))
    let limited = try await client.fetch(now: now.addingTimeInterval(901))
    expect(limited == snapshot && fixture.requests == 3, "429 retains same-credential stale data")
    _ = try await client.fetch(now: now.addingTimeInterval(902))
    expect(fixture.requests == 3, "Cooldown blocks subsequent manual refreshes")
    let cooldownKeys = UserDefaults(suiteName: suite)!.dictionaryRepresentation().keys
        .filter { $0.hasPrefix("claudeUsageRetryAfter.") }
    expect(cooldownKeys.count == 1 && !cooldownKeys[0].contains("fixture-a"),
           "Persisted cooldown keys contain only a credential fingerprint")
    let restarted = fetcher()
    do {
        _ = try await restarted.fetch(now: now.addingTimeInterval(903))
        expect(false, "Restarted fetcher must honor persisted cooldown")
    } catch ClaudeUsageFetchError.rateLimited(let retry) {
        expect(retry == until && fixture.requests == 3, "Cooldown survives fetcher recreation")
    }
    fixture.configure(token: "fixture-b", failure: .requestFailed(500))
    do {
        _ = try await client.fetch(now: now.addingTimeInterval(904))
        expect(false, "A new account must not receive old-account quota or cooldown")
    } catch ClaudeUsageFetchError.requestFailed(500) {}
    expect(fixture.requests == 4, "Cooldown is isolated by credential fingerprint")
    fixture.configure(token: "fixture-b")
    _ = try await client.fetch(now: now.addingTimeInterval(905))
    fixture.configure(token: "fixture-b", failure: .loginRequired)
    do {
        _ = try await client.fetch(now: now.addingTimeInterval(906))
        expect(false, "Authentication errors invalidate cached quota")
    } catch ClaudeUsageFetchError.loginRequired {}
    fixture.configure(token: "fixture-b", failure: .requestFailed(500))
    do {
        _ = try await client.fetch(now: now.addingTimeInterval(907))
        expect(false, "Quota invalidated by authentication must not return on a later network failure")
    } catch ClaudeUsageFetchError.requestFailed(500) {}
    fixture.configure()
    _ = try await restarted.fetch(now: until)
    expect(fixture.requests == 8, "Requests resume at the cooldown deadline")
    fixture.configure(token: "")
    do {
        _ = try await restarted.fetch(now: now.addingTimeInterval(1))
        expect(false, "Invalid credentials must not reuse fresh cached quota")
    } catch ClaudeUsageFetchError.loginRequired {}
    expect(fixture.requests == 8, "Invalid credentials never trigger a usage request")
    let stored = UserDefaults(suiteName: suite)!.dictionaryRepresentation()
    expect(!stored.keys.contains { $0.hasPrefix("claudeUsageRetryAfter.") }, "Successful retry clears persisted cooldown")
    let readsBeforeDisconnect = fixture.credentialReads.count
    UserDefaults(suiteName: suite)!.set(false, forKey: ClaudeUsageFetcher.consentKey)
    do {
        _ = try await client.fetch(now: now)
        expect(false, "Disconnect must block even cached quota")
    } catch ClaudeUsageFetchError.connectionRequired {}
    expect(fixture.requests == 8 && fixture.credentialReads.count == readsBeforeDisconnect, "Disconnect must block credential reads and network requests")
    print("Claude cache: consent, disconnect, TTL, concurrent refreshes, stale data, persistent cooldown, account isolation and auth invalidation passed")
}

func cachesClaudeCredentialsWithoutRepeatingConsent() async throws {
    let suite = "ClaudeCredentialTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: ClaudeUsageFetcher.consentKey)
    let fixture = ClaudeCacheFixture()
    let now = fixture.now
    let client = ClaudeUsageFetcher(defaults: UserDefaults(suiteName: suite)!,
        credentials: { try fixture.credentials(allowInteraction: $0) },
        credentialRevision: { fixture.revision }, loader: { _ in try fixture.load() })
    _ = try await client.fetch(now: now, allowInteraction: true)
    fixture.configure(credentialFailure: .keychainLocked)
    _ = try await client.fetch(now: now.addingTimeInterval(900))
    expect(fixture.credentialReads == [true] && fixture.requests == 2,
           "Background quota refresh reuses credentials without a second Keychain payload read")
    do {
        _ = try await client.fetch(now: now.addingTimeInterval(1800))
        expect(false, "Credential cache is bounded to thirty minutes even without token expiry")
    } catch ClaudeUsageFetchError.keychainLocked {}
    expect(defaults.bool(forKey: ClaudeUsageFetcher.consentKey), "Keychain failure preserves app consent")
    fixture.configure(token: "account-b")
    _ = try await client.fetch(now: now.addingTimeInterval(1801))
    let beforeRepair = fixture.credentialReads.count
    _ = try await client.fetch(now: now.addingTimeInterval(1802), allowInteraction: true)
    expect(fixture.credentialReads.count == beforeRepair + 1,
           "Explicit repair rereads credentials even while their revision is unchanged")
    fixture.configure(token: "account-c", credentialFailure: .keychainLocked)
    do {
        _ = try await client.fetch(now: now.addingTimeInterval(1803))
        expect(false, "Changed source must never reuse another account's cached credentials or quota")
    } catch ClaudeUsageFetchError.keychainLocked {}
    fixture.configure(token: "account-c", failure: .loginRequired)
    do {
        _ = try await client.fetch(now: now.addingTimeInterval(1804))
        expect(false, "401 invalidates credentials")
    } catch ClaudeUsageFetchError.loginRequired {}
    fixture.configure(token: "account-c", credentialFailure: .keychainLocked)
    do {
        _ = try await client.fetch(now: now.addingTimeInterval(1805))
        expect(false, "401 must discard even an unexpired credential cache")
    } catch ClaudeUsageFetchError.keychainLocked {}
    fixture.configure(token: "account-c", failure: .requestFailed(403))
    do {
        _ = try await client.fetch(now: now.addingTimeInterval(1806))
        expect(false, "403 preserves its distinct error type")
    } catch ClaudeUsageFetchError.requestFailed(403) {}
    expect(defaults.bool(forKey: ClaudeUsageFetcher.consentKey), "HTTP failures never revoke app consent")
    fixture.configure(token: "expiring", expiry: now.addingTimeInterval(1810).timeIntervalSince1970 * 1000)
    _ = try await client.fetch(now: now.addingTimeInterval(1807))
    do {
        _ = try await client.fetch(now: now.addingTimeInterval(1810))
        expect(false, "Expired credential cache must not bypass expiry validation")
    } catch ClaudeUsageFetchError.loginRequired {}
    fixture.configure(token: "final")
    _ = try await client.fetch(now: now.addingTimeInterval(1811))
    await client.clearCache()
    let reads = fixture.credentialReads.count
    _ = try await client.fetch(now: now.addingTimeInterval(1812))
    expect(fixture.credentialReads.count == reads + 1, "Disconnect cleanup discards cached secrets")
    do {
        _ = try ClaudeUsageFetcher.snapshot(data: Data(), statusCode: 403)
        expect(false, "403 must not be treated as a successful response")
    } catch ClaudeUsageFetchError.requestFailed(403) {}
    print("Claude credentials: silent cache, TTL, source changes, manual repair, expiry, consent, 401/403 and disconnect passed")
}

func aggregatesCodexMenuAnimationPhases() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
    let now = Date()
    let folder = root.appendingPathComponent(formatter.string(from: now))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let first = folder.appendingPathComponent("first.jsonl")
    let second = folder.appendingPathComponent("second.jsonl")
    let timestamp = ISO8601DateFormatter().string(from: now)
    func event(_ type: String) -> String { "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\"}}\n" }
    func tool(_ name: String) -> String { "{\"timestamp\":\"\(timestamp)\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"\(name)\"}}\n" }
    func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
    try event("task_started").write(to: first, atomically: true, encoding: .utf8)
    let fetcher = CodexSessionActivityFetcher(sessionsURL: root)
    var result = await fetcher.fetch(now: now)
    expect(MenuBarPresentation.focus(in: result.conversations)?.phase == .thinking, "Codex start maps thinking into the menu")
    try append(tool("functions.request_user_input"), to: first)
    result = await fetcher.fetch(changedFiles: [first], now: now)
    expect(MenuBarPresentation.focus(in: result.conversations) == nil && result.conversations.first?.phase == .waiting, "Waiting is an event, not persistent menu focus")
    try append(tool("functions.exec"), to: first)
    result = await fetcher.fetch(changedFiles: [first], now: now)
    expect(MenuBarPresentation.focus(in: result.conversations)?.phase == .working, "Codex tool calls map working into the menu")
    let startedAt = result.conversations.first?.startedAt
    try append(event("task_complete"), to: first)
    result = await fetcher.fetch(changedFiles: [first], now: now)
    expect(MenuBarPresentation.focus(in: result.conversations) == nil && result.activeThreadCount == 0, "Completion cue comes from observed events, not an aggregate state")
    expect(result.conversations.first?.startedAt == startedAt && result.loadedThreadCount == 1, "Completion preserves selection timestamps and loaded count")
    let expired = await fetcher.fetch(changedFiles: [], now: now.addingTimeInterval(3))
    expect(MenuBarPresentation.focus(in: expired.conversations) == nil && expired.conversations == result.conversations, "Snapshots do not replay completed actions as time passes")
    try (event("task_started") + tool("functions.exec")).write(to: second, atomically: true, encoding: .utf8)
    result = await fetcher.fetch(changedFiles: [second], now: now)
    expect(MenuBarPresentation.focus(in: result.conversations)?.phase == .working && result.activeThreadCount == 1, "Concurrent work outranks completion")
    try append(event("task_started"), to: first)
    result = await fetcher.fetch(changedFiles: [first], now: now)
    expect(result.activeThreadCount == 2, "Concurrent turns remain independently running")
    try append(tool("functions.request_user_input"), to: first)
    result = await fetcher.fetch(changedFiles: [first], now: now)
    expect(MenuBarPresentation.focus(in: result.conversations)?.phase == .working, "Waiting never hides another running task")
    try append(event("turn_aborted"), to: first)
    result = await fetcher.fetch(changedFiles: [first], now: now)
    expect(MenuBarPresentation.focus(in: result.conversations)?.phase == .working, "Other live work outranks an aborted unknown turn")
    try append(event("task_complete"), to: second)
    result = await fetcher.fetch(changedFiles: [second], now: now)
    expect(MenuBarPresentation.focus(in: result.conversations) == nil && result.conversations.contains { $0.phase == .unknown }, "Aborted attention never becomes completion or focus")
    let cold = await CodexSessionActivityFetcher(sessionsURL: root).fetch(now: now)
    expect(cold == result, "Cold and incremental conversation states agree")
}

func readsCustomToolConversationPhases() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
    let now = Date()
    let folder = root.appendingPathComponent(formatter.string(from: now))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let first = folder.appendingPathComponent("first.jsonl")
    let second = folder.appendingPathComponent("second.jsonl")
    func line(_ type: String, _ payload: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "timestamp": ISO8601DateFormatter().string(from: now), "type": type, "payload": payload,
        ])
        data.append(10)
        return data
    }
    let started = try line("event_msg", ["type": "task_started"])
    try started.write(to: first)
    try started.write(to: second)
    let fetcher = CodexSessionActivityFetcher(sessionsURL: root)
    _ = await fetcher.fetch(now: now)
    let handle = try FileHandle(forWritingTo: first)
    defer { try? handle.close() }
    let steps: [(String, [String: Any], AgentTaskPhase)] = [
        ("response_item", ["type": "custom_tool_call", "name": "exec", "status": "completed"], .working),
        ("response_item", ["type": "custom_tool_call_output", "output": "task_complete"], .thinking),
        ("response_item", ["type": "custom_tool_call", "name": "functions.request_user_input"], .waiting),
        ("response_item", ["type": "custom_tool_call_output"], .thinking),
        ("response_item", ["type": "function_call", "name": "functions.exec"], .working),
        ("response_item", ["type": "function_call_output"], .thinking),
        ("event_msg", ["type": "task_complete"], .completed),
        ("event_msg", ["type": "task_started"], .thinking),
        ("event_msg", ["type": "turn_aborted"], .unknown),
    ]
    for (type, payload, phase) in steps {
        try handle.seekToEnd()
        try handle.write(contentsOf: line(type, payload))
        let result = await fetcher.fetch(changedFiles: [first], now: now)
        expect(result.conversations.first { $0.id == "codex:" + first.path }?.phase == phase,
               "Real tool/turn event maps to \(phase)")
        expect(result.conversations.first { $0.id == "codex:" + second.path }?.phase == .thinking,
               "One conversation event never changes another conversation")
        let cold = await CodexSessionActivityFetcher(sessionsURL: root).fetch(now: now)
        expect(cold == result, "Cold and incremental custom-tool states agree at \(phase)")
    }
}

func readsConversationMetadataAndPhases() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions")
    let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
    let folder = sessions.appendingPathComponent(formatter.string(from: Date()))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("fixture.jsonl")
    let index = root.appendingPathComponent("session_index.jsonl")
    try Data(#"{"id":"fixture","thread_name":"修复登录"}"#.utf8).write(to: index)
    let timestamp = ISO8601DateFormatter().string(from: Date())
    func event(_ type: String) -> String { "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\"}}\n" }
    try ("{\"type\":\"session_meta\",\"payload\":{\"id\":\"fixture\",\"cwd\":\"/work/upkin\",\"originator\":\"Codex Desktop\",\"source\":\"vscode\"}}\n" + event("task_started"))
        .write(to: file, atomically: true, encoding: .utf8)
    let fetcher = CodexSessionActivityFetcher(sessionsURL: sessions)
    var result = await fetcher.fetch()
    expect(result.conversations.first?.title == "修复登录" && result.conversations.first?.project == "upkin", "Read real index title and metadata cwd")
    expect(result.conversations.first?.phase == .thinking, "Start means thinking, not invented tool activity")
    expect(result.conversations.first?.source == .desktop, "Rollout retains desktop source")
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    func append(_ text: String) throws { try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8)) }
    try append("{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"functions.request_user_input\"}}\n")
    result = await fetcher.fetch(changedFiles: [file])
    expect(result.conversations.first?.group == .attention && result.conversations.first?.emotion == .waiting, "Explicit user-input call belongs in attention")
    try append("{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\"}}\n")
    result = await fetcher.fetch(changedFiles: [file])
    expect(result.conversations.first?.group == .running, "Input response resumes thinking")
    try append(event("task_complete"))
    result = await fetcher.fetch(changedFiles: [file])
    expect(result.conversations.first?.group == .completed && result.activeThreadCount == 0, "Explicit completion retained per conversation")
    let cold = await CodexSessionActivityFetcher(sessionsURL: sessions).fetch()
    expect(cold == result, "Cold and incremental parsing must agree")
    try append(event("turn_aborted"))
    result = await fetcher.fetch(changedFiles: [file])
    expect(result.conversations.first?.phase == .unknown, "Aborted is not successful completion")
    try Data(#"{"id":"fixture","thread_name":"新标题"}"#.utf8).write(to: index, options: .atomic)
    result = await fetcher.fetch(changedFiles: [])
    expect(result.conversations.first?.title == "新标题", "Index-only rename updates cached conversation")

    var database: OpaquePointer?
    let databaseURL = root.appendingPathComponent("state_5.sqlite")
    expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK, "Create metadata fixture")
    defer { sqlite3_close(database) }
    func sql(_ text: String) {
        expect(sqlite3_exec(database, text, nil, nil, nil) == SQLITE_OK, "Update metadata fixture")
    }
    sql("CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT)")
    sql("INSERT INTO threads VALUES ('fixture', '桌面会话名称', 'PRIVATE FIRST PROMPT')")
    result = await fetcher.fetch(changedFiles: [])
    expect(result.conversations.first?.title == "桌面会话名称", "Desktop name takes precedence over stale JSONL index")
    sql("UPDATE threads SET name = '重命名后的会话'")
    result = await fetcher.fetch(changedFiles: [])
    expect(result.conversations.first?.title == "重命名后的会话", "Database-only rename updates without rereading rollout")
    sql("UPDATE threads SET name = NULL")
    result = await fetcher.fetch(changedFiles: [])
    expect(result.conversations.first?.title == "新标题", "Missing desktop name falls back to index, never first prompt")
    sql("ALTER TABLE threads RENAME COLUMN name TO legacy_name")
    result = await fetcher.fetch(changedFiles: [])
    expect(result.conversations.first?.title == "新标题", "Older database schemas retain index titles")
    for (id, source, title) in [
        ("exec", #""exec""#, "Codex 命令行任务"),
        ("child'quoted", #"{"subagent":{"thread_spawn":{"agent_nickname":"Hilbert"}}}"#, "子代理 · Hilbert")
    ] {
        let taskFile = folder.appendingPathComponent(id + ".jsonl")
        try ("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"source\":\(source)}}\n" + event("task_started"))
            .write(to: taskFile, atomically: true, encoding: .utf8)
        result = await fetcher.fetch(changedFiles: [taskFile])
        expect(result.conversations.first { $0.id == "codex:" + id }?.title == title,
               "Identify untitled CLI and child sessions from metadata, not prompt text")
        expect(result.conversations.first { $0.id == "codex:" + id }?.isSubagent == (id == "child'quoted"), "Keep subagent metadata for notification suppression")
    }

    for parentAtTop in [false, true] {
        let taskFile = folder.appendingPathComponent("tree-child.jsonl")
        let parentField = parentAtTop ? ",\"parent_thread_id\":\"fixture\"" : ""
        let spawn = parentAtTop ? "{}" : #"{"parent_thread_id":"fixture"}"#
        let metadata = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"tree-child\",\"source\":{\"subagent\":{\"thread_spawn\":\(spawn)}}\(parentField)}}\n"
        // v2 rollouts can include inherited session_meta; the first record owns the child identity.
        try (metadata + "{\"type\":\"session_meta\",\"payload\":{\"id\":\"fixture\",\"source\":\"exec\"}}\n" + event("task_started"))
            .write(to: taskFile, atomically: true, encoding: .utf8)
        let treeResult = await CodexSessionActivityFetcher(sessionsURL: sessions).fetch()
        expect(treeResult.conversations.first { $0.id == "codex:tree-child" }?.parentConversationID == "codex:fixture",
               "Read parent from top-level or spawn metadata without using inherited session identity")
    }

    try Data(#"{"id":"fixture","thread_name":"Codex Companion Task: <task> PRIVATE TASK"}"#.utf8)
        .write(to: index, options: .atomic)
    result = await fetcher.fetch(changedFiles: [])
    expect(result.conversations.first { $0.id == "codex:fixture" }?.title == "Codex 辅助任务",
           "Internal companion wrappers must not expose task payloads as titles")

    let activity = root.appendingPathComponent("activity")
    let claude = root.appendingPathComponent(".claude/projects/work")
    let grok = root.appendingPathComponent(".grok/sessions/work/grok-session")
    for dir in [activity, claude, grok] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    try Data("{\"type\":\"user\",\"sessionId\":\"claude-session\",\"cwd\":\"/work/backend\"}\n{\"type\":\"ai-title\",\"sessionId\":\"claude-session\",\"aiTitle\":\"补充测试\"}\n".utf8)
        .write(to: claude.appendingPathComponent("claude-session.jsonl"))
    try Data(#"{"info":{"id":"grok-session","cwd":"/work/payments"},"generated_title":"支付流程"}"#.utf8).write(to: grok.appendingPathComponent("summary.json"))
    for (provider, id) in [(CodingAgent.claude, "claude-session"), (.grok, "grok-session")] {
        try JSONEncoder().encode(AgentTask(provider: provider, sessionID: id, phase: .working, updatedAt: Date().timeIntervalSince1970))
            .write(to: activity.appendingPathComponent(id + ".json"))
    }
    let agent = await AgentActivityStore(directory: activity, home: root).fetch()
    expect(Set(agent.conversations.compactMap(\.title)) == ["补充测试", "支付流程"], "Enrich existing hook records without writing hooks")
    expect(Set(agent.conversations.compactMap(\.project)) == ["backend", "payments"], "Read project folders for both CLI providers")
    let missing = Conversation(id: "missing", cwd: "relative", phase: .unknown, updatedAt: 0)
    expect(missing.displayTitle == "未命名会话" && missing.project == nil && missing.group == .attention, "Missing metadata must not be guessed")
    expect(Conversation(id: "idle", phase: .idle, updatedAt: 0).group == nil, "Idle records do not clutter recent work")
}



func limitsCompletedConversations() {
    let completed = (0..<14).map { index in
        Conversation(id: "done-\(index)", provider: index % 2 == 0 ? .claude : nil,
                     phase: .completed, updatedAt: Double(index))
    }
    let active = [Conversation(id: "running", phase: .working, updatedAt: 0),
                  Conversation(id: "waiting", phase: .waiting, updatedAt: 0)]
    let visible = Conversation.visible(completed.reversed() + active)
    expect(visible.filter { $0.phase == .completed }.map(\.id) == (4..<14).reversed().map { "done-\($0)" },
           "Show only the ten most recent completed sessions across providers")
    expect(visible.filter { $0.phase != .completed } == active, "Keep all running and attention rows")
    expect(Conversation.visible(Array(completed.prefix(2))).count == 2, "Keep short completion lists")
    expect(Conversation.visible([Conversation(id: "idle", phase: .idle, updatedAt: 20)]).isEmpty,
           "Idle sessions stay hidden")
}


func buildsConversationTree() {
    let root = Conversation(id: "codex:root", phase: .completed, updatedAt: 1, source: .desktop)
    let child = Conversation(id: "codex:child", phase: .working, updatedAt: 3,
                             isSubagent: true, parentConversationID: root.id)
    let grandchild = Conversation(id: "codex:grandchild", phase: .waiting, updatedAt: 4,
                                  isSubagent: true, parentConversationID: child.id)
    let other = Conversation(id: "claude:other", provider: .claude, phase: .working, updatedAt: 2)
    let items = [grandchild, child, other, root]
    let rows = Conversation.tree(items)
    expect(rows.map { $0.conversation.id } == [root.id, child.id, grandchild.id, other.id], "Order families by their latest descendant, keeping parent first")
    expect(rows.map(\.depth) == [0, 1, 2, 0], "Nested agents keep tree depth")
    expect(rows.map(\.group) == [.attention, .attention, .attention, .running], "Waiting child promotes entire tree without splitting it")
    expect(rows[0].conversation.phase == .completed, "Grouping never changes a parent's real phase")
    expect(Conversation.tree(items + [root, child]).count == rows.count, "Repeated session IDs render only once")
    expect(grandchild.launchTarget(in: items) == root, "Nested children resume their root and retain its desktop route")
    expect(other.launchTarget(in: items) == other, "Other providers retain their launch target")
    expect(child.launchTarget(in: [child]) == nil, "Missing parents never resume a child directly")
    let orphan = Conversation.tree([child])
    expect(orphan.count == 1 && orphan[0].depth == 0, "Missing parents do not hide active children")
    let completed = (0..<12).map { Conversation(id: "done-\($0)", phase: .completed, updatedAt: Double($0 + 10)) }
    expect(Conversation.tree(completed + [root, child]).contains { $0.conversation == root }, "Keep old parent beyond completion limit when its child is visible")
    let cycleA = Conversation(id: "codex:a", phase: .working, updatedAt: 0, isSubagent: true, parentConversationID: "codex:b")
    let cycleB = Conversation(id: "codex:b", phase: .waiting, updatedAt: 0, isSubagent: true, parentConversationID: "codex:a")
    expect(Conversation.tree([cycleA, cycleB]).count == 2, "Cycles terminate and display each task once")
    expect(cycleA.launchTarget(in: [cycleA, cycleB]) == nil, "Cycles never launch arbitrary children")
    let legacy = Conversation(id: "codex:legacy", phase: .working, updatedAt: 0, isSubagent: true)
    expect(legacy.launchTarget(in: [legacy]) == nil, "Legacy child without parent metadata stays read-only")
}

func retainsWholeConversationFamilies() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
    func write(_ id: String, parent: String? = nil, age: TimeInterval, completed: Bool = false) throws -> URL {
        let date = now.addingTimeInterval(-age)
        let folder = root.appendingPathComponent(formatter.string(from: date))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(id + ".jsonl")
        var meta: [String: Any] = ["id": id, "cwd": "/work/same-project", "source": "exec"]
        if let parent {
            meta["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": parent, "agent_nickname": id]]]
        }
        var data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": meta])
        data.append(Data("\n".utf8))
        for type in completed ? ["task_started", "task_complete"] : ["task_started"] {
            data.append(try JSONSerialization.data(withJSONObject: ["timestamp": ISO8601DateFormatter().string(from: date),
                "type": "event_msg", "payload": ["type": type]]))
            data.append(Data("\n".utf8))
        }
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        return file
    }
    let parent = try write("parent", age: 25 * 3600)
    _ = try write("child", parent: "parent", age: 0)
    _ = try write("sibling", parent: "parent", age: 7200, completed: true)
    _ = try write("grandchild", parent: "sibling", age: 7000)
    _ = try write("unrelated-old-running", age: 7200)
    _ = try write("independent", age: 0, completed: true)
    let fetcher = CodexSessionActivityFetcher(sessionsURL: root)
    let result = await fetcher.fetch(now: now)
    expect(result.activeThreadCount == 1 && result.loadedThreadCount == 2, "Historical relatives do not inflate activity counts")
    let rows = Conversation.tree(result.conversations)
    expect(rows.count == 5, "Retain yesterday's parent and old descendants, excluding unrelated stale work")
    expect(rows.first { $0.conversation.id == "codex:child" }?.depth == 1, "Fresh child attaches to old parent")
    expect(rows.first { $0.conversation.id == "codex:grandchild" }?.depth == 2, "Keep old nested descendants")
    let old = rows.first { $0.conversation.id == "codex:parent" }!.conversation
    expect(old.isStale && old.runningDuration(at: now) == nil && old.group == nil && old.emotion == .unknown,
           "Expired work is context, not confirmed completion or live activity")
    expect(result.conversations.first { $0.id == "codex:child" }?.launchTarget(in: result.conversations)?.id == old.id,
           "Historical parent remains the launch target")
    let unchanged = await fetcher.fetch(changedFiles: [], now: now)
    expect(unchanged == result, "Cached history retains the same tree")
    let expired = await fetcher.fetch(changedFiles: [], now: now.addingTimeInterval(3601))
    expect(expired.activeThreadCount == 0 && expired.loadedThreadCount == 0 && !expired.hasActiveSession
           && expired.conversations.allSatisfy { $0.startedAt == nil }, "History never revives activity or character selection after expiry")
    let cold = await CodexSessionActivityFetcher(sessionsURL: root).fetch(now: now.addingTimeInterval(3601))
    expect(cold == expired, "Cold and incremental history agree across activity expiry")
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: parent.path)
    let revived = await fetcher.fetch(changedFiles: [parent], now: now)
    let revivedCold = await CodexSessionActivityFetcher(sessionsURL: root).fetch(now: now)
    expect(revived == revivedCold && revived.activeThreadCount == 2,
           "Historical work becoming fresh recovers start metadata and agrees with a cold read")
    try FileManager.default.removeItem(at: parent)
    let removed = await fetcher.fetch(changedFiles: [parent], now: now)
    expect(!removed.conversations.contains { $0.id == old.id }, "Deleted historical parents leave the cache")
    expect(removed.conversations.first { $0.id == "codex:child" }?.launchTarget(in: removed.conversations) == nil,
           "Deleted parent never redirects to a different same-directory task")

    let families = (0..<12).flatMap { index in
        [Conversation(id: "root-\(index)", phase: .completed, updatedAt: Double(index)),
         Conversation(id: "child-\(index)", phase: .completed, updatedAt: Double(index),
                      isSubagent: true, parentConversationID: "root-\(index)")]
    }
    let limited = Conversation.tree(families)
    expect(limited.count == 20 && limited.filter { $0.depth == 0 }.count == 10,
           "Completion limit counts entire families, never individual children")
    expect(!limited.contains { ["root-0", "child-0", "root-1", "child-1"].contains($0.conversation.id) },
           "Discard oldest families as a unit")
    print("Conversation trees: historical ancestors/descendants, stale activity isolation, deletion and whole-family limits passed")
}

func preparesITermConversationLaunch() {
    let id = "01a169fe-5cd9-7e82-920a-16ea94854438"
    let conversation = Conversation(id: "codex:" + id, cwd: "/tmp/project", phase: .waiting, updatedAt: 0)
    expect(ITermConversationLauncher.sessionID(for: conversation) == id, "Codex UUID can be resumed")
    expect(ConversationSource.codex(originator: "Codex Desktop", source: "vscode") == .desktop, "Desktop originator identifies desktop, not vscode alone")
    expect(ConversationSource.codex(originator: nil, source: "vscode") == .unknown, "IDE sessions are not guessed as desktop")
    for source in ["cli", "exec"] {
        expect(ConversationSource.codex(originator: "codex_cli_rs", source: source) == .terminal, "Explicit CLI sources use terminal")
    }
    expect(conversation.desktopURL == nil, "Unknown sources retain existing terminal route")
    let desktop = Conversation(id: "codex:" + id, phase: .completed, updatedAt: 0, source: .desktop)
    expect(desktop.desktopURL?.absoluteString == "codex://threads/" + id, "Desktop link points at exact session")
    expect(Conversation(id: "codex:../bad", phase: .completed, updatedAt: 0, source: .desktop).desktopURL == nil, "Malformed IDs never become links")
    expect(Conversation(id: "claude:" + id, provider: .claude, phase: .completed, updatedAt: 0, source: .desktop).desktopURL == nil, "Other providers never open Codex desktop")
    for bad in ["codex:/tmp/rollout.jsonl", "codex:$(touch /tmp/bad)", "claude:" + id, "codex:"] {
        expect(ITermConversationLauncher.sessionID(for: .init(id: bad, phase: .waiting, updatedAt: 0)) == nil, "Reject non-session IDs")
    }
    expect(ITermConversationLauncher.sessionID(for: .init(id: "codex:" + id, provider: .claude, phase: .waiting, updatedAt: 0)) == nil, "Other providers never launch Codex")
    for provider in CodingAgent.allCases {
        let conversation = Conversation(id: provider.rawValue + ":" + id, provider: provider, phase: .waiting, updatedAt: 0)
        expect(ITermConversationLauncher.sessionID(for: conversation) == id, "Each provider accepts its own session UUID")
        for invalid in ["", "../session", "$(touch /tmp/bad)", id + "\n"] {
            expect(ITermConversationLauncher.sessionID(for: .init(id: provider.rawValue + ":" + invalid,
                provider: provider, phase: .waiting, updatedAt: 0)) == nil, "Reject malformed provider session IDs")
        }
        let command = ITermConversationLauncher.command(sessionID: id, cwd: "/tmp/Bob's $(echo bad)",
            executable: "/tmp/Agent CLI/" + provider.rawValue, provider: provider)
        expect(command == "cd -- '/tmp/Bob'\\''s $(echo bad)' && '/tmp/Agent CLI/\(provider.rawValue)' --resume '\(id)'",
               "Provider resume commands quote all arguments and preserve default permissions")
        let processes = """
        ttys010 /usr/local/bin/\(provider.rawValue) --resume \(id)
        ttys011 /usr/local/bin/\(provider.rawValue) -r \(id.uppercased())
        ttys012 /usr/local/bin/\(provider.rawValue) --session-id \(id)
        ttys013 /usr/local/bin/\(provider.rawValue) --resume other --prompt \(id)
        ttys014 /bin/echo --resume \(id)
        ttys015 /usr/local/bin/\(provider.rawValue) --resume \(id)-extra
        ?? /usr/local/bin/\(provider.rawValue) --resume \(id)
        ttys016 /usr/local/bin/codex resume \(id)
        """
        expect(ITermConversationLauncher.matchingTTYs(in: processes, sessionID: id, provider: provider) ==
            ["/dev/ttys010", "/dev/ttys011", "/dev/ttys012"], "Focus only the exact provider and session ID")
    }
    expect(ITermConversationLauncher.matchingTTYs(in:
        "ttys020 node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js --resume " + id,
        sessionID: id, provider: .claude) == ["/dev/ttys020"], "Recognize npm-installed Claude")
    let command = ITermConversationLauncher.command(sessionID: id, cwd: "/tmp/Bob's $(echo bad)", executable: "/tmp/Codex CLI/codex")
    expect(command == "cd -- '/tmp/Bob'\\''s $(echo bad)' && '/tmp/Codex CLI/codex' resume --no-daemon '\(id)'", "Quote all shell arguments without expanding input")
    let processes = """
    ttys001 /opt/homebrew/bin/codex resume --no-daemon \(id)
    ttys002 node /opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js resume \(id.uppercased())
    ttys003 /bin/echo codex resume \(id)
    ?? /usr/bin/codex resume \(id)
    ttys004 /usr/bin/codex resume \(id)-extra
    ttys005 /usr/bin/codex fork \(id)
    """
    expect(ITermConversationLauncher.matchingTTYs(in: processes, sessionID: id) == ["/dev/ttys001", "/dev/ttys002"], "Match only exact Codex resume session IDs attached to terminals")
    let claudeSession = Data("""
    {"pid":11564,"sessionId":"\(id.uppercased())","procStart":"Sun Oct 25 06:48:50 2026","kind":"interactive"}
    """.utf8)
    let claudeProcesses = """
    11564 ttys001 Sun Oct 25 06:48:50 2026 claude
    11564 ttys002 Sun Oct 25 07:48:50 2026 claude
    11565 ttys003 Sun Oct 25 06:48:50 2026 claude
    11564 ?? Sun Oct 25 06:48:50 2026 claude
    11564 ttys004 Sun Oct 25 06:48:50 2026 /bin/echo
    """
    expect(ITermConversationLauncher.matchingClaudeTTYs(in: claudeProcesses,
        sessions: [Data("{}".utf8), claudeSession], sessionID: id) == ["/dev/ttys001"],
        "Plain Claude sessions resolve by exact ID and live PID/start time, not cwd or stale PID")
    expect(ITermConversationLauncher.matchingClaudeTTYs(in: claudeProcesses,
        sessions: [claudeSession], sessionID: UUID().uuidString).isEmpty, "Different Claude sessions never share a terminal match")
    let backgroundSession = Data(String(decoding: claudeSession, as: UTF8.self)
        .replacingOccurrences(of: "interactive", with: "background").utf8)
    expect(ITermConversationLauncher.matchingClaudeTTYs(in: claudeProcesses,
        sessions: [backgroundSession], sessionID: id).isEmpty, "Ignore non-interactive Claude processes")
}

func readsGrokQuota() throws {
    let data = Data(#"{"config":{"creditUsagePercent":4,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-10-23T16:21:40.115+00:00","end":"2026-10-30T16:21:40.115+00:00"}},"subscription_tier":"SuperGrok"}"#.utf8)
    let now = Date(timeIntervalSince1970: 100)
    let quota = try GrokUsageSnapshot.decode(from: data, fetchedAt: now)
    expect(quota.window.roundedRemainingPercent == 96 && quota.periodLabel == "每周", "Grok account allowance is not session token usage")
    expect(quota.window.windowMinutes == 10080 && quota.window.resetsAt != nil && quota.fetchedAt == now, "Grok reset and fetch dates are preserved")
    let original = String(decoding: data, as: UTF8.self)
    for invalid in [original.replacingOccurrences(of: "Percent\":4", with: "Percent\":101"),
                    original.replacingOccurrences(of: "Percent\":4", with: "Percent\":-1"),
                    original.replacingOccurrences(of: "2026-10-30", with: "2026-10-22"),
                    original.replacingOccurrences(of: "2026-10-30T16:21:40.115+00:00", with: "bad-date"), "{}"] {
        do {
            _ = try GrokUsageSnapshot.decode(from: Data(invalid.utf8))
            expect(false, "Invalid Grok allowance must not display a made-up percentage")
        } catch {}
    }
    let monthly = original.replacingOccurrences(of: "TYPE_WEEKLY", with: "TYPE_MONTHLY")
    let monthlyQuota = try GrokUsageSnapshot.decode(from: Data(monthly.utf8))
    expect(monthlyQuota.periodLabel == "每月", "Grok period labels follow the source")
}


func discoversCharacterPacks() throws {
    let manager = FileManager.default
    let temporary = manager.temporaryDirectory.appendingPathComponent("character-catalog-\(UUID().uuidString)")
    defer { try? manager.removeItem(at: temporary) }
    let bundled = temporary.appendingPathComponent("bundled")
    let user = temporary.appendingPathComponent("user")
    let outside = temporary.appendingPathComponent("outside")
    for root in [bundled, user, outside] { try manager.createDirectory(at: root, withIntermediateDirectories: true) }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let png = try Data(contentsOf: repository.appendingPathComponent("Resources/CharacterFrames/grok/02/0.png"))
    func makePack(_ id: String, root: URL, name: String? = nil, provider: String? = nil, order: Int = 0,
                  mutate: (inout [String: Any]) -> Void = { _ in }) throws -> URL {
        let folder = root.appendingPathComponent(id)
        var states: [String: Any] = [:]
        for emotion in GrokBallEmotion.allCases {
            let directory = folder.appendingPathComponent(emotion.rawValue)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("0.png"))
            states[emotion.rawValue] = ["frames": 1, "fps": 15, "loop": true, "staticFrame": 0]
        }
        var manifest: [String: Any] = ["version": 1, "width": 72, "height": 44, "states": states, "sortOrder": order]
        if let name { manifest["name"] = name }
        if let provider { manifest["defaultFor"] = provider }
        mutate(&manifest)
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        return folder
    }
    _ = try makePack("fourth-role", root: bundled, name: "Fourth", provider: "codex", order: 2)
    _ = try makePack("first", root: bundled, name: "A", order: 0)
    _ = try makePack("second", root: bundled, name: "A", order: 0)
    _ = try makePack("fourth-role", root: user, name: "Override", provider: "grok", order: -1)
    _ = try makePack("custom", root: user, provider: "claude", order: 1)
    _ = try makePack("user-default", root: user, provider: "codex", order: 4)
    let looped = try makePack("intro-loop", root: outside) {
        var states = $0["states"] as! [String: [String: Any]]
        states["34"] = ["frames": 2, "fps": 15, "loop": true, "staticFrame": 1, "loopStartFrame": 1]
        $0["states"] = states
    }
    try png.write(to: looped.appendingPathComponent("34/1.png"))
    expect(CharacterCatalog(roots: [outside]).pack(id: "intro-loop") != nil, "intro plus loop metadata is accepted")
    try manager.removeItem(at: looped)
    let shared = try makePack("shared", root: outside) { $0["defaultFor"] = ["codex", "claude", "grok"] }
    let sharedCatalog = CharacterCatalog(roots: [outside])
    expect(["codex", "claude", "grok"].allSatisfy { sharedCatalog.defaultPack(for: $0)?.id == "shared" },
           "one pack can be the default for several providers")
    try manager.removeItem(at: shared)
    let catalog = CharacterCatalog(roots: [bundled, user])
    expect(catalog.packs.map(\.id) == ["first", "second", "custom", "fourth-role", "user-default"], "catalog sorts by order, name, then ID")
    expect(catalog.pack(id: "fourth-role")?.name == "Fourth", "bundled IDs take priority over user IDs")
    expect(catalog.pack(id: "custom")?.name == "custom", "legacy manifests fall back to folder name")
    expect(catalog.defaultPack(for: "codex")?.id == "fourth-role", "provider defaults preserve root priority")
    expect(catalog.defaultPack(for: "claude")?.id == "custom", "user packs can supply provider defaults")
    expect(catalog.defaultPack(for: "grok") == nil && catalog.pack(id: "absent") == nil, "duplicate IDs do not leak defaults")
    func invalid(_ id: String, mutate: (inout [String: Any]) -> Void) throws {
        _ = try makePack(id, root: outside, mutate: mutate)
    }
    try invalid("bad-version") { $0["version"] = 2 }
    try invalid("bad-width") { $0["width"] = 36 }
    try invalid("bad-height") { $0["height"] = 22 }
    try invalid("bad-name") { $0["name"] = "  " }
    try invalid("bad-provider") { $0["defaultFor"] = "../codex" }
    try invalid("bad-provider-list") { $0["defaultFor"] = ["codex", "../grok"] }
    try invalid("bad-states") { $0["states"] = [:] }
    try invalid("bad-once-loop") {
        var states = $0["states"] as! [String: [String: Any]]
        states["34"] = ["frames": 2, "fps": 15, "loop": false, "loopStartFrame": 1]
        $0["states"] = states
    }
    for (id, key, value) in [("bad-count", "frames", 151), ("empty-count", "frames", 0),
                             ("bad-fps", "fps", 16), ("zero-fps", "fps", 0),
                             ("bad-static", "staticFrame", 1), ("negative-static", "staticFrame", -1),
                             ("bad-loop", "loopStartFrame", 1), ("zero-loop", "loopStartFrame", 0)] {
        try invalid(id) {
            var states = $0["states"] as! [String: [String: Any]]
            states["02"]![key] = value
            $0["states"] = states
        }
    }
    let missing = try makePack("missing-frame", root: outside)
    try manager.removeItem(at: missing.appendingPathComponent("02/0.png"))
    let corrupt = try makePack("corrupt-frame", root: outside)
    var brokenPNG = png
    brokenPNG[0] ^= 1
    try brokenPNG.write(to: corrupt.appendingPathComponent("02/0.png"))
    let oversized = try makePack("oversized-frame", root: outside)
    try Data(repeating: 0, count: 262_145).write(to: oversized.appendingPathComponent("02/0.png"))
    let wrongSize = try makePack("wrong-size-frame", root: outside)
    var wrongPNG = png
    wrongPNG[19] = 36
    try wrongPNG.write(to: wrongSize.appendingPathComponent("02/0.png"))
    _ = try makePack("UpperCase", root: outside)
    expect(CharacterCatalog(roots: [outside]).packs.isEmpty, "invalid metadata, ranges, names and PNGs are ignored")
    let escaped = try makePack("escape", root: outside)
    try manager.createSymbolicLink(at: user.appendingPathComponent("escaped-folder"), withDestinationURL: escaped)
    let linkedFrame = try makePack("linked-frame", root: user)
    let frame = linkedFrame.appendingPathComponent("02/0.png")
    try manager.removeItem(at: frame)
    try manager.createSymbolicLink(at: frame, withDestinationURL: escaped.appendingPathComponent("02/0.png"))
    let linkedManifest = try makePack("linked-manifest", root: user)
    let manifest = linkedManifest.appendingPathComponent("manifest.json")
    try manager.removeItem(at: manifest)
    try manager.createSymbolicLink(at: manifest, withDestinationURL: escaped.appendingPathComponent("manifest.json"))
    let bounded = CharacterCatalog(roots: [user])
    expect(bounded.pack(id: "escaped-folder") == nil && bounded.pack(id: "linked-frame") == nil
        && bounded.pack(id: "linked-manifest") == nil, "folder, frame and manifest links must remain inside the root")
    expect(CharacterCatalog(roots: [temporary.appendingPathComponent("absent")]).packs.isEmpty, "missing roots are harmless")
}

func tracksConversationCompletions() throws {
    let now = Date(timeIntervalSince1970: 1000)
    let id = "codex:01a169fe-5cd9-7e82-920a-16ea94854438"
    func item(_ phase: AgentTaskPhase, _ time: TimeInterval, id: String = id,
              child: Bool = false) -> Conversation {
        Conversation(id: id, title: "测试会话", cwd: "/tmp/project", phase: phase,
                     updatedAt: time, source: .desktop, isSubagent: child)
    }
    var tracker = ConversationEventTracker()
    expect(tracker.update([item(.completed, 999)], now: now).isEmpty, "Startup never replays historical completions")
    expect(tracker.update([item(.working, 998)], now: now).isEmpty, "Running does not notify")
    let done = item(.completed, 1000)
    expect(tracker.update([done], now: now).map(\.notificationID) == [done.id + ".completed"], "Running to success notifies exact conversation")
    expect(tracker.update([done], now: now).isEmpty, "Repeated snapshot never duplicates notification")
    expect(tracker.update([item(.completed, 1001)], now: now).isEmpty, "Completion metadata updates do not notify again")
    _ = tracker.update([item(.thinking, 1002)], now: now)
    expect(tracker.update([item(.completed, 1003)], now: now).count == 1, "Another round in same session notifies once")
    _ = tracker.update([item(.working, 990)], now: now)
    expect(tracker.update([item(.unknown, 999)], now: now).isEmpty, "Aborted or unknown is not success")
    expect(tracker.update([item(.completed, 1000)], now: now).isEmpty, "Unknown to completed is not an observed successful turn")
    _ = tracker.update([item(.waiting, 999)], now: now)
    expect(tracker.update([done], now: now).count == 1, "Waiting conversation may complete successfully")
    _ = tracker.update([item(.working, 700)], now: now)
    expect(tracker.update([item(.completed, 701)], now: now).isEmpty, "Stale completion after sleep is not replayed")
    _ = tracker.update([item(.working, 999)], now: now)
    expect(tracker.update([item(.completed, 998)], now: now).isEmpty, "Out-of-order completion is ignored")
    _ = tracker.update([item(.working, 999, child: true)], now: now)
    expect(tracker.update([item(.completed, 1000, child: true)], now: now).isEmpty, "Subagents stay quiet")
    _ = tracker.update([], now: now)
    expect(tracker.update([done], now: now).isEmpty, "Reappearing completion does not notify")
    let otherID = "codex:01a169fe-5cd9-7e82-920a-16ea94854439"
    _ = tracker.update([item(.working, 999), item(.working, 999, id: otherID)], now: now)
    expect(tracker.update([done, item(.completed, 1000, id: otherID)], now: now).count == 2, "Parallel conversations notify independently")
    var coalesced = ConversationEventTracker()
    _ = coalesced.update([done], now: now)
    let fastDone = Conversation(id: id, phase: .completed, updatedAt: 1002, turnStartedAt: 1001, source: .desktop)
    expect(coalesced.update([fastDone], now: now.addingTimeInterval(2)).count == 1,
           "A full turn between reads notifies even when its running snapshot was coalesced")
    expect(coalesced.update([fastDone], now: now.addingTimeInterval(2)).isEmpty, "Coalesced completion emits once")
    let changedTitle = Conversation(id: id, title: "renamed", phase: .completed, updatedAt: 1003, turnStartedAt: 1001)
    expect(coalesced.update([changedTitle], now: now.addingTimeInterval(3)).isEmpty, "Same-turn metadata still stays quiet")
    var newSession = ConversationEventTracker()
    _ = newSession.update([], now: now)
    expect(newSession.update([fastDone], now: now.addingTimeInterval(2)).count == 1,
           "A newly created fast session after startup also notifies")
    _ = newSession.update([], now: now.addingTimeInterval(3))
    expect(newSession.update([fastDone], now: now.addingTimeInterval(4)).isEmpty,
           "Reappearing explicit-turn completion never replays its reminder")
    var staleSession = ConversationEventTracker()
    _ = staleSession.update([Conversation(id: id, phase: .working, updatedAt: 900, isStale: true)], now: now)
    expect(staleSession.update([fastDone], now: now.addingTimeInterval(2)).count == 1,
           "A new explicit turn after stale history still notifies")
    var startup = ConversationEventTracker()
    expect(startup.update([fastDone], now: now.addingTimeInterval(2)).isEmpty, "Explicit turn timestamps do not replay history on startup")

    var agents = ConversationEventTracker()
    let claude = Conversation(id: "claude:01a169fe-5cd9-7e82-920a-16ea94854438", provider: .claude,
                              phase: .working, updatedAt: 999)
    _ = agents.update([claude], now: now)
    let claudeDone = Conversation(id: claude.id, provider: .claude, phase: .completed, updatedAt: 1000)
    expect(agents.update([claudeDone], now: now).map(\.notificationID) == [claudeDone.id + ".completed"], "Provider completion has an independent baseline")
    for conversation in [done, claudeDone] {
        let bytes = try PropertyListSerialization.data(fromPropertyList: conversation.notificationInfo, format: .binary, options: 0)
        let info = try PropertyListSerialization.propertyList(from: bytes, format: nil) as! [String: String]
        let restored = Conversation(notificationInfo: info)
        expect(restored?.id == conversation.id && restored?.provider == conversation.provider,
               "Notification preserves exact identity across process restarts")
        expect(restored?.cwd == conversation.cwd && restored?.desktopURL == conversation.desktopURL,
               "Notification preserves validated directory and routing")
    }
    var invalid = done.notificationInfo
    invalid["provider"] = "invalid"
    expect(Conversation(notificationInfo: invalid) == nil, "Invalid provider is never interpreted as Codex")
    invalid = done.notificationInfo; invalid["id"] = "codex:../bad"
    expect(Conversation(notificationInfo: invalid) == nil, "Malformed notification ID is rejected")
    invalid = done.notificationInfo; invalid["cwd"] = "relative/path"
    expect(Conversation(notificationInfo: invalid)?.cwd == nil, "Notification directories pass normal validation")
    print("Completion notifications: transitions, deduplication, parallel providers, stale/subagent suppression and click payload passed")
}

do {
    try handlesExtremeResetDates()
    try await handlesBrokenRPCProcesses()
    try boundsTerminalAutomationProcesses()
    try tracksConversationCompletions()
    migratesLegacyPreferences()
    try configuresActivityHooks()
    try discoversCharacterPacks()
    formatsRunningDuration()
    limitsCompletedConversations()
    buildsConversationTree()
    try await retainsWholeConversationFamilies()
    preparesITermConversationLaunch()
    try await aggregatesCodexMenuAnimationPhases()
    try await readsCustomToolConversationPhases()
    try await readsConversationMetadataAndPhases()
    testsMenuBarRules()
    try await readsTurnStartSignals()
    try await tracksCodexStartWithoutCompletionStealing()
    try readsClaudeQuota()
    try await cachesClaudeQuotaAndCooldown()
    try await cachesClaudeCredentialsWithoutRepeatingConsent()
    try readsGrokQuota()
    try await tracksConcurrentAgentSessions()
    try detectsAccountIdentityWithoutTokenChurn()
    try await watchesOnlyCodexStateChanges()
    try await updatesOnlyChangedRollouts()
    try decodesRateLimitWindows()
    try decodesRateLimitWindowsByDuration()
    try classifiesSingleWeeklyRateLimitWindow()
    try rejectsQuotaWindowsWithoutDuration()
    selectsAvailableQuota()
    clampsPercentages()
    formatsResetTextInEnglish()
    locatesCodexExecutables()
    reportsActiveSessionWhenAnyThreadIsActive()
    try await readsRecentRolloutTaskState()
    try await retainsResumedOldRolloutsAndBoundsWatchers()
    try await incrementallyReadsRollouts()
    if CommandLine.arguments.contains("--live-grok") {
        let quota = try await GrokUsageFetcher().fetch()
        print("Live Grok quota: \(quota.periodLabel) \(quota.window.roundedRemainingPercent)% remaining, reset \(quota.window.resetsAt?.description ?? "unknown")")
    }
    if CommandLine.arguments.contains("--live-claude") {
        let suite = "ClaudeLiveConsent." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: ClaudeUsageFetcher.consentKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = try await ClaudeUsageFetcher(defaults: defaults).fetch(allowInteraction: true)
        print("Live Claude quota: 5h \(snapshot.fiveHour?.roundedRemainingPercent.description ?? "unknown")%, week \(snapshot.weekly?.roundedRemainingPercent.description ?? "unknown")% remaining")
    }
    if CommandLine.arguments.contains("--live") {
        let snapshot = try await CodexRPCUsageFetcher().fetch()
        print("Live Codex usage: \(snapshot.accessibilitySummary)")
    }
    if CommandLine.arguments.contains("--live-sparse-path") {
        let snapshot = try await CodexRPCUsageFetcher(environment: ["PATH": "/usr/bin:/bin"]).fetch()
        print("Live sparse PATH Codex usage: \(snapshot.accessibilitySummary)")
    }
    if CommandLine.arguments.contains("--live-activity") {
        let activity = await CodexSessionActivityFetcher().fetch()
        print("Live activity: \(activity.activeThreadCount)/\(activity.loadedThreadCount) active threads")
        let agents = await AgentActivityStore().fetch()
        for (name, conversations) in [("Codex", activity.conversations), ("CLI", agents.conversations)] {
            print("Live \(name) metadata: \(conversations.count) sessions, \(conversations.filter { $0.title != nil }.count) titles, \(conversations.filter { $0.project != nil }.count) projects")
            for conversation in conversations {
                print("Live state: \(conversation.id) \(conversation.phase.rawValue)")
            }
        }
    }
    print("UpkinCoreTests passed")
} catch {
    fputs("Test threw: \(error)\n", stderr)
    Foundation.exit(1)
}
