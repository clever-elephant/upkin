#!/usr/bin/env bash
# Capture production AppKit views with fictional data; no provider calls or config writes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/upkin-readme.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
swift build --product Upkin
BIN="$(swift build --show-bin-path)"
mkdir -p .codex-qa/readme-refresh
cat > "$TEMP/main.swift" <<'SWIFT'
import AppKit
import UpkinCore
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
@MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
@MainActor func capture(_ window: NSWindow, _ name: String, _ appearance: NSAppearance.Name) throws {
    window.appearance = NSAppearance(named: appearance)
    window.contentView?.appearance = NSAppearance(named: appearance)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
    CATransaction.flush()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l", String(window.windowNumber), ".codex-qa/readme-refresh/\(name).png"]
    try process.run(); process.waitUntilExit()
    precondition(process.terminationStatus == 0, "Capture \(name)")
}
let now = Date()
let stamp = now.timeIntervalSince1970
let parentID = "codex:01a169fe-5cd9-7e82-920a-16ea94854438"
let conversations: [Conversation] = [
    .init(id: parentID, title: "完善菜单栏交互", cwd: "/demo/upkin", phase: .working, updatedAt: stamp, startedAt: stamp - 485, source: .desktop),
    .init(id: "codex:01a169fe-5cd9-7e82-920a-16ea94854439", title: "子代理 · 检查动画播放", cwd: "/demo/upkin", phase: .thinking, updatedAt: stamp, startedAt: stamp - 185, isSubagent: true, parentConversationID: parentID),
    .init(id: "codex:01a169fe-5cd9-7e82-920a-16ea94854440", title: "补齐角色资源校验", cwd: "/demo/upkin", phase: .completed, updatedAt: stamp - 120, source: .terminal)]
let tasks = [
    AgentTask(provider: .claude, sessionID: "01a169fe-5cd9-7e82-920a-16ea94854441", phase: .waiting, updatedAt: stamp, title: "确认首页排版", cwd: "/demo/website"),
    AgentTask(provider: .grok, sessionID: "01a169fe-5cd9-7e82-920a-16ea94854442", phase: .working, updatedAt: stamp, startedAt: stamp - 125, title: "补充接口测试", cwd: "/demo/api")]
let usage = CodexUsageSnapshot(fiveHour: .init(usedPercent: 28, windowMinutes: 300, resetsAt: now.addingTimeInterval(7200)), weekly: .init(usedPercent: 42, windowMinutes: 10080, resetsAt: now.addingTimeInterval(259200)), planType: nil, fetchedAt: now)
let claude = try ClaudeUsageSnapshot.decode(from: Data(#"{"five_hour":{"utilization":36},"seven_day":{"utilization":18}}"#.utf8), fetchedAt: now)
let grok = try GrokUsageSnapshot.decode(from: Data(#"{"config":{"creditUsagePercent":24,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","start":"2026-10-01T00:00:00Z","end":"2026-11-01T00:00:00Z"}}}"#.utf8), fetchedAt: now)
let panel = StatusPopoverController(refresh: {}, openConversation: { _ in })
panel.update(snapshot: usage, session: .init(activeThreadCount: 2, loadedThreadCount: 3, conversations: conversations), agents: .init(tasks: tasks), error: nil, refreshing: false, claudeSnapshot: claude, claudeConnected: true, grokSnapshot: grok)
let item = NSStatusBar.system.statusItem(withLength: 50)
item.button!.title = "Upkin"
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
panel.toggle(relativeTo: item.button!)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
let root = panel.popover.contentViewController!.view
for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    try capture(root.window!, "conversations-\(theme)", appearance)
}
let quota = descendants(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "quota-codex" }!
quota.performClick(nil)
for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    try capture(root.window!, "quota-\(theme)", appearance)
}
panel.popover.close()
NSStatusBar.system.removeStatusItem(item)
let settings = SettingsWindowController(refreshCodex: {}, refreshGrok: {}, connectClaude: {}, disconnectClaude: {})
settings.update(codexReady: true, codexError: nil, codexBusy: false, claudeReady: true, claudeGranted: true, claudeError: nil, claudeBusy: false, grokReady: true, grokError: nil, grokBusy: false)
settings.present()
for (index, name) in [(0, "connections"), (1, "characters"), (2, "notifications")] {
    settings.selectSection(index)
    for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        try capture(settings.window!, "\(name)-\(theme)", appearance)
    }
}
settings.close()
print("Exported 10 native screenshots with demo data.")
SWIFT
FILES=(); OBJECTS=()
for FILE in "$ROOT"/Sources/Upkin/*.swift; do
  [[ "$(basename "$FILE")" == main.swift ]] || FILES+=("$FILE")
done
for FILE in "$ROOT"/Sources/UpkinCore/*.swift; do
  OBJECTS+=("$BIN/UpkinCore.build/$(basename "$FILE").o")
done
swiftc -swift-version 6 -I "$BIN/Modules" "${FILES[@]}" "$TEMP/main.swift" "${OBJECTS[@]}" -o "$TEMP/capture"
"$TEMP/capture"
sips -s format png Resources/AppIcon.icns --out docs/media/app-icon.png >/dev/null
