#!/usr/bin/env python3
"""Keep public branding and compatibility paths consistent without real accounts."""
from pathlib import Path
import plistlib
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ProjectMetadataTests(unittest.TestCase):
    def test_app_icon_is_declared_and_packaged(self):
        info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIconFile'], 'AppIcon')
        icon = (ROOT / 'Resources/AppIcon.icns').read_bytes()
        self.assertEqual(icon[:4], b'icns')
        self.assertEqual(int.from_bytes(icon[4:8], 'big'), len(icon))
        self.assertIn('cp "$ROOT/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"',
                      (ROOT / 'Scripts/build_app.sh').read_text())

    def test_public_name_and_executable(self):
        info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleName'], 'Upkin')
        self.assertEqual(info['CFBundleDisplayName'], 'Upkin')
        self.assertEqual(info['CFBundleExecutable'], 'Upkin')
        self.assertIn('.executable(name: "Upkin", targets: ["Upkin"])',
                      (ROOT / 'Package.swift').read_text())
        self.assertIn('APP="$ROOT/Upkin.app"', (ROOT / 'Scripts/build_app.sh').read_text())
        self.assertIn('Upkin.app/Contents/Resources/upkin-activity.py',
                      (ROOT / 'Scripts/configure_agent_hooks.py').read_text())

    def test_modules_and_activity_paths_use_upkin(self):
        package = (ROOT / 'Package.swift').read_text()
        for name in ['Upkin', 'UpkinCore', 'UpkinCoreTests']:
            self.assertIn('name: "' + name + '"', package)
            self.assertTrue((ROOT / 'Sources' / name).is_dir())
        self.assertIn('swift run UpkinCoreTests', (ROOT / '.github/workflows/ci.yml').read_text())
        for path in ['Sources/UpkinCore/AgentActivity.swift', 'Scripts/agent_activity_hook.py']:
            self.assertIn('Library/Caches/Upkin/activity', (ROOT / path).read_text())
        for path in (ROOT / 'Sources').rglob('*.swift'):
            for line in path.read_text().splitlines():
                if line.startswith('import ') and 'Core' in line:
                    self.assertNotIn('LimitBar', line)

    def test_neutral_identity_and_licenses(self):
        info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'com.local.Upkin')
        self.assertIn('GNU AFFERO GENERAL PUBLIC LICENSE', (ROOT / 'LICENSE').read_text())
        script = (ROOT / 'Scripts/build_app.sh').read_text()
        self.assertIn('"$ROOT/THIRD_PARTY_NOTICES.md"', script)
        self.assertIn('"$ROOT/ThirdParty/RunCatNeo/LICENSE"', script)
        self.assertIn('Apache License', (ROOT / 'ThirdParty/RunCatNeo/LICENSE').read_text())
        self.assertNotIn('Resources/Runners', script)
        for folder in ['Resources/ProviderIcons', 'ThirdParty/GrokBall', 'Resources/CharacterFrames/grok']:
            for name in ['LICENSE', 'SOURCE.txt']:
                self.assertTrue((ROOT / folder / name).is_file())

    def test_extra_pack_replaces_bundled_folder(self):
        script = (ROOT / 'Scripts/build_app.sh').read_text()
        block = script[script.index('if [[ -n "${UPKIN_EXTRA_CHARACTERS:-}"'):
                       script.index('swift "$ROOT/Scripts/test_character_frames.swift"')]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            extra = root / 'extra' / 'grok'
            destination = root / 'resources' / 'CharacterFrames' / 'grok'
            extra.mkdir(parents=True)
            destination.mkdir(parents=True)
            (extra / 'manifest.json').write_text('{}')
            (extra / '0.png').write_bytes(b'new')
            (destination / 'stale.png').write_bytes(b'old')
            result = subprocess.run(['bash', '-euc', block], check=True, capture_output=True,
                                    text=True, env={**os.environ,
                                    'ROOT': str(ROOT),
                                    'UPKIN_EXTRA_CHARACTERS': str(extra.parent),
                                    'APP_RESOURCES': str(root / 'resources')})
            self.assertFalse((destination / 'stale.png').exists())
            self.assertEqual((destination / '0.png').read_bytes(), b'new')
            self.assertIn('Replacing bundled character: grok', result.stdout)

    def test_extra_packs_reject_repository_paths_and_symlinks(self):
        script = (ROOT / 'Scripts/build_app.sh').read_text()
        block = script[script.index('if [[ -n "${UPKIN_EXTRA_CHARACTERS:-}"'):
                       script.index('swift "$ROOT/Scripts/test_character_frames.swift"')]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            repo = root / 'repo'
            repo.mkdir()
            extra = root / 'extra'
            extra.mkdir()
            (extra / 'link').symlink_to(repo, target_is_directory=True)
            for source, message in [(repo, 'outside the repository'), (extra, 'symlinks')]:
                result = subprocess.run(['bash', '-euc', block], capture_output=True, text=True,
                                        env={**os.environ, 'ROOT': str(repo.resolve()),
                                             'UPKIN_EXTRA_CHARACTERS': str(source),
                                             'APP_RESOURCES': str(root / 'resources')})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
            self.assertFalse((root / 'resources').exists())

    def test_clawd_upstream_notice_is_preserved(self):
        source = (ROOT / 'Resources/Clawd/SOURCE.txt').read_text()
        self.assertIn('abderrahimghazali/clawd-pet', source)
        self.assertIn('6c1a9f0e47e1b9643bdb6403f1f8f32285988375', source)
        for folder in ['Resources/Clawd', 'Resources/CharacterFrames/clawd']:
            license_text = (ROOT / folder / 'LICENSE').read_text()
            self.assertIn('GNU AFFERO GENERAL PUBLIC LICENSE', license_text)
            self.assertIn('Copyright (c) 2026 Abderrahim GHAZALI', license_text)
            self.assertIn('MIT License', license_text)

    def test_chatgpt_character_is_included_in_default_build_resources(self):
        import json
        for folder in ['Resources/ChatGPT', 'Resources/CharacterFrames/chatgpt']:
            self.assertTrue((ROOT / folder / 'LICENSE').is_file())
            self.assertTrue((ROOT / folder / 'SOURCE.txt').is_file())
        manifest = json.loads((ROOT / 'Resources/CharacterFrames/chatgpt/manifest.json').read_text())
        self.assertEqual(manifest['defaultFor'], 'codex')
        self.assertEqual(set(manifest['states']), {'02', '30', '32', '35', '33', '34', '11'})

    def test_clawd_is_an_unofficial_rendition(self):
        source = (ROOT / 'Resources/Clawd/SOURCE.txt').read_text().lower()
        self.assertIn('original', source)
        self.assertIn('unofficial', source)


if __name__ == '__main__':
    unittest.main()
