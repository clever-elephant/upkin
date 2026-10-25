#!/usr/bin/env python3
"""Preview by default. --install adds only this app's observers; --remove removes only them."""
import argparse
from datetime import datetime, timezone
import json
import os
import re
from pathlib import Path
import shlex
import sys
import tempfile

from agent_activity_hook import EVENTS

LEGACY_MARKER = 'codex-limit-bar-activity'


def check_path(home, path):
    for component in (path, *path.parents):
        if component == home:
            break
        if component.is_symlink():
            raise ValueError(f'Symlink in hook configuration path: {component}')


def configure(home, binary, mode, python=sys.executable):
    if mode not in ('preview', 'install', 'remove'):
        raise ValueError('Invalid configuration mode')
    home = home.resolve()
    targets = [('claude', home / '.claude/settings.json'),
               ('grok', home / '.grok/hooks/upkin-activity.json')]
    legacy_grok = home / '.grok/hooks' / (LEGACY_MARKER + '.json')
    for _, path in [*targets, ('grok', legacy_grok)]:
        check_path(home, path)
    if legacy_grok.exists():
        targets.append(('grok', legacy_grok))
    changes = []
    for provider, path in targets:
        original = path.read_bytes() if path.exists() else None
        config = json.loads(original) if original else {}
        if not isinstance(config, dict) or not isinstance(config.get('hooks', {}), dict):
            raise ValueError(f'Invalid hook configuration: {path}')
        hooks = config.setdefault('hooks', {})
        command = (shlex.quote(str(python)) + ' ' + shlex.quote(str(binary)) + ' ' + provider)
        for event in dict.fromkeys([*hooks, *EVENTS]):
            entries = hooks.get(event, [])
            if not isinstance(entries, list):
                raise ValueError(f'Invalid {event} entries: {path}')
            clean = []
            for entry in entries:
                if not isinstance(entry, dict) or not isinstance(entry.get('hooks'), list):
                    clean.append(entry)
                    continue
                keep = [h for h in entry['hooks'] if not (isinstance(h, dict)
                        and isinstance(h.get('command'), str)
                        and re.search(r"/(?:upkin-activity|codex-limit-bar-activity)\.py(?:['\"\s]|$)",
                                      h['command']))]
                if keep:
                    clean.append({**entry, 'hooks': keep})
            entries = clean
            # StopCancelled is Grok-only; still clean up older Claude registrations.
            if event in EVENTS and mode != 'remove' and path != legacy_grok and not (provider == 'claude' and event == 'StopCancelled'):
                entries.append({'hooks': [{'type': 'command', 'command': command, 'timeout': 2}]})
            if entries:
                hooks[event] = entries
            else:
                hooks.pop(event, None)
        print(f'{mode}: {provider} → {path}')
        if mode == 'preview':
            continue
        changes.append((path, original, config))
    for path, original, config in changes:
        check_path(home, path)
        if (path.read_bytes() if path.exists() else None) != original:
            raise ValueError(f'Configuration changed during preview: {path}')
        data = json.dumps(config, ensure_ascii=False, indent=2) + '\n'
        if original == data.encode():
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        if original is not None:
            stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%f')
            backup = path.with_name(path.name + '.upkin-' + stamp + '.bak')
            fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'wb') as out:
                out.write(original)
        with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as out:
            temporary = Path(out.name)
            try:
                out.write(data)
                out.close()
                temporary.chmod(path.stat().st_mode & 0o777 if path.exists() else 0o600)
                check_path(home, path)
                if (path.read_bytes() if path.exists() else None) != original:
                    raise ValueError(f'Configuration changed before replacement: {path}')
                os.replace(temporary, path)
            finally:
                temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--install', action='store_true')
    group.add_argument('--remove', action='store_true')
    parser.add_argument('--home', type=Path, default=Path.home())
    parser.add_argument('--script', type=Path, default=Path(__file__).resolve().parents[1] /
                        'Upkin.app/Contents/Resources/upkin-activity.py')
    args = parser.parse_args()
    if not args.remove and not args.script.is_file():
        parser.error('Build the app before configuring hooks.')
    configure(args.home, args.script.resolve(), 'remove' if args.remove else 'install' if args.install else 'preview')


if __name__ == '__main__':
    main()
