#!/usr/bin/env python3
"""Retire only the known XUAN WSL services; retain original files and secrets.

Preview by default. The journal contains unit metadata only and must reside in
a protected root-owned Linux directory. The old Docker ExecStop is suppressed:
it launches privileged Docker containers and is not a safe cleanup operation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

UNITS = (
    'xuan-claude-de-connect.service', 'xuan-claude-de-doh.service',
    'xuan-claude-de.service', 'xuan-docker-firewall.service',
    'xuan-claude-de-redsocks.service', 'xuan-claude-de-dns.service',
)
OVERRIDE = Path('/etc/apt/apt.conf.d/99-zz-cor-egress')
CONTENT = b'Acquire::http::Proxy "DIRECT";\nAcquire::https::Proxy "DIRECT";\n'
RUNTIME = Path('/run/systemd/system/xuan-docker-firewall.service.d/cor-egress-retire.conf')
RUNTIME_CONTENT = b'[Service]\nExecStop=\n'
ENV = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C', 'LC_ALL': 'C'}
OWNER = 'ClashOfRust.LegacyRetirement'
SHA256 = re.compile(r'^[0-9a-f]{64}$')


def validate_journal_path(path, required=True):
    path = path.absolute()
    parent = path.parent
    current = Path(path.anchor)
    for part in parent.parts[1:]:
        current = current / part
        info = current.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0:
            raise ValueError('Retirement journal directory is unsafe.')
        if info.st_mode & 0o022 and not (
                current == Path('/tmp') and info.st_mode & stat.S_ISVTX):
            raise ValueError('Retirement journal directory is writable by others.')
    try:
        info = path.lstat()
    except FileNotFoundError:
        if not required:
            return
        raise
    if not safe_root_file(info, private=True):
        raise ValueError('Retirement journal is not a private root-owned file.')


def safe_root_file(info, private=False):
    return (
        stat.S_ISREG(info.st_mode)
        and info.st_uid == 0
        and not info.st_mode & (0o077 if private else 0o022)
        and info.st_nlink == 1
    )


def read_journal(path):
    validate_journal_path(path)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(descriptor, 'r', encoding='utf-8') as stream:
        state = json.load(stream)
    if (not isinstance(state, dict)
            or state.get('owner') != OWNER
            or type(state.get('schema')) is not int or state['schema'] != 1
            or state.get('phase') not in ('prepared', 'retired', 'restoring', 'restored')
            or not isinstance(state.get('units'), list)
            or type(state.get('apt_override_created')) is not bool
            or type(state.get('runtime_override_created')) is not bool):
        raise ValueError('Unknown retirement journal.')
    seen = set()
    for entry in state['units']:
        if (not isinstance(entry, dict)
                or entry.get('unit') not in UNITS
                or entry['unit'] in seen
                or not isinstance(entry.get('sha256'), str)
                or not SHA256.fullmatch(entry['sha256'])
                or not isinstance(entry.get('enabled'), str)
                or not isinstance(entry.get('active'), str)):
            raise ValueError('Invalid retirement journal entry.')
        seen.add(entry['unit'])
    return state


def verify_owned_file(path, expected, label, allow_missing=False):
    try:
        info = path.lstat()
    except FileNotFoundError:
        # A journal flag means this exact file was created by the retirement
        # transaction.  Its absence is tampering or an incomplete external
        # change, not proof that there is nothing to restore.  Refuse the
        # rollback while leaving every original file untouched.  The only
        # exception is an idempotent retry of a rollback already in progress,
        # or a prepared journal that never reached the write step.
        if allow_missing:
            return False
        raise ValueError(f'{label} is missing; restore refused.')
    if not safe_root_file(info) or path.read_bytes() != expected:
        raise ValueError(f'{label} changed; restore refused.')
    return True


def run(args, check=True):
    result = subprocess.run(args, env=ENV, capture_output=True, text=True, timeout=40)
    if check and result.returncode:
        raise RuntimeError('Known legacy operation failed; original files retained.')
    return result


def inventory():
    result = []
    for unit in UNITS:
        path = Path('/etc/systemd/system')/unit
        if path.is_symlink():
            raise ValueError('Legacy unit is redirected; review before retirement.')
        if not path.exists():
            continue
        if not path.is_file() or path.stat().st_uid != 0 or path.stat().st_mode & 0o022:
            raise ValueError('Legacy unit ownership is unsafe.')
        result.append(dict(unit=unit, sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                           enabled=run(['systemctl', 'is-enabled', unit], False).stdout.strip(),
                           active=run(['systemctl', 'is-active', unit], False).stdout.strip()))
    return result


def save(path, value, exclusive=False):
    validate_journal_path(path, required=not exclusive)
    if exclusive:
        descriptor = os.open(
            path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            json.dump(value, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        return
    descriptor, temporary = tempfile.mkstemp(prefix='.cor-retire-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            json.dump(value, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def write_owned(path, data):
    if path.exists() or path.is_symlink():
        if path.is_symlink() or path.read_bytes() != data:
            raise ValueError('Owned retirement filename is already occupied.')
        return
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--journal', type=Path, required=True)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--rollback', action='store_true')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise ValueError('Run as Linux root.')
    if not args.execute:
        return dict(outcome='not_run', units=inventory(), original_files_retained=True)
    if args.rollback:
        state = read_journal(args.journal)
        if state['phase'] == 'restored':
            return dict(outcome='succeeded', phase='restored', units=len(state['units']),
                        original_files_retained=True, credential_files_copied=False)
        current = {entry['unit']: entry for entry in inventory()}
        for entry in state['units']:
            if current.get(entry['unit'], {}).get('sha256') != entry['sha256']:
                raise ValueError('Legacy unit changed; restore refused.')
        allow_missing = state['phase'] in ('prepared', 'restoring')
        apt_present = (state['apt_override_created']
                       and verify_owned_file(OVERRIDE, CONTENT, 'APT override', allow_missing))
        runtime_present = (state['runtime_override_created']
                           and verify_owned_file(RUNTIME, RUNTIME_CONTENT, 'Runtime override',
                                                 allow_missing))
        state['phase'] = 'restoring'
        save(args.journal, state)
        if apt_present:
            OVERRIDE.unlink()
        for entry in state['units']:
            if entry['enabled'] == 'enabled':
                run(['systemctl', 'enable', entry['unit']])
        if runtime_present:
            RUNTIME.unlink()
        run(['systemctl', 'daemon-reload'])
        # Start the old firewall before its dependent services.
        order = ('xuan-claude-de.service', *(x for x in UNITS if x != 'xuan-claude-de.service'))
        for unit in order:
            entry = next((x for x in state['units'] if x['unit'] == unit), None)
            if entry and entry['active'] == 'active':
                run(['systemctl', 'start', unit])
        state['phase'] = 'restored'
    else:
        state = dict(schema=1, owner='ClashOfRust.LegacyRetirement', phase='prepared',
                     units=inventory(), apt_override_created=not OVERRIDE.exists(),
                     runtime_override_created=not RUNTIME.exists())
        save(args.journal, state, exclusive=True)
        RUNTIME.parent.mkdir(parents=True, exist_ok=True)
        write_owned(RUNTIME, RUNTIME_CONTENT)
        run(['systemctl', 'daemon-reload'])
        for entry in state['units']:
            run(['systemctl', 'disable', entry['unit']])
        # The known firewall unit's ExecStop removes only its exact legacy
        # tuples. Docker ExecStop was cleared above and cannot launch containers.
        for entry in state['units']:
            run(['systemctl', 'stop', entry['unit']])
        write_owned(OVERRIDE, CONTENT)
        after = inventory()
        if any(x['enabled'] == 'enabled' or x['active'] == 'active' for x in after):
            raise RuntimeError('A legacy service remains active or enabled.')
        state['phase'] = 'retired'
    save(args.journal, state)
    return dict(outcome='succeeded', phase=state['phase'], units=len(state['units']),
                original_files_retained=True, credential_files_copied=False)


if __name__ == '__main__':
    try:
        print(json.dumps(main()))
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError):
        print(json.dumps(dict(outcome='failed', message='Inspect the metadata journal; original files retained.')))
        sys.exit(1)
