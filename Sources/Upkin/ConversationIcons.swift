import AppKit
import UpkinCore

// Decode animation frames only for visible rows while the popover is open.
@MainActor
final class ConversationIcons: NSObject {
    static func providerImage(_ name: String, size: CGFloat) -> NSImage {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("ProviderIcons/\(name).png")
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/ProviderIcons/\(name).png")
        let image = bundled.flatMap { NSImage(contentsOf: $0) } ?? NSImage(contentsOf: local)
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)!
        image.size = NSSize(width: size, height: size)
        image.isTemplate = name != "claude"
        return image
    }

    private var images: [String: NSImage] = [:]
    private var targets: [(view: NSImageView, provider: String, emotion: GrokBallEmotion)] = []
    private var players: [ObjectIdentifier: GrokBallView] = [:]
    private var decoded: [String: CharacterFrames.Decoded] = [:]
    private var loading: [String: Task<Void, Never>] = [:]
    private weak var clipView: NSClipView?

    private var isLoaded = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(self.catalogChanged),
            name: CharacterFrames.catalogDidChange, object: nil)
    }

    private func image(character: String, emotion: GrokBallEmotion) -> NSImage {
        let key = character + emotion.rawValue
        if let cached = self.images[key] { return cached }
        let image = CharacterFrames.representative(character: character, emotion: emotion)
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)!
        self.images[key] = image
        return image
    }

    @objc private func catalogChanged() {
        let wasLoaded = self.isLoaded
        self.stop()
        self.images.removeAll()
        for target in self.targets {
            target.view.image = self.image(character: CharacterFrames.character(for: target.provider), emotion: target.emotion)
        }
        if wasLoaded { self.load() }
    }

    func image(for conversation: Conversation, compact: Bool = false) -> NSImageView {
        let provider = conversation.provider?.rawValue ?? "codex"
        let character = CharacterFrames.character(for: provider)
        let image = self.image(character: character, emotion: conversation.emotion)
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.widthAnchor.constraint(equalToConstant: compact ? 24 : 28).isActive = true
        view.heightAnchor.constraint(equalToConstant: 22).isActive = true
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel("\(conversation.provider?.name ?? "Codex") · \(conversation.phase.label)")
        self.targets.append((view, provider, conversation.emotion))
        return view
    }

    func load() {
        self.isLoaded = true
        let clip = self.targets.first?.view.enclosingScrollView?.contentView
        if self.clipView !== clip {
            self.removeScrollObserver()
            self.clipView = clip
            clip?.postsBoundsChangedNotifications = true
            if let clip {
                NotificationCenter.default.addObserver(self, selector: #selector(self.updateVisibleRows),
                    name: NSView.boundsDidChangeNotification, object: clip)
            }
        }
        self.updateVisibleRows()
    }

    @objc private func updateVisibleRows() {
        var visibleStates = Set<String>()
        for target in self.targets {
            let key = ObjectIdentifier(target.view)
            let visible = target.view.window?.isVisible == true && !target.view.isHiddenOrHasHiddenAncestor
                && !target.view.bounds.intersection(target.view.visibleRect).isEmpty
            if visible {
                let character = CharacterFrames.character(for: target.provider)
                let stateKey = character + target.emotion.rawValue
                visibleStates.insert(stateKey)
                guard self.players[key] == nil else { continue }
                guard let frames = self.decoded[stateKey] else {
                    if self.loading[stateKey] == nil {
                        let folder = CharacterFrames.folder(character: character)
                        let emotion = target.emotion
                        self.loading[stateKey] = Task { [weak self] in
                            let worker = Task.detached(priority: .utility) {
                                CharacterFrames.decode(folder: folder, emotion: emotion)
                            }
                            let frames = await withTaskCancellationHandler {
                                await worker.value
                            } onCancel: { worker.cancel() }
                            guard !Task.isCancelled, let self else { return }
                            self.loading[stateKey] = nil
                            if let frames {
                                self.decoded[stateKey] = frames
                                self.updateVisibleRows()
                            }
                        }
                    }
                    continue
                }
                let player = GrokBallView(character: CharacterFrames.character(for: target.provider))
                player.frame = target.view.bounds
                target.view.addSubview(player)
                if player.show(target.emotion, decoded: frames) {
                    target.view.image = nil
                    self.players[key] = player
                } else {
                    player.removeFromSuperview()
                }
            } else if let player = self.players.removeValue(forKey: key) {
                player.stop()
                player.removeFromSuperview()
                target.view.image = self.image(character: CharacterFrames.character(for: target.provider), emotion: target.emotion)
            }
        }
        self.decoded = self.decoded.filter { visibleStates.contains($0.key) }
        for key in Array(self.loading.keys) where !visibleStates.contains(key) {
            self.loading.removeValue(forKey: key)?.cancel()
        }
    }

    private func removeScrollObserver() {
        if let clipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clipView)
        }
        self.clipView = nil
    }

    func clearTargets() {
        self.stop()
        self.targets.removeAll()
    }

    func stop() {
        self.isLoaded = false
        self.removeScrollObserver()
        for target in self.targets {
            target.view.image = self.image(character: CharacterFrames.character(for: target.provider), emotion: target.emotion)
        }
        for player in self.players.values {
            player.stop()
            player.removeFromSuperview()
        }
        self.players.removeAll()
        self.loading.values.forEach { $0.cancel() }
        self.loading.removeAll()
        self.decoded.removeAll()
    }
}
