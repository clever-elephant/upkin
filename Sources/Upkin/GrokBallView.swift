import AppKit
import UpkinCore
import ImageIO

// Baked assets are validated before decoding; only the selected state stays in memory.
@MainActor
enum CharacterFrames {
    static let catalogDidChange = Notification.Name("Upkin.CharacterCatalogDidChange")
    private(set) static var catalog = CharacterCatalog(roots: CharacterFrames.roots())

    private static func roots() -> [URL] {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("CharacterFrames")
        let builtIn = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/CharacterFrames")
        let user = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Upkin/Characters", isDirectory: true)
        return [builtIn, user]
    }

    static func reloadCatalog() {
        self.catalog = CharacterCatalog(roots: self.roots())
        NotificationCenter.default.post(name: self.catalogDidChange, object: nil)
    }

    static func character(for provider: String) -> String {
        self.catalog.defaultPack(for: provider)?.id ?? self.catalog.packs.first?.id ?? ""
    }

    static func folder(character: String) -> URL {
        self.catalog.pack(id: character)?.directory ?? self.roots()[0].appendingPathComponent(".invalid-character")
    }

    nonisolated private static func data(at file: URL, limit: Int) -> Data? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= limit,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= limit else { return nil }
        return data
    }

    nonisolated static func state(_ emotion: GrokBallEmotion, folder: URL) -> CharacterManifest.State? {
        guard let data = self.data(at: folder.appendingPathComponent("manifest.json"), limit: 65_536),
              let manifest = try? JSONDecoder().decode(CharacterManifest.self, from: data),
              manifest.isValid, let state = manifest.states[emotion.rawValue] else { return nil }
        return state
    }

    nonisolated private static func cgImage(folder: URL, emotion: GrokBallEmotion, index: Int) -> CGImage? {
        let file = folder.appendingPathComponent("\(emotion.rawValue)/\(index).png")
        guard let data = self.data(at: file, limit: 262_144),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == 72,
              properties[kCGImagePropertyPixelHeight] as? Int == 44 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func image(folder: URL, emotion: GrokBallEmotion, index: Int) -> NSImage? {
        guard let image = self.cgImage(folder: folder, emotion: emotion, index: index) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 36, height: 22))
    }

    struct Decoded: Sendable {
        let state: CharacterManifest.State
        let images: [CGImage]
    }

    nonisolated static func decode(folder: URL, emotion: GrokBallEmotion) -> Decoded? {
        guard let state = self.state(emotion, folder: folder) else { return nil }
        var images: [CGImage] = []
        for index in 0..<state.frames {
            guard !Task.isCancelled, let image = self.cgImage(folder: folder, emotion: emotion, index: index) else { return nil }
            images.append(image)
        }
        return Decoded(state: state, images: images)
    }

    static func representative(character: String, emotion: GrokBallEmotion) -> NSImage? {
        let folder = self.folder(character: character)
        guard let state = self.state(emotion, folder: folder) else { return nil }
        return self.image(folder: folder, emotion: emotion, index: state.staticFrame ?? (state.loop ? 0 : state.frames - 1))
    }
}

@MainActor
final class GrokBallView: NSView, CAAnimationDelegate {
    weak var playbackWindow: NSWindow? {
        didSet { if oldValue !== self.playbackWindow { self.visibilityChanged() } }
    }
    private(set) var currentImage: NSImage?
    private(set) var character: String
    private let directory: URL?
    private let spriteLayer = CALayer()
    private weak var host: NSView?
    private var frames: [(image: NSImage, cgImage: CGImage)] = []
    private var state: CharacterManifest.State?
    private var emotion: GrokBallEmotion = .idle
    private var reduceMotion = false
    private var oneShot = false
    private var loadedEmotion: GrokBallEmotion?
    private var generation = 0
    private var introFinished = false
    private(set) var frameIndex = 0
    private(set) var animationFinished = false
    var isAnimating: Bool { self.spriteLayer.animation(forKey: "character") != nil }
    var loadedFrameCount: Int { self.frames.count }
    var animationLayer: CALayer { self.spriteLayer }

    init(character: String? = nil, directory: URL? = nil) {
        self.directory = directory
        self.character = character ?? CharacterFrames.character(for: "codex")
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 22))
        self.spriteLayer.contentsGravity = .resizeAspect
        self.spriteLayer.contentsScale = 2
        NSWorkspace.shared.notificationCenter.addObserver(self,
            selector: #selector(self.motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.visibilityChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    func attach(to host: NSView) {
        if self.host !== host {
            self.stop()
            self.spriteLayer.removeFromSuperlayer()
            self.host = host
            host.wantsLayer = true
            host.layer?.addSublayer(self.spriteLayer)
        }
        self.layoutSprite()
        self.visibilityChanged()
    }

    override var frame: NSRect {
        didSet { self.layoutSprite() }
    }

    private func layoutSprite() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.spriteLayer.frame = self.host === self ? self.bounds : self.frame
        self.spriteLayer.isHidden = self.isHidden
        CATransaction.commit()
    }

    func setCharacter(_ character: String) {
        guard self.character != character else { return }
        self.stop()
        self.frames.removeAll()
        self.currentImage = nil
        self.state = nil
        self.loadedEmotion = nil
        self.character = character
        self.setContents(nil)
    }

    @discardableResult
    func show(_ emotion: GrokBallEmotion, reduceMotion: Bool? = nil, decoded: CharacterFrames.Decoded? = nil, oneShot: Bool = false) -> Bool {
        let changedPlayback = self.oneShot != oneShot
        self.oneShot = oneShot
        self.emotion = emotion
        let reduced = reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let changedMotion = self.reduceMotion != reduced
        self.reduceMotion = reduced
        let changedState = self.loadedEmotion != emotion
        if changedState {
            self.stop()
            self.frames.removeAll()
            self.currentImage = nil
            self.loadedEmotion = emotion
            self.animationFinished = false
            self.introFinished = false
            let folder = self.directory ?? CharacterFrames.folder(character: self.character)
            if let decoded {
                self.state = decoded.state
                self.frames = decoded.images.map { (NSImage(cgImage: $0, size: NSSize(width: 36, height: 22)), $0) }
            } else {
                self.state = CharacterFrames.state(emotion, folder: folder)
                if let state = self.state {
                    for index in 0..<state.frames {
                        guard let image = CharacterFrames.image(folder: folder, emotion: emotion, index: index),
                              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                            self.frames.removeAll()
                            self.state = nil
                            break
                        }
                        self.frames.append((image, cgImage))
                    }
                }
            }
        }
        if changedMotion || changedPlayback { self.stop() }
        if changedState || changedMotion || changedPlayback {
            self.animationFinished = false
            if changedState || changedPlayback { self.introFinished = false }
            self.frameIndex = (oneShot || self.state?.loop == false) ? max(0, self.frames.count - 1) : (self.state?.staticFrame ?? 0)
            let frame = self.frames.indices.contains(self.frameIndex) ? self.frames[self.frameIndex] : nil
            self.currentImage = frame?.image
            self.setContents(frame?.cgImage)
            if reduced && (oneShot || self.state?.loop == false) { self.animationFinished = true }
            if reduced { self.introFinished = true }
        }
        self.resumeIfVisible()
        return !self.frames.isEmpty
    }

    private func setContents(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.spriteLayer.contents = image
        CATransaction.commit()
    }

    override var isHidden: Bool {
        didSet { self.layoutSprite(); self.visibilityChanged() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window != nil && self.host == nil { self.attach(to: self) }
        self.visibilityChanged()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func restartPlayback() {
        self.stop()
        self.loadedEmotion = nil
    }

    func stop() {
        if self.state?.loopStartFrame != nil && self.isAnimating { self.introFinished = true }
        self.generation += 1
        self.spriteLayer.removeAnimation(forKey: "character")
    }

    @objc private func visibilityChanged() {
        if self.canAnimate { self.resumeIfVisible() } else { self.stop() }
    }

    private var canAnimate: Bool {
        let window = self.host?.window ?? self.playbackWindow ?? self.window
        return self.spriteLayer.superlayer != nil && !self.reduceMotion && !self.isHiddenOrHasHiddenAncestor
            && self.host?.isHiddenOrHasHiddenAncestor != true && window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true
    }

    private func resumeIfVisible() {
        guard self.canAnimate, !self.isAnimating, self.frames.count > 1,
              !self.animationFinished, let state = self.state else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        let introEnd = self.oneShot ? 0 : (state.loopStartFrame ?? 0)
        let playingIntro = introEnd > 0 && !self.introFinished
        let sequence = Array(self.frames[(playingIntro ? 0 : introEnd)..<(playingIntro ? introEnd : self.frames.count)])
        animation.values = sequence.map(\.cgImage) + [sequence.last!.cgImage]
        animation.keyTimes = (0...sequence.count).map { NSNumber(value: Double($0) / Double(sequence.count)) }
        animation.calculationMode = .discrete
        animation.duration = Double(sequence.count) / state.fps
        animation.repeatCount = state.loop && !self.oneShot && !playingIntro ? .infinity : 1
        if self.oneShot || !state.loop || playingIntro {
            // Model contents already holds the final frame after the one-shot is removed.
            animation.delegate = self
            animation.setValue(self.generation, forKey: "generation")
        }
        self.spriteLayer.add(animation, forKey: "character")
    }

    nonisolated func animationDidStop(_ animation: CAAnimation, finished flag: Bool) {
        let generation = animation.value(forKey: "generation") as? Int
        guard flag else { return }
        Task { @MainActor [weak self] in
            guard let self, self.generation == generation else { return }
            if !self.oneShot && self.state?.loopStartFrame != nil && !self.introFinished {
                self.introFinished = true
                self.spriteLayer.removeAnimation(forKey: "character")
                self.resumeIfVisible()
                return
            }
            self.animationFinished = true
        }
    }

    @objc private func motionPreferenceChanged() {
        self.show(self.emotion, oneShot: self.oneShot)
    }
}
