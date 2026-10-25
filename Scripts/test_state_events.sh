#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/.codex-qa"
TEMP="$(mktemp -d "$ROOT/.codex-qa/state-events.XXXXXX")"
trap '[[ -z "${CHECK_PID:-}" ]] || kill "$CHECK_PID" 2>/dev/null || true; rm -rf "$TEMP"' EXIT
source "$ROOT/Scripts/test_support.sh"
python3 - "$ROOT" "$TEMP" <<'PY'
import json,pathlib,sys
root,temp=map(pathlib.Path,sys.argv[1:])
(temp/'auth.json').write_text('{"tokens":{"account_id":"ACCOUNT_A"}}')
home='URL(fileURLWithPath: '+json.dumps(str(temp))+')'
s=(root/'Sources/Upkin/main.swift').read_text()
s=s.replace('CodexStateWatcher.rootURL',home)
s=s.replace('CodexStateWatcher(activityURL: AgentActivityStore.directory)', 'CodexStateWatcher(rootURL: '+home+', activityURL: '+home+'.appendingPathComponent("activity"))')
s=s.replace('AgentActivityStore.directory', home+'.appendingPathComponent("activity")')
s=s.replace('AgentActivityStore()', 'AgentActivityStore(directory: '+home+'.appendingPathComponent("activity"), home: '+home+')')
s=s.replace('CodexSessionActivityFetcher()','CodexSessionActivityFetcher(sessionsURL: '+home+'.appendingPathComponent("sessions"))')
s=s.replace('final class AppDelegate: NSObject, NSApplicationDelegate {','''final class AppDelegate: NSObject, NSApplicationDelegate {
    private var fixtureCompletions = 0
    private var fixtureRequests = 0
    private var fixtureActivityReads = 0
    private var fixtureImageUpdates = 0''')
s=s.replace('    private func updateMenuBarImage() {', '    private func updateMenuBarImage() {\n        self.fixtureImageUpdates += 1')
s=s.replace('self.refreshClaudeUsage()', '')
s=s.replace('self.refreshGrokUsage()', '')
s=s.replace('try await fetcher.fetch()','try await self.fetchFixtureUsage()')
s=s.replace('let activity = await self.sessionActivityFetcher.fetch','self.fixtureActivityReads += 1\n            let activity = await self.sessionActivityFetcher.fetch')
s=s.replace('for event in events { self.completionNotifications.post(event) }',
    'for event in events { if event.kind == .completed { self.fixtureCompletions += 1 }; self.completionNotifications.post(event) }')
s=s.replace('let delegate = AppDelegate()','''UserDefaults.standard.setVolatileDomain([
    "conversationNotificationsEnabled": false, "UpkinMenuBarStyle": 1
], forName: UserDefaults.argumentDomain)
let delegate = AppDelegate()''')
checks=r'''
extension AppDelegate {
    private func fetchFixtureUsage() async throws -> CodexUsageSnapshot {
        self.fixtureRequests += 1
        let used: Double = self.accountID == "ACCOUNT_A" ? 11 : 22
        try await Task.sleep(for: .seconds(1.2))
        return CodexUsageSnapshot(fiveHour: nil, weekly: UsageWindow(usedPercent: used,
            windowMinutes: 10080, resetsAt: nil), planType: nil, fetchedAt: Date())
    }

    private func waitUntil(_ predicate: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        fatalError("State event check timed out at fixture line \(line); phases=\(self.agentActivity.tasks); celebration=\(self.celebrationTask != nil); codex=\(self.menuBar.emotion)")
    }

    func verifyStateEvents() async throws {
        let root = FIXTURE_ROOT
        try await self.waitUntil { self.statusItem.button?.image != nil && self.stateWatcher != nil }
        precondition(self.statusItem.isVisible && self.statusItem.button!.image!.size.width == (self.menuBar.hasWaiting ? 70 : 65),
            "Legacy island preference must still show the single menu-bar layout")
        precondition(self.timer?.timeInterval == 600)
        precondition(self.stateWatcher != nil)
        try Data("{\"tokens\":{\"account_id\":\"ACCOUNT_B\"}}".utf8)
            .write(to: root.appendingPathComponent("auth.json"), options: .atomic)
        try await self.waitUntil { self.fixtureRequests == 2 }
        precondition(self.snapshot == nil, "Old account response must not publish after a switch")
        try await self.waitUntil { !self.isRefreshing }
        precondition(self.snapshot?.weekly?.roundedRemainingPercent == 78)
        let requestCount = self.fixtureRequests
        try Data("{\"tokens\":{\"account_id\":\"ACCOUNT_B\",\"refresh_token\":\"TOKEN\"}}".utf8)
            .write(to: root.appendingPathComponent("auth.json"), options: .atomic)
        try Data("{}".utf8).write(to: root.appendingPathComponent(".codex-global-state.json"), options: .atomic)
        try await Task.sleep(for: .seconds(1.2))
        precondition(self.fixtureRequests == requestCount,
            "Token rotation and avatar changes must not launch RPC")
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        let day = root.appendingPathComponent("sessions/" + formatter.string(from: Date()))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("fixture.jsonl")
        func codexEvent(_ type: String) -> Data {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let stamp = formatter.string(from: Date())
            return Data("{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\"}}\n".utf8)
        }
        try codexEvent("task_started").write(to: file)
        try await self.waitUntil { self.menuBar.emotion == .thinking }
        precondition(self.statusItem.isVisible && self.statusItem.button!.image != nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"functions.request_user_input\"}}\n".utf8))
        try handle.close()
        try await self.waitUntil { self.menuBar.emotion == .waiting && self.menuBar.hasWaiting }
        let completionHandle = try FileHandle(forWritingTo: file)
        try completionHandle.seekToEnd()
        try completionHandle.write(contentsOf: codexEvent("task_complete"))
        try completionHandle.close()
        try await self.waitUntil { self.menuBar.pending.completed != nil && self.celebrationTask != nil }
        try await self.waitUntil { !self.sessionActivity.hasActiveSession && self.celebrationTask == nil && !self.isRefreshing }
        let completedBeforeBurst = self.fixtureCompletions
        let burst = try FileHandle(forWritingTo: file)
        for turn in 1...5 {
            try burst.seekToEnd()
            try burst.write(contentsOf: codexEvent("task_started") + codexEvent("task_complete"))
            try await self.waitUntil { self.fixtureCompletions == completedBeforeBurst + turn }
        }
        try burst.close()
        try await self.waitUntil { self.celebrationTask == nil && !self.isRefreshing }
        precondition(self.fixtureCompletions == completedBeforeBurst + 5,
            "Five coalesced filesystem turns each reach the shipping notification call exactly once")
        print("PASS: five persistent-writer turns reached shipping notification delivery exactly once")
        let expiredReadCount = self.fixtureActivityReads
        try await Task.sleep(for: .seconds(4))
        precondition(self.fixtureActivityReads == expiredReadCount, "Completed Codex turn must expire once, not schedule repeated cache reads")
        precondition(self.statusItem.button!.image!.size.width == (self.menuBar.hasWaiting ? 70 : 65))
        try await Task.sleep(for: .seconds(2))
        let agentDirectory = root.appendingPathComponent("activity")
        var grok = AgentTask(provider: .grok, sessionID: "GROK_A", phase: .working,
            updatedAt: Date().timeIntervalSince1970, startedAt: Date().timeIntervalSince1970)
        var claude = AgentTask(provider: .claude, sessionID: "CLAUDE_A", phase: .waiting,
            updatedAt: Date().timeIntervalSince1970, startedAt: Date().timeIntervalSince1970 - 1)
        try JSONEncoder().encode(grok).write(to: agentDirectory.appendingPathComponent("grok.json"), options: .atomic)
        try JSONEncoder().encode(claude).write(to: agentDirectory.appendingPathComponent("claude.json"), options: .atomic)
        try await self.waitUntil { self.agentActivity.runningCount == 1 && self.agentActivity.waitingCount == 1 }
        precondition(self.menuBar.provider == .grok && self.characterView.character == "grok")
        precondition(self.statusItem.button!.image!.size.width == (self.menuBar.hasWaiting ? 70 : 65))
        precondition(self.statusItem.button!.subviews.compactMap { $0 as? GrokBallView }.isEmpty,
            "Native playback uses a compositor layer without an animated subview")
        precondition(self.characterView.animationLayer.superlayer === self.statusItem.button!.layer)
        let staticReplica = self.statusItem.button!.image
        try await Task.sleep(for: .milliseconds(500))
        precondition(self.statusItem.button!.image === staticReplica, "Playing frames must not replace the system status image")
        self.statusPopover.render()
        func texts(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(texts)
        }
        let labels = texts(self.statusPopover.popover.contentViewController!.view)
        precondition(labels.contains("运行中  1"))
        precondition(labels.contains("待处理  1"))
        grok.phase = .working; claude.phase = .working
        try JSONEncoder().encode(grok).write(to: agentDirectory.appendingPathComponent("grok.json"), options: .atomic)
        try JSONEncoder().encode(claude).write(to: agentDirectory.appendingPathComponent("claude.json"), options: .atomic)
        try await self.waitUntil { self.agentActivity.runningCount == 2 && self.agentActivity.waitingCount == 0 }
        grok = AgentTask(provider: .grok, sessionID: "GROK_A", phase: .completed, updatedAt: Date().timeIntervalSince1970, startedAt: grok.startedAt)
        try JSONEncoder().encode(grok).write(to: agentDirectory.appendingPathComponent("grok.json"), options: .atomic)
        try await self.waitUntil { self.celebrationTask != nil }
        try await Task.sleep(for: .seconds(1.2))
        claude = AgentTask(provider: .claude, sessionID: "CLAUDE_A", phase: .completed, updatedAt: Date().timeIntervalSince1970)
        try JSONEncoder().encode(claude).write(to: agentDirectory.appendingPathComponent("claude.json"), options: .atomic)
        try await self.waitUntil { self.agentActivity.tasks.contains { $0.provider == .claude && $0.phase == .completed } }
        try await self.waitUntil { self.celebrationTask == nil }
        precondition(self.menuBar.provider == .claude, "Latest event's character remains after both full cycles")
        precondition(self.menuBar.emotion == .idle, "Overlapping completions finish without another filesystem event")
        let nextStart = Date().timeIntervalSince1970
        claude = AgentTask(provider: .claude, sessionID: "CLAUDE_A", phase: .thinking,
            updatedAt: nextStart, startedAt: nextStart)
        try JSONEncoder().encode(claude).write(to: agentDirectory.appendingPathComponent("claude.json"), options: .atomic)
        try await self.waitUntil { self.menuBar.provider == .claude }
        precondition(self.characterView.character == "clawd" && self.characterView.superview == nil && self.characterView.playbackWindow === self.statusItem.button?.window)
        precondition(self.statusItem.button!.image!.size.width == (self.menuBar.hasWaiting ? 70 : 65))
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1))
        let nextCodex = "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
        let nextHandle = try FileHandle(forWritingTo: file)
        try nextHandle.seekToEnd()
        try nextHandle.write(contentsOf: Data(nextCodex.utf8))
        try nextHandle.close()
        try await self.waitUntil { self.menuBar.provider == nil }
        precondition(self.characterView.character == "chatgpt" && self.characterView.currentImage != nil && self.statusItem.button!.subviews.compactMap { $0 as? GrokBallView }.isEmpty)
        precondition(self.statusItem.button!.image!.size.width == (self.menuBar.hasWaiting ? 70 : 65))
        let finalHandle = try FileHandle(forWritingTo: file)
        try finalHandle.seekToEnd()
        try finalHandle.write(contentsOf: codexEvent("task_complete"))
        try finalHandle.close()
        try await self.waitUntil { !self.sessionActivity.hasActiveSession && self.celebrationTask == nil && !self.isRefreshing }
        precondition(self.menuBar.provider == .claude && self.characterView.character == "clawd",
            "Codex celebration yields to Claude work without another file event")
        claude = AgentTask(provider: .claude, sessionID: "CLAUDE_A", phase: .idle,
            updatedAt: Date().timeIntervalSince1970, startedAt: claude.startedAt)
        try JSONEncoder().encode(claude).write(to: agentDirectory.appendingPathComponent("claude.json"), options: .atomic)
        try await self.waitUntil { self.menuBar.emotion == .idle }
        precondition(self.menuBar.provider == .claude, "All idle retains the last role")
        grok = AgentTask(provider: .grok, sessionID: "GROK_A", phase: .working,
            updatedAt: Date().timeIntervalSince1970, startedAt: Date().timeIntervalSince1970 + 2)
        try JSONEncoder().encode(grok).write(to: agentDirectory.appendingPathComponent("grok.json"), options: .atomic)
        try await self.waitUntil { self.menuBar.provider == .grok }
        grok = AgentTask(provider: .grok, sessionID: "GROK_A", phase: .completed,
            updatedAt: Date().timeIntervalSince1970, startedAt: grok.startedAt)
        try JSONEncoder().encode(grok).write(to: agentDirectory.appendingPathComponent("grok.json"), options: .atomic)
        try await self.waitUntil { self.menuBar.emotion == .completed }
        try await self.waitUntil { self.menuBar.emotion == .idle && self.celebrationTask == nil }
        precondition(self.menuBar.provider == .grok, "Expired background Codex completion must not replay")
        try await Task.sleep(for: .milliseconds(600))
        let counts = [self.fixtureRequests, self.fixtureActivityReads]
        let imageUpdates = self.fixtureImageUpdates
        try Data("ready".utf8).write(to: root.appendingPathComponent("idle.ready"))
        try await Task.sleep(for: .seconds(20))
        precondition(self.fixtureImageUpdates - imageUpdates < 120,
            "Appearance observation must not feed image changes back into an endless redraw loop")
        precondition(counts == [self.fixtureRequests, self.fixtureActivityReads],
            "Idle time and unrelated files must perform no RPC, avatar work or activity scans")
        print("PASS state events: account switch; stale response discarded; no token churn; recursive activity; native icon/quota; overlapping completion expiry; native character switching; Codex waiting/completion/expiry; running-agent handoff; idle role retention; no stale celebration replay; zero idle reads/RPC")
    }
}
Task { @MainActor in
    do {
        try await Task.sleep(for: .milliseconds(100))
        try await delegate.verifyStateEvents()
        NSApp.terminate(nil)
    } catch { fputs("State event check failed: \(error)\n", stderr); exit(1) }
}
app.run()
'''.replace('FIXTURE_ROOT',home)
s=s.replace('app.run()',checks)
(temp/'main.swift').write_text(s)
PY
swiftc -swift-version 6 -I "$BIN/Modules" "${UI_SOURCES[@]}" "$TEMP/main.swift" \
    "${CORE_OBJECTS[@]}" -o "$TEMP/check"
"$TEMP/check" > "$TEMP/check.log" 2>&1 &
CHECK_PID=$!
python3 - "$TEMP" "$CHECK_PID" "$ROOT" <<'PY'
import json,pathlib,subprocess,sys,time
temp=pathlib.Path(sys.argv[1]); pid=sys.argv[2]; root=pathlib.Path(sys.argv[3])
for _ in range(600):
    if (temp/'idle.ready').exists(): break
    if subprocess.run(['kill','-0',pid],capture_output=True).returncode:
        raise SystemExit((temp/'check.log').read_text())
    time.sleep(.1)
else: raise SystemExit((temp/'check.log').read_text()+'\nIdle check did not start')
def state():
    cpu,rss=subprocess.check_output(['ps','-p',pid,'-o','time=','-o','rss=']).decode().split()
    values=cpu.split(':'); seconds=float(values[-1])+int(values[-2])*60
    return seconds,int(rss)
a=state(); start=time.monotonic(); time.sleep(15); b=state(); duration=time.monotonic()-start
result={'context':'isolated native character icon/quota app; main-process metrics; no live provider requests or account changes',
        'seconds':round(duration,3),'cpu_average_percent':round((b[0]-a[0])/duration*100,3),
        'rss_mib':round(b[1]/1024,2)}
directory=root/'.codex-qa/native-optimization-20261024'; directory.mkdir(parents=True,exist_ok=True)
(directory/'idle-runtime.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result))
PY
wait "$CHECK_PID" || { cat "$TEMP/check.log"; exit 1; }
CHECK_PID=""
cat "$TEMP/check.log"
