#!/usr/bin/env python3
import contextlib
import io
import json
import os
import hashlib
import shlex
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from concurrent.futures import ThreadPoolExecutor

import agent_activity_hook as hook
import configure_agent_hooks as installer


class ActivityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def event(self, provider, event, session='same', **extra):
        payload = dict(hook_event_name=event, session_id=session, **extra)
        if provider == 'grok':
            payload.update(hookEventName=event, sessionId=session)
        hook.record(provider, payload, self.root, now=1000)
        return self.states()[provider, session]

    def states(self):
        result = {}
        for path in self.root.glob('*.json'):
            d = json.loads(path.read_text())
            result[d['provider'], d['sessionID']] = d
        return result

    def test_independent_sources_and_concurrent_sessions(self):
        self.event('grok', 'UserPromptSubmit')
        self.event('claude', 'UserPromptSubmit')
        self.event('grok', 'UserPromptSubmit', 'other')
        self.event('grok', 'Notification', notification_type='task_complete')
        states = self.states()
        self.assertEqual(len(states), 3)
        self.assertEqual(states['grok', 'same']['phase'], 'completed')
        self.assertEqual(states['claude', 'same']['phase'], 'thinking')
        self.assertEqual(states['grok', 'other']['phase'], 'thinking')

    def test_only_start_events_advance_started_at(self):
        for event, now in [('SessionStart', 1000), ('UserPromptSubmit', 1001),
                           ('PreToolUse', 1002), ('PostToolUse', 1003),
                           ('PermissionRequest', 1004), ('Stop', 1005),
                           ('SessionEnd', 1006)]:
            hook.record('claude', dict(hook_event_name=event, session_id='same'), self.root, now=now)
            state = self.states()['claude', 'same']
            self.assertEqual(state['startedAt'], min(now, 1001))
            self.assertEqual(state['updatedAt'], 1005 if event == 'SessionEnd' else now)
        # Old records remain readable and gain a start time only on a real start.
        path = next(self.root.glob('*.json'))
        state.pop('startedAt')
        path.write_text(json.dumps(state))
        self.assertNotIn('startedAt', self.event('claude', 'PreToolUse'))
        self.assertEqual(self.event('claude', 'UserPromptSubmit')['startedAt'], 1000)

    def test_turn_started_at_prompt_resume_and_missing_grok_prompt(self):
        for provider in ('claude', 'grok'):
            def record(event, now):
                payload = dict(hook_event_name=event, session_id=provider)
                if provider == 'grok':
                    payload.update(hookEventName=event, sessionId=provider)
                hook.record(provider, payload, self.root, now=now)
                return self.states()[provider, provider]
            self.assertNotIn('turnStartedAt', record('SessionStart', 1000))
            self.assertEqual(record('UserPromptSubmit', 1001)['turnStartedAt'], 1001)
            self.assertEqual(record('PreToolUse', 1002)['turnStartedAt'], 1001)
            self.assertEqual(record('UserPromptSubmit', 1003)['turnStartedAt'], 1003)
            self.assertEqual(record('PermissionRequest', 1004)['turnStartedAt'], 1003)
            self.assertEqual(record('PostToolUse', 1005)['turnStartedAt'], 1005)
            self.assertEqual(record('PreToolUse', 1006)['turnStartedAt'], 1005)
        self.event('grok', 'SessionStart', session='no-prompt')
        state = self.event('grok', 'PreToolUse', session='no-prompt')
        self.assertEqual(state['turnStartedAt'], 1000)

    def test_compatibility_invocation_is_not_claude_activity(self):
        hook.record('claude', dict(hookEventName='user_prompt_submit', sessionId='g',
                                  hook_event_name='UserPromptSubmit', session_id='g'), self.root)
        self.assertEqual(self.states(), {})

    def test_waiting_and_parallel_tools(self):
        self.event('claude', 'UserPromptSubmit')
        self.event('claude', 'PreToolUse', tool_use_id='a')
        self.event('claude', 'PreToolUse', tool_use_id='b')
        self.assertEqual(self.event('claude', 'PermissionRequest')['phase'], 'waiting')
        self.assertEqual(self.event('claude', 'PostToolUse', tool_use_id='a')['phase'], 'working')
        self.assertEqual(self.event('claude', 'PostToolUse', tool_use_id='b')['phase'], 'thinking')

    def test_claude_completion_survives_idle_and_exit(self):
        self.event('claude', 'UserPromptSubmit')
        self.assertEqual(self.event('claude', 'Stop')['phase'], 'completed')
        for event, extra in [('Notification', {'notification_type': 'idle_prompt'}), ('SessionEnd', {})]:
            hook.record('claude', dict(hook_event_name=event, session_id='same', **extra),
                        self.root, now=1100)
            self.assertEqual(self.states()['claude', 'same']['phase'], 'completed')
            self.assertEqual(self.states()['claude', 'same']['updatedAt'], 1000)
        self.assertEqual(self.event('claude', 'UserPromptSubmit')['phase'], 'thinking')
        self.event('claude', 'PreToolUse', tool_use_id='a')
        self.assertEqual(self.event('claude', 'Stop')['phase'], 'working')
        self.event('claude', 'PostToolUse', tool_use_id='a')
        self.assertEqual(self.event('claude', 'Stop', background_tasks=[{}])['phase'], 'working')
        self.assertEqual(self.event('claude', 'StopFailure')['phase'], 'error')
        self.assertEqual(self.event('claude', 'SessionEnd')['phase'], 'idle')

    def test_no_false_completion_and_error_recovery(self):
        self.event('grok', 'UserPromptSubmit', promptId='first')
        self.assertEqual(self.event('grok', 'Stop', promptId='first')['phase'], 'unknown')
        self.event('grok', 'UserPromptSubmit', promptId='next')
        self.assertEqual(self.event('grok', 'StopCancelled', promptId='first')['phase'], 'thinking')
        self.assertEqual(self.event('grok', 'Stop', promptId='next', backgroundTasks=[{}])['phase'], 'working')
        self.assertEqual(self.event('grok', 'StopFailure', promptId='next')['phase'], 'error')
        self.assertEqual(self.event('grok', 'PreToolUse', toolUseId='a')['phase'], 'working')
        self.assertEqual(self.event('grok', 'SessionEnd')['phase'], 'idle')

    def test_no_text_or_child_sessions(self):
        self.root.chmod(0o755)
        self.event('grok', 'UserPromptSubmit', prompt='PRIVATE', tool_input={'command': 'PRIVATE'})
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        self.assertNotIn('PRIVATE', next(self.root.glob('*.json')).read_text())
        before = self.states()
        hook.record('grok', dict(hookEventName='Stop', sessionId='child', subagentType='explore'), self.root)
        hook.record('claude', dict(hook_event_name='Stop', session_id='child', agent_id='sub'), self.root)
        hook.record('claude', dict(hook_event_name='Stop', session_id='bad\nname'), self.root)
        self.assertEqual(self.states(), before)
        self.assertEqual(next(self.root.glob('*.json')).stat().st_mode & 0o777, 0o600)

    def test_concurrent_writes(self):
        self.event('claude', 'UserPromptSubmit')
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda i: self.event('claude', 'PreToolUse', tool_use_id=str(i)), range(16)))
        self.assertEqual(len(self.states()['claude', 'same']['tools']), 16)

    def test_malformed_stdin_is_passive(self):
        result = subprocess.run([sys.executable, str(Path(hook.__file__)), 'claude',
                                 '--directory', str(self.root)], input=b'{', capture_output=True)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b'', b''))
        self.assertEqual(self.states(), {})

    def test_activity_symlinks_do_not_touch_targets(self):
        victim = self.root / 'victim'
        victim.write_text('PRIVATE')
        victim.chmod(0o644)
        cache = self.root / 'cache'
        cache.mkdir()
        key = 'claude-' + hashlib.sha256(b'same').hexdigest()
        payload = dict(hook_event_name='UserPromptSubmit', session_id='same')
        for suffix in ('.lock', '.json'):
            link = cache / (key + suffix)
            link.symlink_to(victim)
            with self.assertRaises(OSError):
                hook.record('claude', payload, cache)
            link.unlink()
            self.assertEqual(victim.read_text(), 'PRIVATE')
            self.assertEqual(victim.stat().st_mode & 0o777, 0o644)
        alias = self.root / 'alias'
        alias.symlink_to(cache, target_is_directory=True)
        with self.assertRaises(ValueError):
            hook.record('claude', payload, alias)

    def test_existing_cache_does_not_carry_conversation_fields(self):
        self.event('claude', 'UserPromptSubmit')
        path = next(self.root.glob('*.json'))
        state = json.loads(path.read_text())
        state['prompt'] = 'PRIVATE'
        path.write_text(json.dumps(state))
        self.event('claude', 'PreToolUse')
        self.assertNotIn('PRIVATE', path.read_text())

    def test_installer_rejects_symlinked_files_and_parents(self):
        outside = self.root / 'outside'
        outside.mkdir()
        victim = outside / 'settings.json'
        victim.write_text('{}')
        home = self.root / 'home'
        home.mkdir()
        parent = home / '.claude'
        parent.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            installer.configure(home, home / 'upkin-activity.py', 'install')
        parent.unlink()
        parent.mkdir()
        (parent / 'settings.json').symlink_to(victim)
        with self.assertRaises(ValueError):
            installer.configure(home, home / 'upkin-activity.py', 'remove')
        self.assertEqual(victim.read_text(), '{}')
        self.assertEqual(list(outside.iterdir()), [victim])
        self.assertFalse((home / '.grok').exists())

    def test_installer_quotes_script_and_python_paths(self):
        binary = self.root / "space ' ; $(echo injected)/upkin-activity.py"
        python = "/python path/'python"
        with contextlib.redirect_stdout(io.StringIO()):
            installer.configure(self.root, binary, 'install', python=python)
        hooks = json.loads((self.root / '.claude/settings.json').read_text())['hooks']
        command = hooks['Stop'][0]['hooks'][0]['command']
        self.assertEqual(shlex.split(command), [python, str(binary), 'claude'])

    def test_backup_is_exclusive_and_private_at_creation(self):
        path = self.root / '.claude/settings.json'
        path.parent.mkdir()
        path.write_text('{}')
        real_open = os.open
        backups = []

        def checked_open(file, flags, mode=0o777):
            if str(file).endswith('.bak'):
                backups.append(file)
                self.assertTrue(flags & os.O_EXCL)
                self.assertEqual(mode, 0o600)
            return real_open(file, flags, mode)

        with mock.patch.object(installer.os, 'open', side_effect=checked_open), \
                contextlib.redirect_stdout(io.StringIO()):
            installer.configure(self.root, self.root / 'upkin-activity.py', 'install')
        self.assertEqual(len(backups), 1)
        self.assertEqual(Path(backups[0]).read_text(), '{}')

    def test_installer_preview_idempotence_and_removal(self):
        path = self.root / '.claude/settings.json'
        path.parent.mkdir()
        original = {'theme': 'dark', 'hooks': {'Stop': [{'matcher': 'keep', 'hooks': [
            {'type': 'command', 'command': 'existing-hook'},
            {'type': 'command', 'command': '/old/upkin-activity.py claude'}]}]}}
        path.write_text(json.dumps(original))
        before = path.read_bytes()
        script = self.root / 'upkin-activity.py'
        with contextlib.redirect_stdout(io.StringIO()):
            installer.configure(self.root, script, 'preview')
            self.assertEqual(path.read_bytes(), before)
            installer.configure(self.root, script, 'install')
            first = path.read_bytes()
            installer.configure(self.root, script, 'install')
            self.assertEqual(path.read_bytes(), first)
            self.assertEqual(len(json.loads(first)['hooks']['Stop']), 2)
            installer.configure(self.root, script, 'remove')
        restored = json.loads(path.read_bytes())
        self.assertEqual(restored['theme'], 'dark')
        self.assertEqual(restored['hooks']['Stop'], [{'matcher': 'keep', 'hooks': [
            {'type': 'command', 'command': 'existing-hook'}]}])
        self.assertEqual(json.loads((self.root / '.grok/hooks/upkin-activity.json').read_bytes()), {'hooks': {}})

    def test_provider_events_and_legacy_cleanup(self):
        path = self.root / '.claude/settings.json'
        path.parent.mkdir()
        foreign = {'type': 'command', 'command': 'existing-hook'}
        path.write_text(json.dumps({'hooks': {'StopCancelled': [{'hooks': [
            foreign, {'type': 'command', 'command': '/old/upkin-activity.py claude'}]}]}}))
        with contextlib.redirect_stdout(io.StringIO()):
            installer.configure(self.root, self.root / 'upkin-activity.py', 'install')
        claude = json.loads(path.read_text())['hooks']
        self.assertEqual(claude['StopCancelled'], [{'hooks': [foreign]}])
        grok = json.loads((self.root / '.grok/hooks/upkin-activity.json').read_text())['hooks']
        self.assertIn('StopCancelled', grok)
        path.write_text('{}')
        with contextlib.redirect_stdout(io.StringIO()):
            installer.configure(self.root, self.root / 'upkin-activity.py', 'install')
        self.assertNotIn('StopCancelled', json.loads(path.read_text())['hooks'])

    def test_exact_script_marker_unknown_event_cleanup_and_backups(self):
        path = self.root / '.claude/settings.json'
        path.parent.mkdir()
        foreign = {'matcher': 'keep', 'hooks': [
            {'type': 'command', 'command': '/other/upkin-activity-helper'},
            {'type': 'command', 'command': '/other/upkin-activity.py-helper'},
            {'type': 'command', 'command': '/other/codex-limit-bar-activity.py.backup'}]}
        own = {'hooks': [{'type': 'command', 'command': "python '/old/upkin-activity.py' claude"}]}
        original = json.dumps({'hooks': {'FutureEvent': [foreign, own]}}).encode()
        path.write_bytes(original)
        with contextlib.redirect_stdout(io.StringIO()):
            installer.configure(self.root, self.root / 'upkin-activity.py', 'install')
            self.assertEqual(json.loads(path.read_text())['hooks']['FutureEvent'], [foreign])
            installer.configure(self.root, self.root / 'upkin-activity.py', 'remove')
        self.assertEqual(json.loads(path.read_text()), {'hooks': {'FutureEvent': [foreign]}})
        backups = list(path.parent.glob('*.bak'))
        self.assertEqual(len(backups), 2)
        self.assertIn(original, [backup.read_bytes() for backup in backups])
        self.assertTrue(all(backup.stat().st_mode & 0o777 == 0o600 for backup in backups))

    def test_invalid_second_configuration_does_not_modify_first(self):
        claude = self.root / '.claude/settings.json'
        grok = self.root / '.grok/hooks/upkin-activity.json'
        claude.parent.mkdir(); grok.parent.mkdir(parents=True)
        claude.write_text('{}'); grok.write_text('broken')
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(ValueError):
            installer.configure(self.root, self.root / 'upkin-activity.py', 'install')
        self.assertEqual(claude.read_text(), '{}')

    def test_rename_cleans_legacy_observers_without_duplicates(self):
        claude = self.root / '.claude/settings.json'
        old_grok = self.root / '.grok/hooks/codex-limit-bar-activity.json'
        claude.parent.mkdir(); old_grok.parent.mkdir(parents=True)
        old = {'type': 'command', 'command': '/old/codex-limit-bar-activity.py grok'}
        foreign = {'type': 'command', 'command': 'existing-hook'}
        config = {'theme': 'dark', 'hooks': {'Stop': [{'hooks': [old, foreign]}]}}
        claude.write_text(json.dumps(config)); old_grok.write_text(json.dumps(config))
        script = self.root / 'upkin-activity.py'
        with contextlib.redirect_stdout(io.StringIO()):
            installer.configure(self.root, script, 'install')
            first = claude.read_bytes(), old_grok.read_bytes()
            installer.configure(self.root, script, 'install')
        self.assertEqual(first, (claude.read_bytes(), old_grok.read_bytes()))
        self.assertEqual(json.loads(old_grok.read_text()),
                         {'theme': 'dark', 'hooks': {'Stop': [{'hooks': [foreign]}]}})
        commands = [h['command'] for e in json.loads(claude.read_text())['hooks']['Stop'] for h in e['hooks']]
        self.assertEqual(commands, ['existing-hook', str(Path(sys.executable)) + ' ' + str(script) + ' claude'])

    def test_invalid_legacy_configuration_does_not_modify_new_files(self):
        old = self.root / '.grok/hooks/codex-limit-bar-activity.json'
        old.parent.mkdir(parents=True); old.write_text('broken')
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(ValueError):
            installer.configure(self.root, self.root / 'upkin-activity.py', 'install')
        self.assertFalse((self.root / '.claude/settings.json').exists())
        self.assertFalse((self.root / '.grok/hooks/upkin-activity.json').exists())


if __name__ == '__main__':
    unittest.main()
