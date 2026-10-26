import AppKit
import UpkinCore
import CoreImage.CIFilterBuiltins
import Foundation
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var statusPopover = StatusPopoverController(
        refresh: { [weak self] in self?.refreshMenuAction() },
        openSettings: { [weak self] in self?.showSettings() })
    private lazy var settingsWindow = SettingsWindowController(
        refreshCodex: { [weak self] in self?.refresh() },
        refreshGrok: { [weak self] in self?.refreshGrokUsage() },
        connectClaude: { [weak self] in self?.connectClaudeUsage() },
        disconnectClaude: { [weak self] in self?.disconnectClaudeUsage() },
        notificationsChanged: { [weak self] in self?.completionNotifications.start(interactive: true) })
    private lazy var completionNotifications = CompletionNotificationController()
    private var menuBar = MenuBarPresentation()
    private let fetcher = CodexRPCUsageFetcher()
    private let grokFetcher = GrokUsageFetcher()
    private var grokSnapshot: GrokUsageSnapshot?
    private var grokError: String?
    private var isRefreshingGrok = false
    private let claudeFetcher = ClaudeUsageFetcher()
    private var claudeSnapshot: ClaudeUsageSnapshot?
    private var claudeError: String?
    private var isRefreshingClaude = false
    private let sessionActivityFetcher = CodexSessionActivityFetcher()
    private let agentActivityStore = AgentActivityStore()
    private let characterView = GrokBallView(character: CharacterFrames.character(for: "codex"))
    private var celebrationTask: Task<Void, Never>?
    private var appearanceObservation: NSKeyValueObservation?
    private var menuBarAnimationKey = ""
    private var menuBarRenderKey = ""
    // Source-out fallback erasure follows RunCatNeo's Apache-2.0 BackgroundLayer approach.
    private let characterBackdrop: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = true
        let filter = CIFilter.sourceOutCompositing()
        filter.backgroundImage = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 22))
        layer.backgroundFilters = [filter]
        return layer
    }()
    private var agentActivity = AgentActivitySnapshot()
    private var isReadingAgents = false
    private var needsAgentRescan = false
    private var pendingAgentFiles = Set<URL>()
    private var snapshot: CodexUsageSnapshot?
    private var errorMessage: String?
    private var sessionActivity = CodexSessionActivitySnapshot(activeThreadCount: 0, loadedThreadCount: 0)
    private var isFetchingSessionActivity = false
    private var isRefreshing = false
    private var timer: Timer?
    private var stateWatcher: CodexStateWatcher?
    private var accountID = CodexRPCUsageFetcher.accountID(from: CodexStateWatcher.rootURL.appendingPathComponent("auth.json"))
    private var needsUsageRefresh = false
    private var pendingActivityFiles = Set<URL>()
    private var needsActivityRescan = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        NSApp.setActivationPolicy(.accessory)

        self.statusItem.button?.target = self
        self.statusItem.button?.action = #selector(self.togglePopover)
        self.characterView.playbackWindow = self.statusItem.button?.window
        self.appearanceObservation = self.statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateMenuBarImage() }
        }
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(self.statusBarScreenChanged(_:)),
                                                   name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(self.characterCatalogChanged),
            name: CharacterFrames.catalogDidChange, object: nil)
        self.completionNotifications.anchor = { [weak self] in
            guard let button = self?.statusItem.button, let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        self.completionNotifications.start()
        self.watchCodexState()
        Task { @MainActor in
            self.updateStatusItem()
            self.refresh()
            self.refreshClaudeUsage()
            self.refreshGrokUsage()
            self.refreshSessionActivity()
            self.refreshAgentActivity()
        }
        self.timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recoverState()
            }
        }
        self.timer?.tolerance = 60
    }

    @objc private func refreshMenuAction() {
        self.refreshClaudeUsage()
        self.refreshGrokUsage()
        self.refresh()
        self.refreshSessionActivity()
        self.refreshAgentActivity()
    }

    @objc private func statusBarScreenChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === self.statusItem.button?.window else { return }
        self.characterView.playbackWindow = window
        self.updateMenuBarImage()
    }

    @objc private func characterCatalogChanged() {
        self.menuBarRenderKey = ""
        self.characterView.restartPlayback()
        self.updateStatusItem()
    }

    private func showSettings() {
        self.settingsWindow.present()
    }

    private func watchCodexState() {
        do {
            try FileManager.default.createDirectory(at: AgentActivityStore.directory,
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            self.stateWatcher = try CodexStateWatcher(activityURL: AgentActivityStore.directory) { [weak self] files, rescan in
                guard let self else { return }
                if rescan || files.contains(where: { $0.lastPathComponent == "auth.json" }) {
                    if self.updateAccount() { self.refresh() }
                }
                let agentFiles = files.filter { $0.deletingLastPathComponent().path == AgentActivityStore.directory.resolvingSymlinksInPath().standardizedFileURL.path }
                if rescan || !agentFiles.isEmpty { self.refreshAgentActivity(changedFiles: rescan ? nil : agentFiles) }
                let indexChanged = files.contains { $0.lastPathComponent == "session_index.jsonl" || $0.lastPathComponent.hasPrefix("state_") }
                let rollouts = files.filter { $0.pathExtension == "jsonl" && $0.lastPathComponent != "session_index.jsonl" }
                if rescan || indexChanged || !rollouts.isEmpty { self.refreshSessionActivity(changedFiles: rescan ? nil : rollouts) }
            }
        } catch { fputs("Codex state events: \(error.localizedDescription)\n", stderr) }
    }

    @discardableResult
    private func updateAccount() -> Bool {
        let accountID = CodexRPCUsageFetcher.accountID(from: CodexStateWatcher.rootURL.appendingPathComponent("auth.json"))
        guard accountID != self.accountID else { return false }
        self.accountID = accountID
        self.snapshot = nil
        self.errorMessage = nil
        self.updateStatusItem()
        return true
    }

    private func recoverState() {
        if self.stateWatcher == nil { self.watchCodexState() }
        self.stateWatcher?.refreshRollouts()
        self.updateAccount()
        self.refreshClaudeUsage()
        self.refreshGrokUsage()
        self.refreshSessionActivity()
        self.refreshAgentActivity()
        self.refresh()
    }

    private func refresh() {
        guard !self.isRefreshing else { self.needsUsageRefresh = true; return }
        self.isRefreshing = true
        self.updateStatusItem()

        let accountID = self.accountID
        Task {
            do {
                let snapshot = try await fetcher.fetch()
                if accountID == self.accountID {
                    self.snapshot = snapshot
                    self.errorMessage = nil
                }
            } catch {
                if accountID == self.accountID { self.errorMessage = error.localizedDescription }
            }
            self.isRefreshing = false
            self.updateStatusItem()
            if self.needsUsageRefresh {
                self.needsUsageRefresh = false
                self.refresh()
            }
        }
    }

    private func refreshGrokUsage() {
        guard !self.isRefreshingGrok else { return }
        self.isRefreshingGrok = true
        self.updateStatusItem()
        Task {
            do {
                self.grokSnapshot = try await self.grokFetcher.fetch()
                self.grokError = nil
            } catch {
                self.grokSnapshot = nil
                self.grokError = error.localizedDescription
            }
            self.isRefreshingGrok = false
            self.updateStatusItem()
        }
    }

    private func connectClaudeUsage() {
        guard !self.isRefreshingClaude else { return }
        self.statusPopover.popover.close()
        if UserDefaults.standard.bool(forKey: ClaudeUsageFetcher.consentKey) {
            self.refreshClaudeUsage(allowInteraction: true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "连接 Claude 额度？"
        alert.informativeText = "Upkin 将读取本机 Claude Code 的登录凭据，仅用于向 Anthropic 查询订阅额度。凭据仅在内存中使用，不写入磁盘，也不发送给 Anthropic 以外的任何服务。macOS 可能要求钥匙串授权；确认请求来自 Upkin 后可选择“始终允许”以减少重复提示。取消不影响会话活动。你可以随时断开额度连接。"
        alert.addButton(withTitle: "授权并连接")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(true, forKey: ClaudeUsageFetcher.consentKey)
        self.refreshClaudeUsage(allowInteraction: true)
    }

    private func disconnectClaudeUsage() {
        guard !self.isRefreshingClaude else { return }
        UserDefaults.standard.set(false, forKey: ClaudeUsageFetcher.consentKey)
        self.claudeSnapshot = nil
        self.claudeError = nil
        self.isRefreshingClaude = true
        self.updateStatusItem()
        Task {
            await self.claudeFetcher.clearCache()
            self.isRefreshingClaude = false
            self.updateStatusItem()
        }
    }

    private func refreshClaudeUsage(allowInteraction: Bool = false) {
        guard UserDefaults.standard.bool(forKey: ClaudeUsageFetcher.consentKey),
              !self.isRefreshingClaude else { return }
        self.isRefreshingClaude = true
        self.updateStatusItem()
        Task {
            do {
                self.claudeSnapshot = try await self.claudeFetcher.fetch(allowInteraction: allowInteraction)
                self.claudeError = nil
            } catch {
                // The fetcher retains stale data only for the same validated credentials.
                self.claudeSnapshot = nil
                self.claudeError = error.localizedDescription
            }
            self.isRefreshingClaude = false
            self.updateStatusItem()
        }
    }

    private func refreshSessionActivity(changedFiles: Set<URL>? = nil) {
        if let changedFiles { self.pendingActivityFiles.formUnion(changedFiles) }
        else { self.needsActivityRescan = true }
        guard !self.isFetchingSessionActivity else { return }
        let files = self.needsActivityRescan ? nil : self.pendingActivityFiles
        self.pendingActivityFiles.removeAll(keepingCapacity: true)
        self.needsActivityRescan = false
        self.isFetchingSessionActivity = true
        Task {
            defer {
                self.isFetchingSessionActivity = false
                if self.needsActivityRescan || !self.pendingActivityFiles.isEmpty {
                    self.refreshSessionActivity(changedFiles: [])
                }
            }
            let activity = await self.sessionActivityFetcher.fetch(changedFiles: files)
            guard activity != self.sessionActivity else { return }
            let log = Logger(subsystem: "com.local.Upkin", category: "notifications")
            let previous = Dictionary(self.sessionActivity.conversations.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            for item in activity.conversations where !item.isSubagent && !item.isStale {
                if previous[item.id]?.phase != item.phase || previous[item.id]?.turnStartedAt != item.turnStartedAt {
                    log.debug("Codex state: phase=\(item.phase.rawValue, privacy: .public), target=\(item.id, privacy: .private(mask: .hash))")
                }
            }
            self.sessionActivity = activity
            let events = self.updateMenuBarActivity()
            if !events.isEmpty { log.debug("Codex notification events: \(events.count)") }
            self.updateStatusItem()
            if events.contains(where: { $0.kind == .completed }) {
                self.refresh()
            }
        }
    }

    private func refreshAgentActivity(changedFiles: Set<URL>? = nil) {
        if let changedFiles { self.pendingAgentFiles.formUnion(changedFiles) }
        else { self.needsAgentRescan = true }
        guard !self.isReadingAgents else { return }
        let files = self.needsAgentRescan ? nil : self.pendingAgentFiles
        self.pendingAgentFiles.removeAll(keepingCapacity: true)
        self.needsAgentRescan = false
        self.isReadingAgents = true
        Task {
            self.agentActivity = await self.agentActivityStore.fetch(changedFiles: files)
            self.updateMenuBarActivity()
            self.isReadingAgents = false
            self.updateStatusItem()
            if self.needsAgentRescan || !self.pendingAgentFiles.isEmpty {
                self.refreshAgentActivity(changedFiles: [])
            }
        }
    }

    @discardableResult
    private func updateMenuBarActivity() -> [ConversationEvent] {
        let events = self.menuBar.update(self.sessionActivity.conversations + self.agentActivity.conversations)
        for id in self.menuBar.tracker.exitedWaiting { self.completionNotifications.removeWaiting(for: id) }
        for event in events { self.completionNotifications.post(event) }
        return events
    }

    private func updateStatusItem() {
        self.settingsWindow.update(codexReady: self.snapshot != nil, codexError: self.errorMessage, codexBusy: self.isRefreshing,
            claudeReady: self.claudeSnapshot != nil, claudeGranted: UserDefaults.standard.bool(forKey: ClaudeUsageFetcher.consentKey),
            claudeError: self.claudeError, claudeBusy: self.isRefreshingClaude,
            grokReady: self.grokSnapshot != nil, grokError: self.grokError, grokBusy: self.isRefreshingGrok)
        self.statusPopover.update(snapshot: self.snapshot, session: self.sessionActivity,
                                  agents: self.agentActivity, error: self.errorMessage,
                                  refreshing: self.isRefreshing || self.isRefreshingClaude || self.isRefreshingGrok,
                                  claudeSnapshot: self.claudeSnapshot, claudeError: self.claudeError,
                                  claudeConnected: UserDefaults.standard.bool(forKey: ClaudeUsageFetcher.consentKey),
                                  grokSnapshot: self.grokSnapshot, grokError: self.grokError)
        guard let button = self.statusItem.button else { return }
        self.statusItem.isVisible = true
        let provider = self.menuBar.provider
        let emotion = self.menuBar.emotion
        self.menuBarAnimationKey = (provider?.rawValue ?? "codex") + emotion.rawValue
        self.characterView.setCharacter(CharacterFrames.character(for: provider?.rawValue ?? "codex"))
        let ready = self.characterView.show(emotion, oneShot: self.menuBar.playing != nil)
        self.characterView.playbackWindow = button.window
        self.characterView.isHidden = !ready
        if self.menuBar.playing != nil && self.celebrationTask == nil {
            let folder = CharacterFrames.folder(character: self.characterView.character)
            let state = CharacterFrames.state(emotion, folder: folder)
            let duration = state.map { Double($0.frames) / $0.fps } ?? 0
            self.celebrationTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                guard let self else { return }
                self.celebrationTask = nil
                self.menuBar.finishPlayback()
                // Consecutive events may use the same provider and action; replay from frame zero.
                self.characterView.restartPlayback()
                self.updateStatusItem()
            }
        }
        self.updateMenuBarImage()
        button.toolTip = self.statusToolTip()
        button.setAccessibilityLabel(self.statusToolTip())
    }

    private func updateMenuBarImage() {
        guard let button = self.statusItem.button else { return }
        let frame = self.characterView.currentImage ?? self.runnerImage
        let percent = self.snapshot?.availablePercent
        let scale = button.window?.backingScaleFactor ?? 2
        let key = "\(self.menuBarAnimationKey):\(percent ?? -1):\(button.effectiveAppearance.name.rawValue):\(scale)"
        if self.menuBarRenderKey != key {
            self.menuBarRenderKey = key
            var image: NSImage!
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
#if arch(arm64)
                let fallback = frame
#else
                // Source-out backdrop erasure is unavailable on Intel; keep the live layer unobstructed.
                let fallback = self.characterView.isHidden ? self.runnerImage : NSImage(size: NSSize(width: 36, height: 22))
#endif
                image = MenuBarQuotaImage.makeRasterized(remainingPercent: percent, runnerImage: fallback, scale: scale)
            }
            if button.image !== image {
                self.statusItem.length = image.size.width
                button.title = ""
                button.image = image
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleNone
            }
        }
        button.wantsLayer = true
        let origin = NSPoint(x: (button.bounds.width - (button.image?.size.width ?? button.bounds.width)) / 2, y: button.bounds.midY - 11)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.characterBackdrop.frame = NSRect(origin: origin, size: NSSize(width: 32, height: 22))
        self.characterBackdrop.contentsScale = scale
        self.characterBackdrop.isHidden = self.characterView.isHidden
#if arch(arm64)
        if self.characterBackdrop.superlayer !== button.layer { button.layer?.addSublayer(self.characterBackdrop) }
#endif
        self.characterView.frame = NSRect(origin: origin, size: NSSize(width: 36, height: 22))
        CATransaction.commit()
        self.characterView.attach(to: button)
    }

    private let runnerImage = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Codex")!

    private func statusToolTip() -> String {
        let conversation = self.menuBar.displayedConversation
        let provider = conversation?.provider?.name ?? self.menuBar.provider?.name ?? "Codex"
        let phase = self.menuBar.playing?.kind.phase ?? conversation?.phase ?? .idle
        let activity = "\(provider) · \(phase.label)"
        let usage = self.snapshot?.accessibilitySummary ?? self.errorMessage ?? "正在读取 Codex 用量"
        return "\(activity)。\(usage)。Grok / Claude：\(self.agentActivity.summary)"
    }

    @objc private func togglePopover() {
        guard let button = self.statusItem.button else { return }
        self.statusPopover.toggle(relativeTo: button)
    }

}

UpkinPreferences.migrate()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
