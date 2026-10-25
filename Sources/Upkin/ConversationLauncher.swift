import AppKit
import UpkinCore

@MainActor
enum ConversationLauncher {
    enum LaunchError: LocalizedError {
        case desktopUnavailable

        var errorDescription: String? { "打开 Codex 桌面会话失败，请检查桌面应用是否已安装。" }
    }

    static func open(_ conversation: Conversation) async throws {
        if let url = conversation.desktopURL {
            guard NSWorkspace.shared.open(url) else { throw LaunchError.desktopUnavailable }
        } else {
            try await ITermConversationLauncher.open(conversation)
        }
    }
}
