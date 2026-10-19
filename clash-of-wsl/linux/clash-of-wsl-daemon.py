#!/usr/bin/env python3
"""clash-of-wsl resident daemon.

Runs inside the managed WSL distribution. It keeps the fail-closed network
arrangement authoritative between operator actions and reports health through a
state file, so the Windows component and the desktop client can tell a running
daemon apart from a healthy one.

It never opens the tunnel by itself. Only an explicit operator action, carried
by the reviewed manager, may open it.
"""
import argparse
import json
import os
import pathlib
import signal
import subprocess
import sys
import time

STATE_DIR = pathlib.Path('/var/lib/cor-egress')
STATE_FILE = STATE_DIR / 'daemon.json'
LOG_FILE = STATE_DIR / 'daemon.log'


def log(message):
    try:
        STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
        with open(LOG_FILE, 'a', encoding='utf-8') as handle:
            handle.write('%d %s\n' % (int(time.time()), message))
    except OSError:
        pass


def collect():
    try:
        out = subprocess.run(['nft', 'list', 'tables'], capture_output=True,
                             timeout=30, check=False, text=True)
        stdout = out.stdout
        code = out.returncode
    except (OSError, subprocess.SubprocessError):
        stdout = ''
        code = 1
    return {
        'guard_present': 'cor_egress_guard' in stdout,
        'nft_readable': code == 0,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description='clash-of-wsl resident daemon')
    parser.add_argument('--once', action='store_true', help='collect and exit')
    args = parser.parse_args(argv)

    if os.geteuid() != 0:
        print('resident daemon requires root inside the managed distribution')
        return 1

    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)

    if args.once:
        print(json.dumps({'schema': 1, 'facts': collect()}, sort_keys=True))
        return 0

    stop = {'requested': False}

    def handle(signum, frame):
        stop['requested'] = True

    signal.signal(signal.SIGTERM, handle)
    signal.signal(signal.SIGINT, handle)

    log('daemon online pid=%d' % os.getpid())
    while not stop['requested']:
        document = {
            'schema': 1,
            'component': 'clash-of-wsl',
            'pid': os.getpid(),
            'checked_at': int(time.time()),
            'facts': collect(),
        }
        try:
            tmp = STATE_FILE.with_suffix('.pending')
            tmp.write_text(json.dumps(document, sort_keys=True) + '\n', encoding='utf-8')
            os.chmod(tmp, 0o600)
            os.replace(tmp, STATE_FILE)
        except OSError as exc:
            log('state write failed: %s' % exc)
        time.sleep(60)

    log('daemon offline')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
