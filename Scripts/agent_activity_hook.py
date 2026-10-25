#!/usr/bin/env python3
"""Observe a CLI lifecycle event; never emit a hook decision or store conversation text."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time

ROOT = Path.home() / 'Library/Caches/Upkin/activity'
EVENTS = ('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse',
          'PostToolUseFailure', 'PermissionRequest', 'Notification', 'Stop',
          'StopFailure', 'StopCancelled', 'SessionEnd', 'PreCompact', 'PostCompact')


def record(provider, payload, root=ROOT, now=None):
    if provider not in ('claude', 'grok') or not isinstance(payload, dict):
        return
    grok = 'hookEventName' in payload
    # Grok also loads Claude's settings: ignore that compatibility invocation.
    if grok != (provider == 'grok') or payload.get('subagentType') or payload.get('agent_id'):
        return
    event = payload.get('hook_event_name') or payload.get('hookEventName')
    event = next((v for v in EVENTS if re.sub('_', '', str(event)).lower() == v.lower()), None)
    session = payload.get('sessionId') if grok else payload.get('session_id')
    if (event is None or not isinstance(session, str) or not 1 <= len(session) <= 200
            or any(ord(c) < 32 or ord(c) == 127 for c in session)):
        return
    now = time.time() if now is None else now
    key = provider + '-' + hashlib.sha256(session.encode()).hexdigest()
    if root.is_symlink():
        raise ValueError('Activity directory must not be a symlink')
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.chmod(0o700)
    path = root / (key + '.json')
    fd = os.open(root / (key + '.lock'), os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as lock:
        os.fchmod(lock.fileno(), 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = {'provider': provider, 'sessionID': session, 'phase': 'idle',
                 'updatedAt': now, 'tools': [], 'turnID': None}
        if path.exists():
            with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW)) as source:
                previous = json.load(source)
            # Never carry arbitrary fields from an existing cache into a new record.
            state.update({k: previous[k] for k in (*state, 'startedAt', 'turnStartedAt')
                          if k in previous})
        turn = payload.get('promptId') or payload.get('prompt_id')
        if not isinstance(turn, str) or len(turn) > 200:
            turn = None
        # Delayed reports for a superseded Grok turn must not settle the next one.
        if event != 'UserPromptSubmit' and turn and state['turnID'] and turn != state['turnID']:
            return
        previous_phase = state['phase']
        tool = payload.get('tool_use_id') or payload.get('toolUseId')
        tool = tool if isinstance(tool, str) and len(tool.encode()) <= 128 else 'unidentified'
        if event in ('SessionStart', 'UserPromptSubmit'):
            state['startedAt'] = now
            state.update(phase='thinking' if event == 'UserPromptSubmit' else 'idle',
                         tools=[], turnID=turn)
        elif event == 'PreToolUse':
            state['tools'] = sorted(set(state['tools'] + [tool]))[:32]
            state['phase'] = 'working'
        elif event in ('PostToolUse', 'PostToolUseFailure'):
            state['tools'] = [v for v in state['tools'] if v != tool]
            state['phase'] = ('error' if event == 'PostToolUseFailure' else
                              'working' if state['tools'] else 'thinking')
        elif event == 'PermissionRequest':
            state['phase'] = 'waiting'
        elif event == 'Notification':
            kind = payload.get('notificationType') or payload.get('notification_type')
            if kind == 'permission_prompt':
                state['phase'] = 'waiting'
            elif kind == 'task_complete':
                state.update(phase='completed', tools=[])
            elif kind == 'idle_prompt':
                if state['phase'] == 'completed':
                    return
                state.update(phase='idle', tools=[])
            else:
                return
        elif event == 'Stop':
            background = payload.get('backgroundTasks') or payload.get('background_tasks')
            # Claude Stop ends a reply; Grok Stop can still be cancelled by a hook.
            state['phase'] = ('working' if background or state['tools'] else
                              'completed' if provider == 'claude' else 'unknown')
        elif event == 'StopFailure':
            state.update(phase='error', tools=[])
        elif event == 'SessionEnd' and state['phase'] == 'completed':
            return  # Keep the completion time when the CLI closes.
        elif event in ('StopCancelled', 'SessionEnd'):
            state.update(phase='idle', tools=[])
        else:
            state['phase'] = 'thinking'
        if event == 'UserPromptSubmit' or (state['phase'] in ('thinking', 'working')
                and previous_phase not in ('thinking', 'working')):
            state['turnStartedAt'] = now
        state['updatedAt'] = now
        with tempfile.NamedTemporaryFile(mode='w', dir=root, prefix='.', delete=False) as out:
            temporary = Path(out.name)
            try:
                json.dump(state, out)
                out.close()
                os.replace(temporary, path)
            finally:
                temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('provider', choices=('grok', 'claude'))
    parser.add_argument('--directory', type=Path, default=ROOT)
    args = parser.parse_args()
    try:
        data = sys.stdin.buffer.read(1024 * 1024 + 1)
        if len(data) <= 1024 * 1024:
            record(args.provider, json.loads(data), args.directory)
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        pass  # Observation failure must never interrupt a coding task.


if __name__ == '__main__':
    main()
