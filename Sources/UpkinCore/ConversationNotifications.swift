import Foundation

extension Conversation {
    public var notificationInfo: [String: String] {
        var info = ["id": self.id, "provider": self.provider?.rawValue ?? "codex",
                    "source": self.source.rawValue, "title": self.displayTitle]
        info["cwd"] = self.cwd
        return info
    }

    public init?(notificationInfo info: [String: String]) {
        guard let id = info["id"], let name = info["provider"],
              name == "codex" || CodingAgent(rawValue: name) != nil,
              let rawSource = info["source"], let source = ConversationSource(rawValue: rawSource) else { return nil }
        self.init(id: id, provider: CodingAgent(rawValue: name), title: info["title"], cwd: info["cwd"],
                  phase: .completed, updatedAt: 0, source: source)
        guard ITermConversationLauncher.sessionID(for: self) != nil else { return nil }
    }
}
