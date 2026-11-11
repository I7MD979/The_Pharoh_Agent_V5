#!/usr/bin/env python3
"""Detect an alive-but-stalled llama-server; invoked by a systemd timer."""
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

SERVICE = 'llama-cyberstrike.service'
BASE = 'http://127.0.0.1:8000'
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class UnsupportedTelemetry(ValueError):
    pass


def request(path, payload=None, timeout=10):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={'Content-Type': 'application/json'})
    with HTTP.open(req, timeout=timeout) as response:
        return json.load(response)


def progress(slots):
    if not isinstance(slots, list) or not slots or any(
            not isinstance(slot, dict) or not isinstance(slot.get('is_processing'), bool)
            for slot in slots):
        raise UnsupportedTelemetry('Invalid /slots response')
    active = []
    for slot in slots:
        if not slot['is_processing']:
            continue
        token = slot.get('next_token')
        if isinstance(token, list):
            decoded = [item.get('n_decoded') for item in token if isinstance(item, dict)]
            decoded = decoded if any(isinstance(n, int) for n in decoded) else None
        else:
            decoded = token.get('n_decoded') if isinstance(token, dict) else None
        past = slot.get('n_past')
        prompt = slot.get('n_prompt_tokens_processed')
        if not any(isinstance(n, (int, list)) for n in (past, prompt, decoded)):
            raise UnsupportedTelemetry('Busy slot has no readable progress counters')
        active.append([slot.get('id'), slot.get('id_task'), past, prompt, decoded])
    return active


def assess(state, now, fingerprint, probe_ok=True, stall_seconds=1800):
    """Track progress, allowing long requests while token counts keep advancing."""
    if fingerprint:
        state['failures'] = 0
        if fingerprint != state.get('progress'):
            state.update(progress=fingerprint, progress_at=now)
        return now - state.get('progress_at', now) >= stall_seconds
    state.pop('progress', None)
    state.pop('progress_at', None)
    state['failures'] = 0 if probe_ok else state.get('failures', 0) + 1
    return state['failures'] >= 3


def command(*args):
    result = subprocess.run(args, text=True, capture_output=True, timeout=20)
    return result.stdout + result.stderr


def diagnose(reason):
    directory = Path(os.environ.get('LOGS_DIRECTORY', '/var/log/pharaoh-watchdog'))
    directory.mkdir(parents=True, exist_ok=True)
    parts = [time.strftime('%Y-%m-%dT%H:%M:%S%z'), reason]
    for args in [('journalctl', '-u', SERVICE, '-n', '80', '--no-pager'),
                 ('nvidia-smi',), ('free', '-h')]:
        try:
            parts.append(command(*args))
        except (OSError, subprocess.TimeoutExpired) as exc:
            parts.append(str(exc))
    (directory / 'latest-diagnostic.log').write_text('\n'.join(parts))


def main():
    now = time.monotonic()
    props = dict(line.split('=', 1) for line in command(
        'systemctl', 'show', SERVICE, '-p', 'ActiveState', '-p', 'InvocationID',
        '-p', 'ActiveEnterTimestampMonotonic').splitlines() if '=' in line)
    # Respect stop-stack and normal systemd restart/startup handling.
    if props.get('ActiveState') != 'active':
        return
    started = int(props.get('ActiveEnterTimestampMonotonic', '0')) / 1_000_000
    if now - started < int(os.environ.get('STARTUP_GRACE_SECONDS', '900')):
        return
    directory = Path(os.environ.get('STATE_DIRECTORY', '/var/lib/pharaoh-watchdog'))
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / 'state.json'
    try:
        state = json.loads(path.read_text())
    except (OSError, ValueError):
        state = {}
    invocation = props.get('InvocationID')
    if state.get('invocation') != invocation:
        state = {'invocation': invocation}
    stall_seconds = int(os.environ.get('STALL_SECONDS', '1800'))
    probe_timeout = int(os.environ.get('PROBE_TIMEOUT_SECONDS', '120'))
    reason = ''
    try:
        health = request('/health')
        if not isinstance(health, dict) or not isinstance(health.get('status'), str):
            raise UnsupportedTelemetry('Unexpected /health response')
        if health.get('status') != 'ok':
            raise ValueError('Model is not ready')
        fingerprint = progress(request('/slots'))
        if fingerprint:
            restart = assess(state, now, fingerprint,
                             stall_seconds=stall_seconds)
            reason = 'Busy model made no observable progress within the stall limit'
        elif now - state.get('last_probe', 0) >= 300:
            # A real one-token inference detects GPU hangs that /health misses.
            reply = request('/completion', {'prompt': 'Hi', 'n_predict': 1,
                                            'cache_prompt': False, 'stream': False},
                            timeout=probe_timeout)
            if isinstance(reply, list) and len(reply) == 1:
                reply = reply[0]
            if not isinstance(reply, dict) or not (
                    isinstance(reply.get('content'), str) or isinstance(reply.get('tokens_predicted'), int)):
                raise UnsupportedTelemetry('Unexpected /completion response')
            if not reply.get('content') and not reply.get('tokens_predicted', 0):
                raise ValueError('Inference probe returned no tokens')
            state['last_probe'] = now
            restart = assess(state, now, [])
        else:
            restart = assess(state, now, [])
    except (UnsupportedTelemetry, json.JSONDecodeError) as exc:
        restart = assess(state, now, [])
        print(f'Watchdog skipped recovery: {exc}', flush=True)
    except (OSError, ValueError) as exc:
        restart = assess(state, now, [], probe_ok=False)
        reason = f'HTTP/inference probe failed: {exc}'
        print(reason, flush=True)
    if restart:
        diagnose(reason)
        print(f'Restarting {SERVICE}: {reason}', flush=True)
        # Recheck: never bring a service back if the user stopped it meanwhile.
        active = command('systemctl', 'is-active', SERVICE).strip()
        if active == 'active':
            subprocess.run(['systemctl', 'try-restart', SERVICE], check=True, timeout=90)
        state = {}
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(state))
    temporary.replace(path)


if __name__ == '__main__':
    main()
