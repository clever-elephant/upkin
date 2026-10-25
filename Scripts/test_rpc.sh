#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/upkin-rpc-test.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
cat > "$TEMP/check.swift" <<'SWIFT'
import Darwin
import Foundation

@main
struct Check {
    static func main() async throws {
        // Keep the default signal disposition: this regression must catch process termination.
        signal(SIGPIPE, SIG_DFL)
        let client = try CodexRPCClient(executablePath: "/bin/sh",
            arguments: ["-c", "exec 0<&-; sleep 1"], environment: [:])
        defer { client.shutdown() }
        try await Task.sleep(for: .milliseconds(300))
        do {
            try await client.initialize()
            preconditionFailure("Writing to closed CLI stdin must fail")
        } catch CodexUsageFetchError.requestFailed {
            print("PASS: closed CLI stdin throws a request error without SIGPIPE")
        }
        let exited = try CodexRPCClient(executablePath: "/usr/bin/true", arguments: [], environment: [:])
        defer { exited.shutdown() }
        try await Task.sleep(for: .milliseconds(300))
        do {
            try await exited.initialize()
            preconditionFailure("An exited CLI must fail")
        } catch is CodexUsageFetchError {
            print("PASS: early CLI exit is recoverable")
        }
        let responder = try CodexRPCClient(executablePath: "/bin/sh", arguments: ["-c", #"""
        read -r request
        printf '%s\n' '{"id":1,"result":{}}'
        read -r notification
        read -r request
        printf '%s\n' '{"id":2,"result":{"ok":true}}'
        read -r notification
        """#], environment: [:])
        defer { responder.shutdown() }
        try await responder.initialize()
        let result = try await responder.requestData(method: "fixture", timeout: 1)
        let object = try JSONSerialization.jsonObject(with: result) as! [String: Bool]
        precondition(object["ok"] == true)
        print("PASS: initialization, notification and newline-delimited requests")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 6 \
    "$ROOT/Sources/UpkinCore/CodexRPCUsageFetcher.swift" \
    "$ROOT/Sources/UpkinCore/CodexUsageSnapshot.swift" \
    "$ROOT/Sources/UpkinCore/UpkinPreferences.swift" \
    "$TEMP/check.swift" -o "$TEMP/check"
python3 - "$TEMP/check" <<'PY'
import subprocess, sys
subprocess.run([sys.argv[1]], check=True, timeout=12)
PY
