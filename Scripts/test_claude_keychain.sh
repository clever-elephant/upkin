#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import subprocess
import tempfile

source = Path('Sources/UpkinCore/ClaudeUsageFetcher.swift').read_text()
revision = source[source.index('    private static func readCredentialRevision()'):source.index('    private static func readCredentials(')]
reader = source[source.index('    private static func readCredentials('):]
assert 'Self.copyKeychainItem(query, allowInteraction: false, result: &result)' in revision
assert 'Self.copyKeychainItem(query, allowInteraction: allowInteraction, result: &result)' in reader
assert source.count('SecItemCopyMatching(') == 1
helper = source[source.index('    private static let keychainLock'):source.index('    private static func readCredentialRevision()')]
# Exercise the production guard with a probe instead of reading any stored credential.
helper = helper.replace('SecItemCopyMatching(query as CFDictionary, &result)', 'probe()')
fixture = '''import Foundation
import Security
struct Fixture {
    nonisolated(unsafe) static var expected = false
''' + helper + '''
    private static func probe() -> OSStatus {
        var allowed: DarwinBoolean = true
        precondition(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess)
        precondition(allowed.boolValue == expected, "Interaction policy must apply during the query")
        return errSecItemNotFound
    }
    static func verify() {
        var original: DarwinBoolean = true
        precondition(SecKeychainGetUserInteractionAllowed(&original) == errSecSuccess)
        defer { _ = SecKeychainSetUserInteractionAllowed(original.boolValue) }
        for initial in [false, true] {
            precondition(SecKeychainSetUserInteractionAllowed(initial) == errSecSuccess)
            for requested in [false, true] {
                expected = requested
                var result: CFTypeRef?
                precondition(copyKeychainItem([:], allowInteraction: requested, result: &result) == errSecItemNotFound)
                var restored: DarwinBoolean = true
                precondition(SecKeychainGetUserInteractionAllowed(&restored) == errSecSuccess)
                precondition(restored.boolValue == initial, "Query failure must restore the previous policy")
            }
        }
    }
}
Fixture.verify()
print("Claude keychain: silent probes, explicit consent and interaction restoration passed")
'''
with tempfile.TemporaryDirectory(prefix='upkin-keychain-test-') as directory:
    path = Path(directory) / 'main.swift'
    path.write_text(fixture)
    subprocess.run(['swift', str(path)], check=True)
PY
