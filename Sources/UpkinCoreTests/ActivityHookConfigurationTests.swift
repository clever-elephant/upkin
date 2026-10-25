import Foundation
import UpkinCore

func configuresActivityHooks() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let script = home.appendingPathComponent("app's folder/upkin-activity.py")
    try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("# fixture".utf8).write(to: script)
    let configuration = ActivityHookConfiguration(home: home, script: script)
    let claude = home.appendingPathComponent(".claude/settings.json")
    try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
    let foreign: [String: Any] = ["matcher": "keep", "hooks": [["type": "command", "command": "other-tool"]]]
    let original: [String: Any] = ["theme": "dark", "hooks": ["Stop": [foreign,
        ["hooks": [["type": "command", "command": "python /old/codex-limit-bar-activity.py claude"]]]]]]
    try JSONSerialization.data(withJSONObject: original).write(to: claude)
    func status(_ provider: CodingAgent) throws -> ActivityHookConfiguration.Status { try configuration.status(for: provider) }
    expect((try? status(.claude) == .outdated) == true, "Legacy Claude hook needs updating")
    expect((try? status(.grok) == .missing) == true, "Absent Grok hook is unconfigured")
    try configuration.configure(.claude, install: true)
    expect((try? status(.claude) == .configured) == true, "All events configured without waiting for an activity event")
    let first = try Data(contentsOf: claude)
    let installed = try JSONSerialization.jsonObject(with: first) as! [String: Any]
    expect(installed["theme"] as? String == "dark", "Preserve unrelated settings")
    let stops = (installed["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
    expect((stops[0] as NSDictionary).isEqual(to: foreign), "Preserve other hooks and matchers")
    let command = ((stops[1]["hooks"] as! [[String: Any]])[0]["command"] as! String)
    expect(command.contains("'\\''"), "Quote apostrophes in app paths")
    try configuration.configure(.claude, install: true)
    expect((try? Data(contentsOf: claude) == first) == true, "Updates are idempotent")
    expect((try? FileManager.default.contentsOfDirectory(atPath: claude.deletingLastPathComponent().path) == ["settings.json"]) == true, "No extra backup files")
    let hooks = installed["hooks"] as! [String: Any]
    var partial = installed
    var partialHooks = hooks
    partialHooks.removeValue(forKey: "PreToolUse")
    partial["hooks"] = partialHooks
    try JSONSerialization.data(withJSONObject: partial).write(to: claude)
    expect((try? status(.claude) == .outdated) == true, "Partial event coverage needs updating")
    try configuration.configure(.claude, install: true)
    try configuration.configure(.claude, install: false)
    expect((try? status(.claude) == .missing) == true, "Removal only removes Upkin hooks")
    let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: claude)) as! [String: Any]
    expect(((restored["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]).count == 1, "Foreign hook survives removal")
    let legacy = home.appendingPathComponent(".grok/hooks/codex-limit-bar-activity.json")
    try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: original).write(to: legacy)
    expect((try? status(.grok) == .outdated) == true, "Detect Grok legacy file")
    try configuration.configure(.grok, install: true)
    expect((try? status(.grok) == .configured) == true, "Migrate Grok without duplicate observers")
    try configuration.configure(.grok, install: false)
    expect((try? status(.grok) == .missing) == true, "Remove Grok observers from both paths")
    try Data("broken".utf8).write(to: legacy)
    let grok = home.appendingPathComponent(".grok/hooks/upkin-activity.json")
    let before = try Data(contentsOf: grok)
    do { try configuration.configure(.grok, install: true); expect(false, "Reject malformed legacy config") }
    catch { }
    expect((try? Data(contentsOf: grok) == before) == true, "Validate all configs before writing")
    try comparesGUIAndCLIHookConfiguration(home: home)
    try FileManager.default.removeItem(at: script)
    do { try configuration.configure(.claude, install: true); expect(false, "Reject missing app resource") }
    catch { }
    print("Activity hooks: migration, provider isolation, preservation, idempotence, quoting, partial config, removal and invalid input passed")
}

private func comparesGUIAndCLIHookConfiguration(home: URL) throws {
    let script = home.appendingPathComponent("app folder/upkin-activity.py")
    try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("# fixture".utf8).write(to: script)
    let gui = home.appendingPathComponent("gui")
    let cli = home.appendingPathComponent("cli")
    let python = home.appendingPathComponent("python executable")
    try FileManager.default.createSymbolicLink(at: python, withDestinationURL: URL(fileURLWithPath: "/usr/bin/python3"))
    let configuration = ActivityHookConfiguration(home: gui, script: script, python: python.path)
    let paths = [".claude/settings.json", ".grok/hooks/upkin-activity.json", ".grok/hooks/codex-limit-bar-activity.json"]
    let foreign: [String: Any] = ["matcher": "keep", "hooks": [
        ["type": "command", "command": "/other/upkin-activity-helper"],
        ["type": "command", "command": "/other/upkin-activity.py-helper"],
        ["type": "command", "command": "/other/codex-limit-bar-activity.py.backup"]]]
    let own: [String: Any] = ["hooks": [["type": "command", "command": "python '/old/codex-limit-bar-activity.py' claude"]]]
    let seed = try JSONSerialization.data(withJSONObject: ["theme": "dark", "hooks": [
        "Stop": [foreign, own], "StopCancelled": [foreign, own], "FutureEvent": [foreign, own]]])
    for root in [gui, cli] {
        for path in paths {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try seed.write(to: file)
        }
    }
    let scripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Scripts")
    for install in [true, false] {
        try configuration.configure(.claude, install: install)
        try configuration.configure(.grok, install: install)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); from configure_agent_hooks import configure; configure(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], python=sys.argv[5])",
                             scripts.path, cli.path, script.path, install ? "install" : "remove", python.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        expect(process.terminationStatus == 0, "CLI fixture succeeds without reading real configuration")
        for path in paths {
            let left = try JSONSerialization.jsonObject(with: Data(contentsOf: gui.appendingPathComponent(path))) as! NSDictionary
            let right = try JSONSerialization.jsonObject(with: Data(contentsOf: cli.appendingPathComponent(path))) as! NSDictionary
            expect(left.isEqual(right), "GUI/CLI agree on events, migration, precise markers and quoted commands: \(path)")
            let hooks = left["hooks"] as! [String: Any]
            expect((hooks["FutureEvent"] as! NSArray).isEqual(to: [foreign]), "Unknown events lose only this app's old observer")
        }
    }
    for path in paths {
        let guiFiles = try FileManager.default.contentsOfDirectory(at: gui.appendingPathComponent(path).deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let backups = try FileManager.default.contentsOfDirectory(at: cli.appendingPathComponent(path).deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "bak" }
        expect(!guiFiles.contains { $0.pathExtension == "bak" } && !backups.isEmpty,
               "GUI stays backup-free while the CLI keeps its existing backup contract")
    }
    print("Hook installers: GUI/CLI install/removal parity, exact markers, unknown events and backup differences passed")
}
