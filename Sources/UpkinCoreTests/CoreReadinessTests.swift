import Darwin
import Foundation
import UpkinCore

func handlesExtremeResetDates() throws {
    let now = Date(timeIntervalSince1970: 0)
    for interval in [Double.nan, .infinity, -.infinity, Double(Int.max), -Double.greatestFiniteMagnitude] {
        let window = UsageWindow(usedPercent: 10, windowMinutes: 300,
                                 resetsAt: Date(timeIntervalSince1970: interval))
        expect(window.resetText(relativeTo: now) == (interval.isFinite && interval < 0 ? "resetting now" : "reset unknown"),
               "Invalid or out-of-range reset dates never trap during integer conversion")
    }
    let payload = #"{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":9223372036854775807}}}"#
    let snapshot = try CodexUsageSnapshot.decodeRateLimits(from: Data(payload.utf8))
    expect(snapshot.fiveHour?.resetText(relativeTo: now) == "reset unknown", "Extreme RPC reset timestamps stay printable")
    print("Reset dates: nonfinite, huge, expired and extreme RPC timestamps passed")
}

func handlesBrokenRPCProcesses() async throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent("upkin-rpc-test-" + UUID().uuidString)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("codex")
    let pidFile = directory.appendingPathComponent("pid")
    let response = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}}"#
    let handshake = """
    IFS= read -r request || exit
    printf '%s\\n' '{"id":1,"result":{}}'
    IFS= read -r notification || exit
    IFS= read -r request || exit
    """
    let cases: [(String, Bool, Bool)] = [
        (handshake + "\nprintf '%s\\n' '\(response)'\nexec /bin/sleep 30", true, false),
        (handshake.replacingOccurrences(of: "printf '%s\\n' '{\"id\":1,\"result\":{}}'",
            with: "printf '%s\\n' '{\"id\":true,\"error\":{\"message\":\"not an integer ID\"}}' '{\"id\":1,\"result\":{}}'")
            + "\nprintf '%s\\n' '{\"id\":2.5,\"error\":{\"message\":\"fractional ID\"}}' '\(response)'", true, false),
        (handshake + "\nprintf '%s\\n' '{\"id\":2,\"result\":null}'", false, false),
        ("printf '%s\\n' 'not JSON'", false, false),
        ("/usr/bin/awk 'BEGIN { for (i=0; i<1048577; i++) printf \"x\" }'", false, false),
        ("/usr/bin/awk 'BEGIN { for (i=0; i<1048577; i++) printf \"x\"; printf \"\\n\" }'", false, false),
        ("IFS= read -r request\nexec /bin/sleep 30", false, true),
        ("IFS= read -r request\nexec /bin/sleep 30", false, false),
    ]
    for (index, test) in cases.enumerated() {
        let script = "#!/bin/sh\ntrap '' TERM\nprintf '%s\\n' \"$$\" > \"$UPKIN_TEST_PID\"\n" + test.0 + "\n"
        try Data(script.utf8).write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try? manager.removeItem(at: pidFile)
        let start = Date()
        let task = Task { try await CodexRPCUsageFetcher(environment: [
            "PATH": directory.path + ":/usr/bin:/bin", "UPKIN_TEST_PID": pidFile.path,
        ]).fetch() }
        if test.2 {
            for _ in 0..<100 where !manager.fileExists(atPath: pidFile.path) {
                try await Task.sleep(for: .milliseconds(10))
            }
            task.cancel()
        }
        do {
            let snapshot = try await task.value
            expect(test.1 && snapshot.fiveHour?.remainingPercent == 75, "Fake RPC success decodes the matching response")
        } catch {
            expect(!test.1, "Valid fake RPC response succeeds: \(error)")
            if index == cases.count - 1 {
                guard case CodexUsageFetchError.timeout = error else {
                    expect(false, "Silent RPC fails with a typed timeout, not another error"); return
                }
            }
        }
        expect(Date().timeIntervalSince(start) < (index == cases.count - 1 ? 12 : 4),
               "Broken or cancelled RPC exits promptly")
        let pid = try Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        guard let pid else { expect(false, "Fake CLI recorded its PID"); return }
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        for _ in 0..<150 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        expect(kill(pid, 0) == -1 && errno == ESRCH, "RPC cleanup reaps even a CLI that ignores SIGTERM")
    }
    print("RPC processes: success, exact IDs, null/malformed data, oversized lines, cancellation, timeout and SIGKILL cleanup passed")
}

func boundsTerminalAutomationProcesses() throws {
    let output = try ITermConversationLauncher.run("/bin/cat", arguments: [], input: "fixture script", timeout: 2)
    expect(output == "fixture script", "Terminal automation still writes and closes stdin, then drains stdout")
    let start = Date()
    do {
        _ = try ITermConversationLauncher.run("/bin/sleep", arguments: ["30"], timeout: 0.2)
        expect(false, "Unresponsive automation must fail")
    } catch {
        expect(Date().timeIntervalSince(start) < 3, "Automation has an outer process deadline")
    }
    do {
        _ = try ITermConversationLauncher.run("/bin/sh", arguments: ["-c", "exit 0"],
                                             input: String(repeating: "x", count: 1_048_576), timeout: 2)
        expect(false, "Writing to an exited process must report a broken pipe")
    } catch {}
    print("Terminal automation: stdin/EOF, process deadline and broken-pipe handling passed")
}
