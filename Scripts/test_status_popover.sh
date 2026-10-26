#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/status-popover-test.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
source "$ROOT/Scripts/test_support.sh"
mkdir -p .codex-qa
python3 - "$ROOT" "$TEMP" <<'PY'
import pathlib, sys
root, temp = map(pathlib.Path, sys.argv[1:])
s = (root / 'Sources/Upkin/main.swift').read_text()
connect = s[s.index('    private func connectClaudeUsage()'):s.index('    private func disconnectClaudeUsage()')]
assert connect.index('bool(forKey: ClaudeUsageFetcher.consentKey)') < connect.index('let alert = NSAlert()')
assert 'self.refreshClaudeUsage(allowInteraction: true)\n            return' in connect
refresh = s[s.index('    private func refreshClaudeUsage('):s.index('    private func refreshSessionActivity(')]
assert 'set(false, forKey: ClaudeUsageFetcher.consentKey)' not in refresh, 'Fetch failures must preserve app consent'
disconnect = s[s.index('    private func disconnectClaudeUsage()'):s.index('    private func refreshClaudeUsage(')]
assert 'await self.claudeFetcher.clearCache()' in disconnect, 'Disconnect must release cached credentials'
assert 'statusMenu' not in s and 'menuNeedsUpdate' not in s and 'NSMenuDelegate' not in s
assert 'action = #selector(self.togglePopover)' in s
assert 'addSubview(self.characterView)' not in s
assert 'self.characterView.playbackWindow = self.statusItem.button?.window' in s
assert 'frameDidChange' not in s and 'updateMenuBarImage' in s
assert 'self.characterView.attach(to: button)' in s
assert 'NSSize(width: 32, height: 22)' in s
# Verify open/close wiring without real provider requests in the UI fixture.
start = s.index('    @objc private func refreshMenuAction() {')
end = s.index('    @objc private func statusBarScreenChanged(', start)
for call in ['refreshClaudeUsage()', 'refreshGrokUsage()', 'refresh()', 'refreshSessionActivity()', 'refreshAgentActivity()']:
    assert 'self.' + call in s[start:end]
s = s[:start] + '    private var menuRefreshes = 0\n    @objc private func refreshMenuAction() { self.menuRefreshes += 1 }\n\n' + s[end:]
s = s.replace('app.run()', r'''
extension AppDelegate {
    func verifyStatusPopover() throws {
        // This fixture bypasses applicationDidFinishLaunching, which normally installs the observer.
        NotificationCenter.default.addObserver(self, selector: #selector(self.characterCatalogChanged),
            name: CharacterFrames.catalogDidChange, object: nil)
        self.characterView.playbackWindow = self.statusItem.button?.window
        let stamp = Date().timeIntervalSince1970
        let grokTask = AgentTask(provider: .grok, sessionID: "FIXTURE_GROK", phase: .working, updatedAt: stamp, startedAt: stamp)
        let claudeTask = AgentTask(provider: .claude, sessionID: "FIXTURE_CLAUDE", phase: .waiting, updatedAt: stamp, startedAt: stamp + 1)
        let scenarios: [([AgentTask], CodingAgent?)] = [
            ([], nil), ([claudeTask], nil), ([grokTask], .grok), ([grokTask, claudeTask], .grok)]
        for (tasks, expectedProvider) in scenarios {
            self.agentActivity = AgentActivitySnapshot(tasks: tasks)
            self.menuBar = MenuBarPresentation()
            self.updateMenuBarActivity()
            self.updateStatusItem()
            precondition(self.statusItem.length == 44, "Concurrent work must not widen the unknown-quota slot")
            precondition(self.statusItem.button!.subviews.compactMap { $0 as? GrokBallView }.isEmpty)
            precondition(self.characterView.animationLayer.superlayer === self.statusItem.button!.layer,
                         "Animation lives in an independent compositor layer, not the status image")
            let still = self.statusItem.button!.image
            self.updateMenuBarImage()
            precondition(self.statusItem.button!.image === still, "Unchanged status must not replace the static replica image")
            let expectedCharacter = CharacterFrames.character(for: expectedProvider?.rawValue ?? "codex")
            precondition(self.menuBar.provider == expectedProvider && self.characterView.character == expectedCharacter
                         && self.characterView.currentImage != nil, "Old starts must not reclaim a running role")
        }
        self.agentActivity = AgentActivitySnapshot()
        self.updateMenuBarActivity()
        self.updateStatusItem()
        CharacterFrames.reloadCatalog()
        precondition(self.characterView.character == CharacterFrames.character(for: self.menuBar.provider?.rawValue ?? "codex"),
                     "Catalog refresh preserves the provider's fixed character")
        self.updateStatusItem()
        let staticReplica = self.statusItem.button!.image
        for _ in 0..<3 { self.updateMenuBarImage() }
        precondition(self.statusItem.button!.image === staticReplica,
                     "Repeated status updates preserve one static replica, independent of CA animation frames")
        let statusWindow = self.statusItem.button!.window!
        let unrelatedWindow = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        unrelatedWindow.isReleasedWhenClosed = false
        self.statusBarScreenChanged(Notification(name: NSWindow.didChangeBackingPropertiesNotification, object: unrelatedWindow))
        precondition(self.statusItem.button!.image === staticReplica && self.characterView.playbackWindow === statusWindow,
                     "Other windows' backing changes must not touch the status replica or playback host")
        unrelatedWindow.close()
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            self.statusBarScreenChanged(Notification(name: name, object: statusWindow))
            precondition(self.characterView.playbackWindow === statusWindow && self.statusItem.button!.image === staticReplica,
                         "Screen/backing notifications with unchanged scale preserve the status image and playback window")
        }
        var refreshes = 0
        var opened: [String] = []
        let panel = StatusPopoverController(refresh: { refreshes += 1 },
                                            openConversation: { opened.append($0.id) })
        let root = panel.popover.contentViewController!.view
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func labels() -> [String] { descendants(root).compactMap { ($0 as? NSTextField)?.stringValue } }
        let now = Date()
        let active = CodexSessionActivitySnapshot(activeThreadCount: 2, loadedThreadCount: 3, conversations: [
            .init(id: "codex:01a169fe-5cd9-7e82-920a-16ea94854438", title: "修复登录问题", cwd: "/work/upkin", phase: .waiting, updatedAt: now.timeIntervalSince1970, source: .desktop),
            .init(id: "codex:2", title: "优化菜单栏布局", cwd: "/work/upkin", phase: .working, updatedAt: now.timeIntervalSince1970, startedAt: now.timeIntervalSince1970 - 185),
            .init(id: "codex:3", title: "修复额度显示", cwd: "/work/upkin", phase: .completed, updatedAt: now.timeIntervalSince1970 - 120)])
        let waiting = AgentTask(provider: .claude, sessionID: "01a169fe-5cd9-7e82-920a-16ea94854439", phase: .waiting,
            updatedAt: now.timeIntervalSince1970, title: "梳理支付流程", cwd: "/work/payments")
        let working = AgentTask(provider: .claude, sessionID: "01a169fe-5cd9-7e82-920a-16ea94854440", phase: .thinking,
            updatedAt: now.timeIntervalSince1970, startedAt: now.timeIntervalSince1970 - 3665, title: "补充接口测试", cwd: "/work/backend")
        let snapshot = CodexUsageSnapshot(fiveHour: .init(usedPercent: 32, windowMinutes: 300, resetsAt: now.addingTimeInterval(7200)),
            weekly: .init(usedPercent: 58, windowMinutes: 10080, resetsAt: now.addingTimeInterval(259200)), planType: nil, fetchedAt: now)
        func apply(_ usage: CodexUsageSnapshot? = nil, _ session: CodexSessionActivitySnapshot = .init(activeThreadCount: 0, loadedThreadCount: 0),
                   _ tasks: [AgentTask] = [], error: String? = nil, refreshing: Bool = false,
                   claude: ClaudeUsageSnapshot? = nil, claudeError: String? = nil, connected: Bool = true,
                   grok: GrokUsageSnapshot? = nil, grokError: String? = nil) {
            panel.update(snapshot: usage, session: session, agents: .init(tasks: tasks), error: error, refreshing: refreshing,
                         claudeSnapshot: claude, claudeError: claudeError, claudeConnected: connected, grokSnapshot: grok, grokError: grokError)
            panel.render()
            precondition(panel.popover.contentSize.width == 400 && panel.popover.contentSize.height > 50)
            precondition(labels().contains("会话"))
            precondition(!labels().contains { $0.contains("SESSION_") || $0 == "工作中" || $0 == "思考中" || $0 == "等待输入" })
        }
        let savedClaude = try ClaudeUsageSnapshot.decode(from: Data(#"{"five_hour":{"utilization":25}}"#.utf8))
        apply(claude: savedClaude, claudeError: "fixture", connected: false)
        precondition(!descendants(root).contains { ["quota-claude", "connect-claude"].contains($0.identifier?.rawValue ?? "") },
                     "Without consent, hide Claude quota and connection entry even with stale data or errors")
        apply(claude: savedClaude)
        let authorizedQuota = descendants(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "quota-claude" }!
        authorizedQuota.performClick(nil)
        precondition(labels().contains("Claude"))
        apply(claude: savedClaude, connected: false)
        precondition(!labels().contains("Claude") && !labels().contains("5 小时"),
                     "Revoking consent also closes the expanded Claude detail")
        apply()
        precondition(labels().contains("暂无近期会话"))
        let treeParent = Conversation(id: "codex:01a169fe-5cd9-7e82-920a-16ea94854438", title: "树状主会话",
            cwd: "/work/upkin", phase: .completed, updatedAt: now.timeIntervalSince1970 - 120, source: .desktop)
        let treeChild = Conversation(id: "codex:01a169fe-5cd9-7e82-920a-16ea94854439", title: "子代理 · Herschel",
            cwd: "/work/upkin", phase: .working, updatedAt: now.timeIntervalSince1970, startedAt: now.timeIntervalSince1970 - 185,
            isSubagent: true, parentConversationID: treeParent.id)
        let treeGrandchild = Conversation(id: "codex:01a169fe-5cd9-7e82-920a-16ea94854440", title: "子代理 · Hilbert",
            phase: .waiting, updatedAt: now.timeIntervalSince1970, isSubagent: true, parentConversationID: treeChild.id)
        let treeSibling = Conversation(id: "codex:01a169fe-5cd9-7e82-920a-16ea94854441", title: "子代理 · Mill",
            cwd: "/work/upkin", phase: .completed, updatedAt: now.timeIntervalSince1970 - 60,
            isSubagent: true, parentConversationID: treeParent.id)
        apply(nil, .init(activeThreadCount: 2, loadedThreadCount: 4, conversations: [treeGrandchild, treeSibling, treeChild, treeParent]))
        precondition(labels().contains("待处理  1") && !labels().contains("已完成  1"), "Family stays together in the highest-priority section")
        func titleX(_ text: String) -> CGFloat {
            let label = descendants(root).compactMap { $0 as? NSTextField }.first { $0.stringValue == text }!
            return root.convert(label.bounds, from: label).minX
        }
        precondition(titleX(treeParent.displayTitle) < titleX("Herschel")
                     && titleX("Herschel") < titleX("Hilbert"), "Tree depth indents each generation")
        let treeList = descendants(root).compactMap { $0 as? ConversationTreeList }.first!
        precondition(treeList.branches.count == 3, "Nested and sibling rows each have a native tree connector")
        precondition(!labels().contains("↳") && !labels().contains(treeChild.displayTitle), "Child rows omit redundant prefixes and text arrows")
        for (row, depth) in treeList.rows {
            let icon = row.subviews.first { $0.identifier?.rawValue == "conversation-icon" }!
            let title = row.subviews.compactMap { $0 as? NSTextField }.first!
            let gap = row.convert(title.bounds, from: title).minX - row.convert(icon.bounds, from: icon).maxX
            precondition(abs(gap - (depth > 0 ? 4 : 6)) < 0.5, "Icon and title use compact optical spacing")
            precondition(row.frame.height == (depth > 0 ? 26 : 32))
            precondition(icon.frame.width == (depth > 0 ? 24 : 28))
        }
        precondition(titleX("Mill") == titleX("Herschel"), "Siblings share the same title alignment")
        let childButton = descendants(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == treeGrandchild.id }!
        precondition(childButton.toolTip?.contains("打开所属主会话") == true)
        root.layoutSubtreeIfNeeded()
        let treeImage = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: treeImage)
        try treeImage.representation(using: .png, properties: [:])!.write(to:
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".codex-qa/conversation-tree.png"))
        childButton.performClick(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        precondition(opened.last == treeParent.id, "Child click opens its root rather than resuming an unloaded agent")
        opened.removeAll()
        let staleChild = Conversation(id: treeChild.id, title: treeChild.title, phase: .working,
            updatedAt: now.timeIntervalSince1970 - 7200, startedAt: now.timeIntervalSince1970 - 7300,
            isSubagent: true, parentConversationID: treeParent.id, isStale: true)
        apply(nil, .init(activeThreadCount: 0, loadedThreadCount: 0, conversations: [treeParent, staleChild]))
        precondition(labels().contains("状态已过期") && labels().contains("已完成  1"), "Historical child stays attached without promoting a finished family to running")
        precondition(!labels().contains("2 小时 1 分钟"), "Stale children have no live duration")
        apply(nil, .init(activeThreadCount: 1, loadedThreadCount: 1, conversations: [treeChild]))
        precondition(labels().contains(treeChild.displayTitle), "Orphan task remains visible")
        precondition(!descendants(root).contains { $0.identifier?.rawValue == treeChild.id }, "Missing parent has no unsafe resume button")
        let completedTasks = (0..<14).map { index in
            AgentTask(provider: .claude, sessionID: "done-\(index)", phase: .completed,
                      updatedAt: now.timeIntervalSince1970 - Double(index), title: "完成任务\(index)")
        }
        apply(nil, .init(activeThreadCount: 0, loadedThreadCount: 0), completedTasks + [waiting, working])
        precondition(labels().contains("已完成  10") && labels().contains("运行中  1") && labels().contains("待处理  1"))
        precondition(labels().contains("完成任务0") && labels().contains("完成任务9") && !labels().contains("完成任务10"))
        apply(refreshing: true)
        precondition(labels().contains("正在读取会话…"))
        precondition(descendants(root).compactMap { $0 as? NSButton }.first { $0.toolTip == "正在刷新" }?.isEnabled == false)
        let claude = try ClaudeUsageSnapshot.decode(from: Data(#"{"five_hour":{"utilization":84},"seven_day":{"utilization":33}}"#.utf8))
        apply(snapshot, active, [waiting, working], claude: claude)
        precondition(labels().contains("待处理  2") && labels().contains("运行中  2") && labels().contains("已完成  1"))
        precondition(labels().contains("· upkin") && labels().contains("· payments") && labels().contains("修复登录问题"))
        precondition(labels().contains("2 分钟前"))
        precondition(labels().contains("3 分钟") && labels().contains("1 小时 1 分钟"))
        let originalLabels = descendants(root).compactMap { $0 as? NSTextField }
        panel.updateRunningDurations(at: now.addingTimeInterval(60))
        precondition(labels().contains("4 分钟") && labels().contains("1 小时 2 分钟"))
        precondition(descendants(root).compactMap { $0 as? NSTextField } == originalLabels,
                     "Duration ticks must not rebuild rows or reset scrolling")
        panel.updateRunningDurations(at: now)
        precondition(descendants(root).filter { $0.accessibilityRole() == .progressIndicator }.isEmpty, "Quota is collapsed by default")
        for label in descendants(root).compactMap({ $0 as? NSTextField }) where label.stringValue == "修复登录问题" {
            precondition(label.font?.pointSize == 13)
        }
        let conversationButtons = descendants(root).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix("codex:") == true }
        precondition(conversationButtons.count == 1, "Only resumable Codex UUID rows are clickable")
        precondition(descendants(root).filter { $0.identifier?.rawValue == "open-conversation" }.count == 3, "All valid provider rows show a persistent opening arrow")
        precondition(conversationButtons[0].toolTip?.contains("点击在 Codex 桌面端") == true)
        conversationButtons[0].performClick(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        precondition(opened == ["codex:01a169fe-5cd9-7e82-920a-16ea94854438"], "Click opens the exact conversation")
        let resumableGrokTask = AgentTask(provider: .grok, sessionID: "01a169fe-5cd9-7e82-920a-16ea94854441", phase: .waiting,
            updatedAt: now.timeIntervalSince1970, title: "Grok 会话", cwd: "/work/grok")
        for task in [waiting, resumableGrokTask] {
            apply(snapshot, active, [task], claude: claude)
            let id = task.provider.rawValue + ":" + task.sessionID
            let button = descendants(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id }
            precondition(button != nil, "Each provider has a clickable conversation row")
            button!.performClick(nil)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            precondition(opened.last == id, "Click forwards the exact provider conversation")
        }
        apply(snapshot, active, [waiting, working], claude: claude)
        func quotaButton(_ provider: String) -> NSButton {
            descendants(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "quota-" + provider }!
        }
        let grok = try GrokUsageSnapshot.decode(from: Data(#"{"config":{"creditUsagePercent":4,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-10-23T16:21:40+00:00","end":"2026-10-30T16:21:40+00:00"}}}"#.utf8))
        apply(snapshot, active, [waiting, working], claude: claude, grok: grok)
        precondition(quotaButton("grok").attributedTitle.string.hasPrefix("96%"))
        quotaButton("grok").performClick(nil)
        precondition(labels().contains("每周") && !labels().contains("5 小时"), "Grok displays its own billing period")
        precondition(descendants(root).filter { $0.accessibilityRole() == .progressIndicator }.count == 1)
        quotaButton("grok").performClick(nil)
        apply(snapshot, active, [waiting, working], claude: claude, grokError: "读取失败，请刷新")
        precondition(quotaButton("grok").attributedTitle.string.hasPrefix("—"))
        precondition(!labels().contains { $0.contains("读取失败") }, "Quota errors stay out of the popover")
        apply(snapshot, active, [waiting, working], claude: claude, grok: grok)
        precondition(quotaButton("codex").attributedTitle.string.hasPrefix("42%"))
        precondition(quotaButton("claude").attributedTitle.string.hasPrefix("16%"), "Each summary uses its tightest window")
        let quotaButtons = ["codex", "claude", "grok"].map(quotaButton)
        for button in quotaButtons {
            precondition(button.image?.size == NSSize(width: 16, height: 16))
            precondition(button.imageScaling == .scaleNone, "Brand icons keep identical display dimensions")
            let font = button.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            precondition(font == NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium))
            precondition(button.font == font, "Native button and percentage use the same font")
        }
        precondition(Set(quotaButtons.map { $0.frame.midY }).count == 1, "Quota controls share the same vertical center")
        precondition(quotaButton("claude").image?.isTemplate == false)
        precondition(quotaButton("grok").image?.isTemplate == true, "Monochrome Grok mark follows light/dark appearance")
        precondition(!labels().contains("剩余额度"))
        let title = descendants(root).compactMap { $0 as? NSTextField }.first { $0.stringValue == "修复登录问题" }!
        let project = descendants(root).compactMap { $0 as? NSTextField }.first { $0.stringValue == "· upkin" }!
        let titleFrame = root.convert(title.alignmentRect(forFrame: title.bounds), from: title)
        let projectFrame = root.convert(project.alignmentRect(forFrame: project.bounds), from: project)
        precondition(abs(projectFrame.minX - titleFrame.maxX - 6) < 1 && abs(projectFrame.midY - titleFrame.midY) < 2,
                     "Title and project stay on one line: title=\(titleFrame) project=\(projectFrame)")
        let header = descendants(root).first { $0.identifier?.rawValue == "conversation-header" }!
        let footer = descendants(root).first { $0.identifier?.rawValue == "quota-footer" }!
        let headerButtons = descendants(header).compactMap { $0 as? NSButton }
        precondition(headerButtons.count == 1 && headerButtons[0].toolTip == "设置",
                     "Header has only the native settings control")
        let refreshButton = descendants(footer).compactMap { $0 as? NSButton }.first { $0.toolTip == "刷新额度与状态" }!
        precondition(refreshButton.keyEquivalent == "r" && refreshButton.bezelStyle == .recessed,
                     "Refresh keeps its shortcut and native styling in the fixed footer")
        precondition(descendants(root).compactMap { $0 as? NSButton }.filter { $0.toolTip == "刷新额度与状态" }.count == 1)
        for button in quotaButtons + [refreshButton] {
            precondition(button.frame.width >= button.fittingSize.width && footer.bounds.contains(button.frame),
                         "Footer controls fit without clipping: \(button.frame)")
        }
        precondition(refreshes == 0)
        panel.toggle(relativeTo: self.statusItem.button!)
        precondition(refreshes == 1, "Opening immediately requests fresh quota and activity")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 5))
        precondition(panel.popover.isShown)
        precondition(panel.durationTimer?.isValid == true, "Visible panel updates elapsed labels")
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            root.window?.appearance = NSAppearance(named: name)
            root.appearance = NSAppearance(named: name)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            root.layoutSubtreeIfNeeded()
            if let window = root.window {
                let shot = Process()
                shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                shot.arguments = ["-x", "-l", String(window.windowNumber), ".codex-qa/conversations-window-\(name.rawValue).png"]
                try shot.run(); shot.waitUntilExit()
            }
            let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.cacheDisplay(in: root.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".codex-qa/conversations-\(name.rawValue).png"))
        }
        // Pointer-position hover and scrolling are covered by test_conversation_hover.sh.
        panel.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        precondition(descendants(root).compactMap { $0 as? NSImageView }.filter { $0.frame.width <= 36.1 }.count >= 5)
        quotaButton("codex").performClick(nil)
        precondition(descendants(root).filter { $0.accessibilityRole() == .progressIndicator }.count == 2)
        precondition(labels().contains("剩余 68%") && !labels().contains("剩余 16%"))
        quotaButton("claude").performClick(nil)
        precondition(descendants(root).filter { $0.accessibilityRole() == .progressIndicator }.count == 2)
        precondition(labels().contains("剩余 16%") && !labels().contains("剩余 68%"), "Each provider opens only its own detail")
        quotaButton("claude").performClick(nil)
        precondition(descendants(root).filter { $0.accessibilityRole() == .progressIndicator }.isEmpty)
        apply(snapshot, active, [waiting], error: "fixture error")
        precondition(!labels().contains { $0.contains("更新失败") })
        quotaButton("codex").performClick(nil)
        precondition(labels().contains { $0.hasPrefix("上次更新于") }, "Stale quota retains its update time")
        quotaButton("codex").performClick(nil)
        apply(error: "fixture error", claudeError: "登录已过期，请重新登录")
        precondition(!labels().contains { $0.contains("更新失败") })
        precondition(!labels().contains { $0.contains("登录已过期") })
        apply(claudeError: "HTTP 429", grokError: "HTTP 500")
        precondition(!labels().contains { $0.contains("HTTP") }, "Raw provider errors must not be rendered")
        precondition(quotaButton("claude").attributedTitle.string.hasPrefix("—"), "Missing quota is not zero")
        for used: Double in [0, 100] {
            apply(CodexUsageSnapshot(fiveHour: nil, weekly: .init(usedPercent: used, windowMinutes: 10080, resetsAt: nil), planType: nil, fetchedAt: now))
            precondition(quotaButton("codex").attributedTitle.string.hasPrefix("\(Int(100 - used))%"))
        }
        let long = String(repeating: "很长的会话标题", count: 20)
        let tasks = (0..<30).map { AgentTask(provider: .grok, sessionID: "SESSION_\($0)", phase: .working,
            updatedAt: now.timeIntervalSince1970, title: long, cwd: "/work/" + String(repeating: "long-project", count: 20)) }
        apply(snapshot, .init(activeThreadCount: 0, loadedThreadCount: 0), tasks, claude: claude)
        precondition(panel.popover.contentSize.height < 480, "Many conversations must scroll, not fill screen")
        let scroll = descendants(root).compactMap { $0 as? NSScrollView }.first!
        precondition(scroll.scrollerStyle == .overlay && scroll.verticalScroller?.controlSize == .small,
                     "Conversation scrolling uses a compact native overlay, not a persistent track")
        let gutter = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay) + 2
        let list = scroll.documentView as! ConversationTreeList
        precondition(list.rows.allSatisfy { list.bounds.maxX - $0.view.frame.maxX >= gutter - 0.5 },
                     "Rows reserve space even for the expanded overlay scroller")
        let footerBefore = root.convert(quotaButton("codex").bounds, from: quotaButton("codex"))
        precondition(!descendants(scroll).contains { $0.identifier?.rawValue == "quota-codex" }, "Footer is outside scrolling list")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 150))
        scroll.reflectScrolledClipView(scroll.contentView)
        precondition(root.convert(quotaButton("codex").bounds, from: quotaButton("codex")) == footerBefore, "Footer stays fixed while conversations scroll")
        precondition(descendants(root).compactMap { $0 as? NSScrollView }.first?.frame.height == 360)
        let rowsBeforeRefresh = scroll.documentView!.subviews
        let scrollOrigin = scroll.contentView.bounds.origin
        apply(snapshot, .init(activeThreadCount: 0, loadedThreadCount: 0), tasks, refreshing: true, claude: claude)
        precondition(descendants(root).compactMap { $0 as? NSScrollView }.first === scroll,
                     "Quota/loading refresh preserves the list instance")
        precondition(scroll.documentView!.subviews == rowsBeforeRefresh && scroll.contentView.bounds.origin == scrollOrigin,
                     "Quota/loading refresh preserves row identities and scroll position")
        apply(snapshot, active, [waiting, working])
        let button = descendants(root).compactMap { $0 as? NSButton }.first { $0.toolTip == "刷新额度与状态" }!
        button.performClick(nil)
        precondition(refreshes == 2, "Manual refresh remains available")
        panel.popover.close()
        precondition(panel.durationTimer == nil, "Closed panel must stop duration ticks")
        precondition(refreshes == 2, "Closing does not refresh")
        panel.toggle(relativeTo: self.statusItem.button!)
        precondition(refreshes == 3, "Every reopen requests fresh data")
        panel.toggle(relativeTo: self.statusItem.button!)
        precondition(refreshes == 3 && !panel.popover.isShown, "Toggle-close does not refresh")
        self.updateStatusItem()
        precondition(self.statusItem.menu == nil)
        self.togglePopover()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        precondition(self.statusPopover.popover.isShown)
        precondition(self.menuRefreshes == 1, "Status button uses the shared refresh action")
        self.snapshot = snapshot
        self.sessionActivity = active
        self.agentActivity = .init(tasks: [waiting])
        self.updateStatusItem()
        precondition(self.statusPopover.snapshot == snapshot, "Open panel must receive live data")
        self.togglePopover()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
        precondition(!self.statusPopover.popover.isShown)
        precondition(self.menuRefreshes == 1, "Status button close does not refresh")
        precondition(self.statusItem.length == 60, "All providers share one compact two-digit quota slot")
        print("PASS: conversation groups; titles/projects; compact state icons; scroll; collapsed quota/detail; errors; refresh/toggle; light/dark captures")
    }
}
app.delegate = nil
app.setActivationPolicy(.accessory)
app.finishLaunching()
app.delegate = delegate
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
try delegate.verifyStatusPopover()
''')
(temp / 'main.swift').write_text(s)
PY
swiftc -swift-version 6 -I "$BIN/Modules" "${UI_SOURCES[@]}" "$TEMP/main.swift" \
    "${CORE_OBJECTS[@]}" -o "$TEMP/check"
bash "$ROOT/Scripts/test_conversation_hover.sh"
"$TEMP/check"
