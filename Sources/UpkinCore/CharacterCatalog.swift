import Foundation

public struct CharacterPack: Sendable, Equatable {
    public let id: String
    public let name: String
    public let directory: URL
    public let defaultFor: [String]
    public let sortOrder: Int

    public init(id: String, name: String, directory: URL, defaultFor: [String] = [], sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.directory = directory
        self.defaultFor = defaultFor
        self.sortOrder = sortOrder
    }
}

public struct CharacterManifest: Decodable, Sendable {
    let version: Int
    let width: Int
    let height: Int
    let name: String?
    let defaultFor: Providers?
    let sortOrder: Int?
    public let states: [String: State]

    public struct State: Decodable, Sendable {
        public let frames: Int
        public let fps: Double
        public let loop: Bool
        public let staticFrame: Int?
        public let loopStartFrame: Int?

        var isValid: Bool {
            (1...150).contains(self.frames) && self.fps.isFinite && (1...15).contains(self.fps)
                && (self.staticFrame.map { (0..<self.frames).contains($0) } ?? true)
                && (self.loopStartFrame.map { self.loop && (1..<self.frames).contains($0) } ?? true)
        }
    }

    // `defaultFor` accepts one provider ID or a list, so one pack can serve several tools.
    struct Providers: Decodable, Sendable {
        let values: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) { self.values = [value] }
            else { self.values = try container.decode([String].self) }
        }
    }

    public var isValid: Bool {
        self.version == 1 && self.width == 72 && self.height == 44
            && self.states.values.allSatisfy(\.isValid)
    }
}

public struct CharacterCatalog: Sendable {
    public let packs: [CharacterPack]
    private let defaults: [String: CharacterPack]

    public init(roots: [URL]) {
        var discovered: [String: CharacterPack] = [:]
        var defaults: [String: CharacterPack] = [:]
        for root in roots {
            let root = root.resolvingSymlinksInPath().standardizedFileURL
            let folders = (try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard discovered[folder.lastPathComponent] == nil,
                      let pack = Self.readPack(folder: folder, root: root) else { continue }
                discovered[pack.id] = pack
                for provider in pack.defaultFor where defaults[provider] == nil { defaults[provider] = pack }
            }
        }
        self.packs = discovered.values.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id < $1.id
        }
        self.defaults = defaults
    }

    public func pack(id: String) -> CharacterPack? { self.packs.first { $0.id == id } }
    public func defaultPack(for provider: String) -> CharacterPack? { self.defaults[provider] }

    private static func isSlug(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        } && value.first != "-" && value.first != "_"
    }

    private static func contained(_ file: URL, in root: URL) -> Bool {
        file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.path + "/")
    }

    private static func data(at file: URL, root: URL, limit: Int) -> Data? {
        guard self.contained(file, in: root),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, (1...limit).contains(size),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= limit else { return nil }
        return data
    }

    private static func readPack(folder: URL, root: URL) -> CharacterPack? {
        let id = folder.lastPathComponent
        guard self.isSlug(id), self.contained(folder, in: root),
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let data = self.data(at: folder.appendingPathComponent("manifest.json"), root: root, limit: 65_536),
              let manifest = try? JSONDecoder().decode(CharacterManifest.self, from: data),
              manifest.isValid,
              Set(manifest.states.keys) == Set(GrokBallEmotion.allCases.map(\.rawValue)),
              manifest.defaultFor?.values.allSatisfy(self.isSlug) ?? true else { return nil }
        let name = manifest.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? id
        guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        for (stateID, state) in manifest.states {
            for frame in 0..<state.frames {
                let file = folder.appendingPathComponent("\(stateID)/\(frame).png")
                guard let data = self.data(at: file, root: root, limit: 262_144), self.validPNG(data) else { return nil }
            }
        }
        return CharacterPack(id: id, name: name, directory: folder.resolvingSymlinksInPath(),
                             defaultFor: manifest.defaultFor?.values ?? [], sortOrder: manifest.sortOrder ?? 0)
    }

    // Discovery checks headers only; the native player rejects images that fail pixel decoding.
    private static func validPNG(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24,
              Array(bytes.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(bytes[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82] else { return false }
        func uint32(_ offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        return uint32(16) == 72 && uint32(20) == 44
    }
}
