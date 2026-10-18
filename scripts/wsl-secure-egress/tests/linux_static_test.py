#!/usr/bin/env python3
"""Portable harness checks. No subprocess, socket or Linux kernel operation runs.

    python -B scripts/wsl-secure-egress/tests/linux_static_test.py

These tests validate gating and evidence handling, not real firewall behavior.
"""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("cor_linux_integration", HERE / "linux_integration.py")
harness = importlib.util.module_from_spec(spec)
# Import must never execute any OS command or open a network socket.
with patch.object(subprocess, "run", side_effect=AssertionError("command during import")), \
        patch.object(subprocess, "Popen", side_effect=AssertionError("process during import")), \
        patch.object(socket, "socket", side_effect=AssertionError("socket during import")):
    spec.loader.exec_module(harness)
manager_path = HERE.parent / "linux" / "manager.py"
manager_spec = importlib.util.spec_from_file_location("cor_egress_manager", manager_path)
manager = importlib.util.module_from_spec(manager_spec)
with patch.object(subprocess, "run", side_effect=AssertionError("command during import")):
    manager_spec.loader.exec_module(manager)


def manager_table_fixture(owner='owned', opened=False, state=None, profile=None):
    expected = manager.manager_rule_expressions(
        state if opened else None, profile if opened else None)
    items = [{'table': {'family': 'inet', 'name': manager.TABLE,
                        'comment': 'cor-egress:' + owner}}]
    for name in expected:
        chain = {'family': 'inet', 'table': manager.TABLE, 'name': name,
                 'type': 'filter', 'hook': name, 'prio': -150, 'policy': 'drop'}
        if name == 'nat_out':
            chain.update(type='nat', hook='postrouting', prio=100, policy='accept')
        items.append({'chain': chain})
        items.extend({'rule': {'family': 'inet', 'table': manager.TABLE,
                               'chain': name, 'expr': expression}}
                     for expression in expected[name])
    return {'nftables': items}


class AttestationTests(unittest.TestCase):
    def setUp(self):
        self.instance = object.__new__(manager.Manager)
        self.instance.s = {'generation': 71, 'phase': 'Running'}
        self.instance.load = Mock()
        self.instance.assert_table = Mock()
        self.instance.health = Mock()
        self.instance.save = Mock()
        self.instance.audit_config = Mock(return_value={'facts': {
            'owned_config_matches': True, 'interop_runtime_disabled': True}})
        self.instance.event = Mock(return_value={'outcome': 'succeeded'})
        self.assertion = dict(schema=1, generation=71, issued_at_unix=1000,
                              all_distros_managed=True, hyperv_default_deny=True,
                              dns_tunneling_disabled=True, interop_disabled=True,
                              effective_audit_passed=True)

    def renew(self, assertion=None):
        raw = json.dumps(self.assertion if assertion is None else assertion).encode()
        with patch.object(manager.sys, 'stdin', Mock(buffer=io.BytesIO(raw))), \
                patch.object(manager.time, 'time', return_value=1001):
            return self.instance.attest()

    def test_only_a_current_matching_complete_audit_can_replace_proof(self):
        with patch.object(manager, 'atomic') as write:
            self.renew()
            write.assert_called_once()
            self.instance.health.assert_called_once()
            self.instance.save.assert_called_once()
            self.assertEqual(self.instance.s['attestation'],
                             str(manager.STATE / 'scope-attestation.json'))
        for updates in ({'generation': 72}, {'issued_at_unix': 700},
                        {'issued_at_unix': 1002}, {'effective_audit_passed': False},
                        {'all_distros_managed': 1}, {'issued_at_unix': True},
                        {'issued_at_unix': float('nan')}, {'issued_at_unix': 10**400}):
            with self.subTest(updates=updates), patch.object(manager, 'atomic') as write:
                with self.assertRaises(manager.Blocked):
                    self.renew(dict(self.assertion, **updates))
                write.assert_not_called()

    def test_closed_tunnel_and_config_drift_never_renew_proof(self):
        with patch.object(manager, 'atomic') as write:
            self.instance.s['phase'] = 'Guarded'
            with self.assertRaises(manager.Blocked):
                self.renew()
            self.instance.health.assert_not_called()
            self.instance.s['phase'] = 'Running'
            self.instance.audit_config.return_value['facts']['owned_config_matches'] = False
            with self.assertRaises(manager.Blocked):
                self.renew()
            write.assert_not_called()

    def test_no_privileged_policy_operation_is_called_by_renewal(self):
        for name in ('replace_table', 'start', 'stop', 'install',
                     'setup_routing', 'sysctl_forward'):
            setattr(self.instance, name, Mock(side_effect=AssertionError('network mutation')))
        with patch.object(manager, 'atomic'):
            self.renew()
        self.assertEqual(manager.parse(['attest', '--generation', '71']).action, 'attest')


class GateTests(unittest.TestCase):
    def test_boot_guard_uses_fixed_installed_wrapper(self):
        self.assertEqual(manager.boot_guard_command(),
                         '/usr/local/lib/cor-egress/manager guard')

    def test_existing_emergency_table_blocks_both_boot_paths(self):
        for role in ('manager', 'distro-config'):
            instance = object.__new__(manager.Manager)
            instance.s = {'role': role, 'phase': 'Guarded'}
            with self.subTest(role=role), \
                    patch.object(manager, 'list_table', return_value={'nftables': []}), \
                    patch.object(manager, 'ensure_static_boot_guard') as ensure_static:
                with self.assertRaisesRegex(manager.Blocked, 'emergency table preserved'):
                    instance.boot_guard()
                ensure_static.assert_not_called()

    def test_boot_emergency_matcher_accepts_missing_comment_only_for_exact_deny(self):
        items = [
            {'table': {'family': 'inet', 'name': manager.BOOT_EMERGENCY}},
            {'chain': {'name': 'output', 'type': 'filter', 'hook': 'output',
                       'prio': -200, 'policy': 'drop'}},
            {'chain': {'name': 'forward', 'type': 'filter', 'hook': 'forward',
                       'prio': -200, 'policy': 'drop'}},
            {'rule': {'chain': 'output', 'expr': [{'counter': {}}, {'drop': None}]}},
            {'rule': {'chain': 'forward', 'expr': [{'counter': {}}, {'drop': None}]}},
        ]
        with patch.object(manager, 'table_items', return_value=items):
            self.assertTrue(manager.boot_emergency_matches())
        with patch.object(manager, 'table_items',
                          return_value=items + [{'rule': {'chain': 'output',
                                                          'expr': [{'accept': None}]}}]):
            self.assertFalse(manager.boot_emergency_matches())

    def test_manager_matcher_rejects_unbounded_accept_rule(self):
        listed = {'nftables': [
            {'table': {'family': 'inet', 'name': manager.TABLE,
                       'comment': 'cor-egress:owned'}},
            {'chain': {'name': 'output', 'type': 'filter', 'hook': 'output',
                       'prio': -150, 'policy': 'drop'}},
            {'chain': {'name': 'forward', 'type': 'filter', 'hook': 'forward',
                       'prio': -150, 'policy': 'drop'}},
            {'rule': {'chain': 'output', 'expr': [{'accept': None}]}},
        ]}
        with patch.object(manager, 'list_table', return_value=listed):
            self.assertFalse(manager.manager_table_matches('owned'))

    def test_manager_matcher_rejects_forged_selector_names(self):
        # A broad accept must not pass merely because unrelated JSON values
        # contain the selector names the old textual matcher searched for.
        forged = {'match': {
            'op': '==',
            'left': {'meta': {'key': 'oifname'}},
            'right': {'comment': 'iifname saddr daddr udp sport dport'},
        }}
        listed = {'nftables': [
            {'table': {'family': 'inet', 'name': manager.TABLE,
                       'comment': 'cor-egress:owned'}},
            {'chain': {'name': 'output', 'type': 'filter', 'hook': 'output',
                       'prio': -150, 'policy': 'drop'}},
            {'chain': {'name': 'forward', 'type': 'filter', 'hook': 'forward',
                       'prio': -150, 'policy': 'drop'}},
            {'rule': {'chain': 'output', 'expr': [
                forged, {'accept': None},
            ]}},
        ]}
        with patch.object(manager, 'list_table', return_value=listed):
            self.assertFalse(manager.manager_table_matches('owned'))

    def test_manager_matcher_accepts_exact_closed_loopback_rule(self):
        listed = manager_table_fixture()
        with patch.object(manager, 'list_table', return_value=listed):
            self.assertTrue(manager.manager_table_matches('owned'))

    def test_manager_matcher_requires_exact_open_rules_and_rejects_mutations(self):
        state = {'uplink': 'eth0', 'root_sources': ['10.20.0.1/32'],
                 'forward_sources': [{'interface': 'docker0',
                                      'source_cidr': '172.18.0.0/16'}]}
        profile = {'endpoint_ipv4': '192.0.2.2', 'endpoint_port': 51820,
                   'resolver_ipv4': '10.77.0.1'}
        listed = manager_table_fixture(opened=True, state=state, profile=profile)
        with patch.object(manager, 'list_table', return_value=listed):
            self.assertTrue(manager.manager_table_matches(
                'owned', opened=True, state=state, profile=profile))
        mutations = []
        wrong_endpoint = json.loads(json.dumps(listed))
        for rule in wrong_endpoint['nftables']:
            if rule.get('rule', {}).get('chain') == 'forward':
                for expression in rule['rule']['expr']:
                    match = expression.get('match', {})
                    if match.get('left') == {'payload': {'protocol': 'ip', 'field': 'daddr'}}:
                        match['right'] = '203.0.113.9'
                        mutations.append(wrong_endpoint)
                        break
                if mutations:
                    break
        missing_v6 = json.loads(json.dumps(listed))
        missing_v6['nftables'] = [
            item for item in missing_v6['nftables']
            if not (item.get('rule', {}).get('chain') == 'output' and
                    item['rule']['expr'][0].get('match', {}).get('left') ==
                    {'meta': {'key': 'nfproto'}} and
                    item['rule']['expr'][0]['match']['right'] == 'ipv6')]
        mutations.append(missing_v6)
        extra_object = json.loads(json.dumps(listed))
        extra_object['nftables'].append({'set': {'family': 'inet',
                                                  'table': manager.TABLE,
                                                  'name': 'unexpected'}})
        mutations.append(extra_object)
        for changed in mutations:
            with patch.object(manager, 'list_table', return_value=changed):
                self.assertFalse(manager.manager_table_matches(
                    'owned', opened=True, state=state, profile=profile))

    def test_manager_matcher_accepts_exact_open_rules_without_optional_comment(self):
        state = {'uplink': 'eth0', 'root_sources': ['10.20.0.1/32'],
                 'forward_sources': []}
        profile = {'endpoint_ipv4': '192.0.2.2', 'endpoint_port': 51820,
                   'resolver_ipv4': '10.77.0.1'}
        listed = manager_table_fixture(opened=True, state=state, profile=profile)
        listed['nftables'][0]['table'].pop('comment')
        with patch.object(manager, 'list_table', return_value=listed):
            self.assertTrue(manager.manager_table_matches(
                'owned', opened=True, state=state, profile=profile))

    def test_guard_failure_uses_boot_only_emergency_fallback(self):
        class FakeManager:
            def __init__(self, _args):
                self.s = {}
                self.checks = []
                self.close_requested = False
                self.dirty = True
                self.safe_closed = False
                self.boot_only = None

            def boot_guard(self):
                raise manager.Blocked('guard failed')

            def emergency_deny(self, boot_only=False):
                self.boot_only = boot_only

            def event(self, action, outcome, message):
                return {'action': action, 'outcome': outcome, 'message': message}

        fake = None

        def construct(args):
            nonlocal fake
            fake = FakeManager(args)
            return fake

        with tempfile.TemporaryDirectory() as folder, \
                patch.object(manager, 'STATE', Path(folder)), \
                patch.object(manager, 'private_path'), \
                patch.object(manager, 'Manager', side_effect=construct), \
                patch.object(manager.sys, 'platform', 'linux'), \
                patch.object(manager.os, 'geteuid', return_value=0), \
                patch.object(manager, 'boot_id', return_value='current'), \
                patch.object(manager.os, 'readlink', return_value='current'), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(manager.main(['guard']), 2)
        self.assertIsNotNone(fake)
        self.assertTrue(fake.boot_only)

    def test_distro_config_boot_guard_installs_static_deny_without_profile(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'role': 'distro-config', 'phase': 'DistroConfigured'}
        instance.load = Mock(side_effect=AssertionError('private profile read'))
        instance.event = Mock(return_value={'outcome': 'succeeded'})
        with patch.object(manager, 'list_table', return_value=None), \
                patch.object(manager, 'ensure_static_boot_guard', return_value='static'), \
                patch.object(manager, 'command') as command:
            instance.boot_guard()
        instance.load.assert_not_called()
        command.assert_not_called()

    def test_distro_config_boot_guard_preserves_manager_or_static_table(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'role': 'distro-config', 'phase': 'DistroConfigured'}
        instance.event = Mock(return_value={'outcome': 'succeeded'})
        with patch.object(manager, 'list_table', return_value=None), \
                patch.object(manager, 'ensure_static_boot_guard', return_value='static'), \
                patch.object(manager, 'command') as command:
            instance.boot_guard()
        command.assert_not_called()

    def test_distro_config_unknown_table_gets_independent_emergency_deny(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'role': 'distro-config', 'phase': 'DistroConfigured'}
        instance.event = Mock(return_value={'outcome': 'blocked'})
        with patch.object(manager, 'list_table', return_value=None), \
                patch.object(manager, 'ensure_static_boot_guard', return_value='unknown'), \
                patch.object(manager, 'ensure_boot_emergency_deny') as emergency:
            result = instance.boot_guard()
        emergency.assert_called_once_with()
        self.assertEqual(result['outcome'], 'blocked')

    def test_ensure_static_guard_handles_concurrent_create(self):
        with patch.object(manager, 'list_table', return_value={'nftables': []}), \
                patch.object(manager, 'command', side_effect=RuntimeError('File exists')), \
                patch.object(manager, 'static_boot_matches', return_value=True):
            self.assertEqual(manager.ensure_static_boot_guard(), 'static')

    def test_manager_requires_exact_static_boot_table_for_adoption(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'owner': 'owned'}
        with patch.object(manager, 'table_hash', return_value='static'), \
                patch.object(manager, 'static_boot_matches', return_value=True), \
                patch.object(manager, 'manager_table_matches', return_value=False), \
                patch.object(manager, 'command') as command:
            self.assertTrue(instance.adopt_static_boot_table())
        command.assert_not_called()
        with patch.object(manager, 'table_hash', return_value='foreign'), \
                patch.object(manager, 'static_boot_matches', return_value=False), \
                patch.object(manager, 'manager_table_matches', return_value=False), \
                patch.object(manager, 'command') as command:
            with self.assertRaisesRegex(manager.Blocked, 'preserving'):
                instance.adopt_static_boot_table()
        command.assert_not_called()

    def test_manager_retains_a_valid_existing_manager_table(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'owner': 'owned'}
        with patch.object(manager, 'table_hash', return_value='owned'), \
                patch.object(manager, 'static_boot_matches', return_value=False), \
                patch.object(manager, 'manager_table_matches', return_value=True):
            self.assertFalse(instance.adopt_static_boot_table())

    def test_distro_config_boot_guard_accepts_a_valid_shared_manager_table(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'role': 'distro-config', 'phase': 'DistroConfigured'}
        instance.load = Mock(side_effect=AssertionError('private profile read'))
        instance.event = Mock(return_value={'outcome': 'succeeded'})
        with patch.object(manager, 'list_table', return_value=None), \
                patch.object(manager, 'ensure_static_boot_guard', return_value='manager'), \
                patch.object(manager, 'ensure_boot_emergency_deny') as emergency:
            instance.boot_guard()
        instance.load.assert_not_called()
        emergency.assert_not_called()

    def test_distro_config_unknown_table_preserves_it_and_installs_emergency(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'role': 'distro-config', 'phase': 'DistroConfigured'}
        instance.event = Mock(return_value={'outcome': 'blocked'})
        with patch.object(manager, 'list_table', return_value=None), \
                patch.object(manager, 'ensure_static_boot_guard', return_value='unknown'), \
                patch.object(manager, 'ensure_boot_emergency_deny') as emergency, \
                patch.object(manager, 'command') as command:
            result = instance.boot_guard()
        emergency.assert_called_once_with()
        command.assert_not_called()
        self.assertEqual(result['outcome'], 'blocked')

    def test_boot_emergency_is_idempotent_and_refuses_name_collision(self):
        with patch.object(manager, 'list_table', return_value={'nftables': []}), \
                patch.object(manager, 'boot_emergency_matches', return_value=True), \
                patch.object(manager, 'command') as command:
            self.assertFalse(manager.ensure_boot_emergency_deny())
        command.assert_not_called()
        with patch.object(manager, 'list_table', return_value={'nftables': []}), \
                patch.object(manager, 'boot_emergency_matches', return_value=False), \
                patch.object(manager, 'command') as command:
            with self.assertRaises(manager.Blocked):
                manager.ensure_boot_emergency_deny()
        command.assert_not_called()

    def test_boot_emergency_create_race_accepts_only_exact_table(self):
        with patch.object(manager, 'list_table', side_effect=[None, {'nftables': []}]), \
                patch.object(manager, 'command', side_effect=RuntimeError('File exists')), \
                patch.object(manager, 'boot_emergency_matches', return_value=True):
            self.assertFalse(manager.ensure_boot_emergency_deny())

    def test_manager_replaces_static_guard_atomically(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'owner': 'owned', 'tables': {}}
        instance.save = Mock()
        instance.root_rules = Mock(return_value='table inet cor_egress_guard {}\n')
        with patch.object(manager, 'table_hash', side_effect=['static', 'manager', 'manager']), \
                patch.object(manager, 'manager_table_matches', return_value=False), \
                patch.object(manager, 'static_boot_matches', return_value=True), \
                patch.object(manager, 'command') as command:
            instance.install_manager_after_boot_guard()
        command.assert_called_once_with(
            ['nft', '-f', '-'],
            data=('delete table inet cor_egress_guard\n' +
                  'table inet cor_egress_guard {}\n').encode())

    def test_running_manager_is_closed_before_guarded_phase(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'owner': 'owned', 'phase': 'Running', 'tables': {}}
        instance.p = {'endpoint_ipv4': '192.0.2.2', 'endpoint_port': 51820,
                      'resolver_ipv4': '10.77.0.1'}
        instance.save = Mock()
        instance.root_rules = Mock(return_value='closed-rules')
        instance.replace_table = Mock()
        with patch.object(manager, 'table_hash', return_value='manager'), \
                patch.object(manager, 'manager_table_matches', return_value=True):
            instance.install_manager_after_boot_guard()
        instance.replace_table.assert_called_once_with('closed-rules')
        self.assertEqual(instance.s['phase'], 'Guarded')

    def test_unknown_table_never_gets_overwritten(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'owner': 'owned', 'tables': {}}
        instance.save = Mock()
        instance.root_rules = Mock(return_value='replacement')
        with patch.object(manager, 'table_hash', return_value='unknown'), \
                patch.object(manager, 'manager_table_matches', return_value=False), \
                patch.object(manager, 'static_boot_matches', return_value=False), \
                patch.object(manager, 'command') as command:
            with self.assertRaisesRegex(manager.Blocked, 'preserving'):
                instance.install_manager_after_boot_guard()
        command.assert_not_called()

    def test_static_boot_rules_have_owned_comment_and_drop_chains(self):
        rules = manager.static_boot_rules()
        self.assertIn('comment "cor-egress-boot-v1"', rules)
        self.assertIn('chain output', rules)
        self.assertIn('chain forward', rules)
        self.assertEqual(rules.count('policy drop'), 2)
        self.assertEqual(rules.count('counter drop'), 4)

    def test_boot_guard_checks_profile_identity_before_reconciliation(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'role': 'manager', 'phase': 'Guarded'}
        instance.load = Mock(side_effect=manager.Blocked('profile drift'))
        instance.boot_reconcile = Mock()
        instance.replace_table = Mock()
        with patch.object(manager, 'list_table', return_value=None), \
                patch.object(manager, 'ensure_static_boot_guard', return_value='static'), \
                self.assertRaises(manager.Blocked):
            instance.boot_guard()
        instance.boot_reconcile.assert_not_called()
        instance.replace_table.assert_not_called()

    def test_boot_guard_establishes_static_deny_before_profile_load(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'role': 'manager', 'phase': 'Guarded'}
        calls = []
        instance.load = Mock(side_effect=lambda: calls.append('profile') or
                             (_ for _ in ()).throw(manager.Blocked('profile drift')))
        with patch.object(manager, 'list_table', return_value=None), \
                patch.object(manager, 'ensure_static_boot_guard',
                          side_effect=lambda: calls.append('static') or 'static'), \
                self.assertRaises(manager.Blocked):
            instance.boot_guard()
        self.assertEqual(calls, ['static', 'profile'])

    def test_boot_reconcile_accepts_static_or_manager_guard_in_new_namespace(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'phase': 'Guarded', 'role': 'manager', 'root_namespace': 'old',
                      'boot_id': 'old', 'namespaces': {}, 'tables': {}}
        instance.policy_routes = Mock(return_value=[])
        instance.save = Mock()
        instance.s = {'phase': 'Guarded', 'role': 'manager', 'root_namespace': 'old',
                      'boot_id': 'old', 'namespaces': {}, 'tables': {}}
        with patch.object(manager.os, 'readlink', return_value='new'), \
                patch.object(manager, 'boot_id', return_value='new'), \
                patch.object(manager.Path, 'exists', return_value=False), \
                patch.object(manager.Path, 'is_symlink', return_value=False), \
                patch.object(manager, 'json_command', side_effect=[[], []]), \
                patch.object(manager, 'table_hash', return_value='static'), \
                patch.object(manager, 'table_classification', return_value='static'), \
                patch.object(manager, 'list_table', return_value=None):
            instance.boot_reconcile()
        instance.save.assert_called_once_with()
        instance.s = {'phase': 'Guarded', 'role': 'manager', 'root_namespace': 'old',
                      'boot_id': 'old', 'namespaces': {}, 'tables': {}}
        with patch.object(manager.os, 'readlink', return_value='new'), \
                patch.object(manager, 'boot_id', return_value='new'), \
                patch.object(manager.Path, 'exists', return_value=False), \
                patch.object(manager.Path, 'is_symlink', return_value=False), \
                patch.object(manager, 'json_command', side_effect=[[], []]), \
                patch.object(manager, 'table_hash', return_value='manager'), \
                patch.object(manager, 'table_classification', return_value='manager'), \
                patch.object(manager, 'list_table', return_value=None):
            instance.boot_reconcile()
        instance.s = {'phase': 'Guarded', 'role': 'manager', 'root_namespace': 'old',
                      'boot_id': 'old', 'namespaces': {}, 'tables': {}}
        with patch.object(manager.os, 'readlink', return_value='new'), \
                patch.object(manager, 'boot_id', return_value='new'), \
                patch.object(manager.Path, 'exists', return_value=False), \
                patch.object(manager.Path, 'is_symlink', return_value=False), \
                patch.object(manager, 'json_command', side_effect=[[], []]), \
                patch.object(manager, 'table_hash', return_value='unknown'), \
                patch.object(manager, 'table_classification', return_value='unknown'), \
                patch.object(manager, 'list_table', return_value=None):
            with self.assertRaises(manager.Blocked):
                instance.boot_reconcile()

    def test_static_matcher_rejects_swapped_hooks_and_wrong_policy(self):
        base = {'nftables': [
            {'table': {'family': 'inet', 'name': manager.TABLE,
                       'comment': manager.STATIC_BOOT_COMMENT}},
            {'chain': {'name': 'output', 'type': 'filter', 'hook': 'forward',
                       'prio': -150, 'policy': 'drop'}},
            {'chain': {'name': 'forward', 'type': 'filter', 'hook': 'output',
                       'prio': -150, 'policy': 'drop'}},
        ]}
        with patch.object(manager, 'list_table', return_value=base):
            self.assertFalse(manager.static_boot_matches())

    def test_manager_matcher_rejects_unknown_base_chain(self):
        listed = {'nftables': [
            {'table': {'family': 'inet', 'name': manager.TABLE,
                       'comment': 'cor-egress:owned'}},
            {'chain': {'name': 'output', 'type': 'filter', 'hook': 'output',
                       'prio': -150, 'policy': 'drop'}},
            {'chain': {'name': 'forward', 'type': 'filter', 'hook': 'forward',
                       'prio': -150, 'policy': 'drop'}},
            {'chain': {'name': 'foreign', 'type': 'filter', 'hook': 'prerouting',
                       'prio': -150, 'policy': 'accept'}},
        ]}
        with patch.object(manager, 'list_table', return_value=listed):
            self.assertFalse(manager.manager_table_matches('owned'))

    def test_sandbox_staging_remains_traversable_under_private_umask(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(manager, 'private_path'):
            before = os.umask(0o077)
            try:
                path = manager.sandbox_directory(Path(folder)/'sandbox')
            finally:
                os.umask(before)
            self.assertEqual(path.stat().st_mode & 0o777, 0o755)
    def test_only_the_known_wsl_pe_handler_can_be_disabled(self):
        known = 'enabled\ninterpreter /init\nflags: PF\noffset 0\nmagic 4d5a\n'
        instance = object.__new__(manager.Manager)
        instance.s = {}
        instance.save = Mock()
        registration = Mock()
        registration.exists.return_value = True
        registration.read_text.side_effect = [known, known.replace('enabled', 'disabled', 1)]
        with patch.object(manager, 'INTEROP', registration):
            instance.interop_guard()
        registration.write_text.assert_called_once_with('0')
        self.assertEqual(instance.s['interop_guard']['before'], 'enabled')
        self.assertTrue(instance.save.called)
        for text in (known.replace('/init', '/foreign'), known.replace('4d5a', '7f454c46')):
            registration = Mock()
            registration.exists.return_value = True
            registration.read_text.return_value = text
            with patch.object(manager, 'INTEROP', registration):
                with self.assertRaises(manager.Blocked):
                    instance.interop_guard()
            registration.write_text.assert_not_called()

    def test_interop_restore_respects_later_changes(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'interop_guard': {'before': 'enabled', 'written': 'disabled'}}
        instance.save = Mock()
        with patch.object(instance, 'interop_state', return_value='enabled'), \
                patch.object(manager, 'INTEROP') as registration:
            with self.assertRaises(manager.Blocked):
                instance.restore_interop_guard()
        registration.write_text.assert_not_called()

    def test_all_three_explicit_gates_are_required(self):
        for execute in (False, True):
            for ci in (None, "false", "TRUE", "1", "true"):
                for isolated in (None, "true", "0", "1"):
                    env = {key: value for key, value in
                           (("CI", ci), ("COR_EGRESS_ISOLATED_CI", isolated)) if value is not None}
                    expected = execute and ci == "true" and isolated == "1"
                    with self.subTest(execute=execute, ci=ci, isolated=isolated), \
                            patch.dict(os.environ, env, clear=True), \
                            patch.object(harness.sys, "platform", "linux"), \
                            patch.object(os, "geteuid", return_value=0, create=True), \
                            patch.object(subprocess, "run") as run:
                        if expected:
                            harness.execution_gate(execute)
                        else:
                            with self.assertRaises(harness.Failure):
                                harness.execution_gate(execute)
                        run.assert_not_called()

    def test_non_linux_and_non_root_refused(self):
        for platform, uid in (("win32", 0), ("linux", 1000)):
            with self.subTest(platform=platform, uid=uid), \
                    patch.dict(os.environ, {"CI": "true", "COR_EGRESS_ISOLATED_CI": "1"}, clear=True), \
                    patch.object(harness.sys, "platform", platform), \
                    patch.object(os, "geteuid", return_value=uid, create=True):
                with self.assertRaises(harness.Failure):
                    harness.execution_gate(True)

    def test_refused_entrypoint_has_no_side_effects(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(harness, "command") as command, \
                patch.object(subprocess, "run") as run, patch.object(harness, "private_mounts") as mounts:
            with self.assertRaises(harness.Failure):
                harness.main(["--execute-isolated"])
            command.assert_not_called()
            run.assert_not_called()
            mounts.assert_not_called()

    def test_launcher_only_enters_unshare(self):
        with patch.object(harness, "execution_gate"), \
                patch.object(harness, "PAYLOAD_PYTHON", sys.executable), \
                patch.object(harness.shutil, "which", return_value="/usr/bin/tool"), \
                patch.object(harness, "namespace_ids", return_value={"net": 1, "mnt": 2, "pid": 3}), \
                patch.object(subprocess, "run", return_value=Mock(returncode=0)) as run, \
                patch.object(harness, "private_mounts") as mounts, \
                patch.object(harness, "Fixture") as fixture:
            self.assertEqual(harness.main(["--execute-isolated"]), 0)
            argv = run.call_args.args[0]
            self.assertEqual(argv[0], "unshare")
            for flag in ("--net", "--mount", "--pid", "--fork", "--mount-proc", "--kill-child=SIGKILL"):
                self.assertIn(flag, argv)
            self.assertIn("--_isolated-parent", argv)
            mounts.assert_not_called()
            fixture.assert_not_called()
            run.assert_called_once()

    def test_internal_child_cannot_use_launcher_namespaces(self):
        original = {"net": 1, "mnt": 2, "pid": 3}
        for current in (original, {"net": 4, "mnt": 2, "pid": 5}):
            with patch.object(os, "getpid", return_value=1), \
                    patch.object(harness, "namespace_ids", return_value=current), \
                    patch.object(harness, "command") as command:
                with self.assertRaises(harness.Failure):
                    harness.verify_child(original)
                command.assert_not_called()
        with patch.object(os, "getpid", return_value=123):
            with self.assertRaises(harness.Failure):
                harness.verify_child(original)


class EvidenceTests(unittest.TestCase):
    def fixture(self):
        fixture = object.__new__(harness.Fixture)
        fixture.evidence = []
        fixture.control = Mock()
        fixture.observe = Mock(return_value=dict(direct=0, tunnel=0, wireguard=0))
        fixture.probe = Mock(return_value=dict(nonce="fake", sent=True, reply=False))
        fixture.receipts = Mock(return_value=[])
        return fixture

    def test_send_success_or_timeout_is_not_a_negative_proof(self):
        fixture = self.fixture()
        fixture.deny_counters = Mock(return_value=7)
        with patch.object(harness.time, "sleep"):
            with self.assertRaisesRegex(harness.Failure, "deny counter"):
                fixture.negative("send-is-not-delivery")

    def test_nonce_receipt_defeats_negative_even_with_drop_counter(self):
        fixture = self.fixture()
        fixture.deny_counters = Mock(side_effect=[1, 2])
        fixture.receipts.return_value = [dict(nonce="fake")]
        with patch.object(harness.time, "sleep"):
            with self.assertRaisesRegex(harness.Failure, "reached receiver"):
                fixture.negative("received-is-a-leak")

    def test_escaped_packet_defeats_negative_without_application_receipt(self):
        fixture = self.fixture()
        fixture.deny_counters = Mock(side_effect=[1, 2])
        fixture.observe.side_effect = [dict(direct=0), dict(direct=1)]
        with patch.object(harness.time, "sleep"):
            with self.assertRaisesRegex(harness.Failure, "escaped"):
                fixture.negative("escaped-syn-is-a-leak")

    def test_counter_and_receiver_controls_required_for_negative(self):
        fixture = self.fixture()
        fixture.deny_counters = Mock(side_effect=[1, 2])
        with patch.object(harness.time, "sleep"):
            fixture.negative("bounded-refusal")
        self.assertEqual(fixture.control.call_count, 2)
        self.assertEqual(fixture.evidence[0]["received"], 0)

    def test_echo_without_receipt_cannot_pass_positive(self):
        fixture = self.fixture()
        fixture.probe.return_value = dict(nonce="fake", reply=True)
        fixture.observe.side_effect = [dict(direct=0), dict(direct=1)]
        with self.assertRaisesRegex(harness.Failure, "receipt"):
            fixture.positive("no-receiver-record")

    def test_wrong_tunnel_source_cannot_pass_positive(self):
        fixture = self.fixture()
        fixture.probe.return_value = dict(nonce="fake", reply=True)
        fixture.receipts.return_value = [dict(nonce="fake", kind="tcp", source="192.0.2.1")]
        fixture.observe.side_effect = [dict(direct=0, tunnel=0, wireguard=0),
                                       dict(direct=0, tunnel=1, wireguard=1)]
        with self.assertRaisesRegex(harness.Failure, "wrong tunnel source"):
            fixture.positive("wrong-source", via_tunnel=True)

    def test_inline_scripts_and_owned_files_parse_without_execution(self):
        for name in ("RECEIVER", "CLIENT", "SANDBOX_AUDIT"):
            compile(getattr(harness, name), f"<{name}>", "exec")
        for path in (HERE / "linux_integration.py", HERE / "linux_static_test.py"):
            compile(path.read_text(encoding="utf-8"), str(path), "exec")

    def test_transport_pmtu_policy_rule_uses_supported_selectors(self):
        manager_path = HERE.parent / "linux" / "manager.py"
        source = manager_path.read_text(encoding="utf-8")
        self.assertIn("'to', TRANSPORT_IP + '/32', 'lookup', 'main'", source)
        self.assertNotIn("'protocol', 'icmp'", source)
        self.assertIn('icmp type 3 icmp code 4 ct state related counter accept', source)
        self.assertIn('PREF_TRANSPORT_PMTU = 10072', source)
        self.assertIn('PREF_DEFAULT_DENY = 10074', source)

    def test_wsl_host_generation_is_disabled_and_hosts_are_owned(self):
        source = (HERE.parent / "linux" / "manager.py").read_text(encoding="utf-8")
        self.assertIn("'generateHosts': 'false'", source)
        self.assertIn("self.snapshot('/etc/hosts'", source)
        self.assertIn("127.0.0.1 localhost", source)
        self.assertNotIn("host.docker.internal", source)

    def test_sandbox_seccomp_denies_namespace_entry_and_creation(self):
        program = manager.seccomp_filter()
        instructions = [struct.unpack_from("HBBI", program, offset)
                        for offset in range(0, len(program), 8)]
        self.assertTrue(instructions)
        self.assertTrue(all(len(instruction) == 4 for instruction in instructions))

        def evaluate(arch, syscall, arg0=0):
            data = bytearray(32)
            struct.pack_into("I", data, manager.SECCOMP_ARCH_OFFSET, arch)
            struct.pack_into("I", data, manager.SECCOMP_NR_OFFSET, syscall)
            struct.pack_into("I", data, manager.SECCOMP_ARG0_OFFSET, arg0)
            accumulator = 0
            pc = 0
            while pc < len(instructions):
                code, jump_true, jump_false, value = instructions[pc]
                if code == 0x20:  # BPF_LD | BPF_W | BPF_ABS
                    accumulator = struct.unpack_from("I", data, value)[0]
                    pc += 1
                elif code == 0x15:  # BPF_JMP | BPF_JEQ | BPF_K
                    pc += (jump_true if accumulator == value else jump_false) + 1
                elif code == 0x45:  # BPF_JMP | BPF_JSET | BPF_K
                    pc += (jump_true if accumulator & value else jump_false) + 1
                elif code == 0x06:  # BPF_RET | BPF_K
                    return value
                else:
                    self.fail(f"unexpected seccomp opcode 0x{code:x}")
            self.fail("seccomp program fell through")

        arch_name = manager.platform.machine().lower()
        arch = manager.AUDIT_ARCHES[arch_name]
        syscalls = manager.SYSCALLS[arch_name]
        denied = manager.SECCOMP_RET_ERRNO | manager.EPERM
        self.assertEqual(evaluate(arch, syscalls["unshare"]), denied)
        self.assertEqual(evaluate(arch, syscalls["setns"]), denied)
        self.assertEqual(evaluate(arch, syscalls["clone3"]),
                         manager.SECCOMP_RET_ERRNO | manager.ENOSYS)
        self.assertEqual(evaluate(arch, syscalls["clone"]), manager.SECCOMP_RET_ALLOW)
        self.assertEqual(
            evaluate(arch, syscalls["clone"], manager.CLONE_NAMESPACE_FLAGS & -manager.CLONE_NAMESPACE_FLAGS),
            denied,
        )
        self.assertEqual(evaluate(arch, syscalls["clone"], 0x00000100), manager.SECCOMP_RET_ALLOW)
        source = manager_path.read_text(encoding="utf-8")
        self.assertIn("'unshare'", source)
        self.assertIn("'setns'", source)
        self.assertIn("'clone3'", source)
        self.assertIn("'--seccomp'", source)

    def test_sandbox_seccomp_refuses_unknown_architecture(self):
        with patch.object(manager.platform, "machine", return_value="unknown-cpu"):
            with self.assertRaisesRegex(manager.Blocked, "Unsupported architecture"):
                manager.seccomp_filter()

    def test_nonce_generator_has_unique_dns_safe_labels(self):
        tokens = {harness.nonce() for _ in range(100)}
        self.assertEqual(len(tokens), 100)
        self.assertTrue(all(len(token) == 32 and set(token) <= set("0123456789abcdef") for token in tokens))

    def test_udp_client_rejects_wrong_nonce_and_wrong_sender(self):
        for payload, peer, expected in ((b"aa" * 16, (harness.TARGET, 18080), True),
                                        (b"bb" * 16, (harness.TARGET, 18080), False),
                                        (b"aa" * 16, (harness.ENDPOINT, 18080), False)):
            fake_socket = Mock()
            fake_socket.recvfrom.return_value = (payload, peer)
            config = dict(mode="udp", host=harness.TARGET, port=18080, nonce="aa" * 16)
            output = io.StringIO()
            with self.subTest(payload=payload, peer=peer), \
                    patch.object(socket, "socket", return_value=fake_socket), \
                    patch.object(sys, "argv", ["client", json.dumps(config)]), contextlib.redirect_stdout(output):
                exec(compile(harness.CLIENT, "<CLIENT>", "exec"), {})
            result = json.loads(output.getvalue())
            self.assertEqual(result["reply"], expected)
            self.assertTrue(result["sent"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
