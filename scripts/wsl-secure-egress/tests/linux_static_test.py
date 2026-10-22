#!/usr/bin/env python3
"""Portable harness checks. No subprocess, socket or Linux kernel operation runs.

    python -B scripts/wsl-secure-egress/tests/linux_static_test.py

These tests validate gating and evidence handling, not real firewall behavior.
"""

import contextlib
import errno
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
from types import SimpleNamespace
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
with contextlib.ExitStack() as import_context:
    if sys.platform != 'linux':
        # The production module is Linux-only; portable offline tests never
        # acquire a real Linux flock, including when run on the Windows host.
        import_context.enter_context(patch.dict(
            sys.modules, {'fcntl': Mock(LOCK_EX=2, LOCK_NB=4, LOCK_UN=8)}))
    import_context.enter_context(patch.object(
        subprocess, "run", side_effect=AssertionError("command during import")))
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


class CrossDistroGuardTests(unittest.TestCase):
    """Run the real classifier/boot path with distinct distro state and nft I/O."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state_path = Path(self.temp.name)
        self.policy = {'endpoint_ipv4': '192.0.2.2', 'endpoint_port': 51820,
                       'resolver_ipv4': '10.77.0.1'}
        self.runtime = {'uplink': 'eth0',
                        'root_sources': ['10.20.0.1/32', manager.BUS_ROOT_IP + '/32'],
                        'forward_sources': [{'interface': 'docker0',
                                             'source_cidr': '172.18.0.0/16'}]}
        self.journal = {'schema': 1, 'role': 'distro-config', 'phase': 'DistroConfigured',
                        'owner': 'different-distro-owner', 'generation': 71,
                        'shared_guard_profile': self.policy}
        self.tables = {}
        self.writes = []
        self.saved = []

    def kernel(self, argv, ns=None, data=None, **kwargs):
        if argv == ['ip', '-d', '-j', 'link', 'show', 'dev', 'eth0']:
            return subprocess.CompletedProcess(
                argv, 0, stdout=json.dumps([{'ifname': 'eth0', 'flags': ['UP'],
                                             'linkinfo': {}}]).encode(), stderr=b'')
        if argv == ['ip', '-j', 'link', 'show'] and ns is None:
            return subprocess.CompletedProcess(
                argv, 0, stdout=json.dumps([
                    {'ifname': manager.ROOT_IF, 'flags': ['UP']},
                    {'ifname': manager.BUS_IF, 'flags': ['UP']},
                    {'ifname': 'eth0', 'flags': ['UP']},
                ]).encode(), stderr=b'')
        if argv == ['ip', '-j', 'link', 'show'] and ns == manager.TRANSPORT:
            return subprocess.CompletedProcess(
                argv, 0, stdout=json.dumps([
                    {'ifname': 'lo', 'flags': ['UP']},
                    {'ifname': manager.NS_IF, 'flags': ['UP']},
                ]).encode(), stderr=b'')
        if argv == ['ip', '-j', 'link', 'show'] and ns == manager.GW:
            return subprocess.CompletedProcess(
                argv, 0, stdout=json.dumps([
                    {'ifname': 'lo', 'flags': ['UP']},
                    {'ifname': 'wg0', 'flags': ['UP']},
                    {'ifname': manager.GW_BUS_IF, 'flags': ['UP']},
                ]).encode(), stderr=b'')
        if argv == ['ip', '-4', '-j', 'route', 'get', '192.0.2.2']:
            return subprocess.CompletedProcess(
                argv, 0, stdout=json.dumps([{'dev': 'eth0'}]).encode(), stderr=b'')
        # shared_root_runtime_matches only inspects the root namespace, so a
        # sibling distro never opens the manager's private /run/netns binds.
        if (argv[:8] == ['ip', '-4', '-j', 'route', 'get', '192.0.2.2',
                         'from', manager.TRANSPORT_IP] and
                argv[8:] == ['iif', manager.ROOT_IF]):
            return subprocess.CompletedProcess(
                argv, 0, stdout=json.dumps([{'dev': 'eth0'}]).encode(), stderr=b'')
        if argv == ['ip', '-4', '-N', '-j', 'route', 'show', 'table', manager.ROUTE_TABLE]:
            return subprocess.CompletedProcess(
                argv, 0, stdout=json.dumps([
                    {'dst': 'default', 'dev': manager.BUS_IF,
                     'gateway': manager.BUS_GW_IP},
                    {'dst': 'default', 'type': 'unreachable'},
                ]).encode(), stderr=b'')
        if argv == ['ip', '-4', '-j', 'rule', 'show']:
            return subprocess.CompletedProcess(
                argv, 0, stdout=json.dumps([
                    {'priority': manager.PREF_DEFAULT_DENY,
                     'table': int(manager.ROUTE_TABLE)}]).encode(), stderr=b'')
        if argv == ['ip', '-4', '-j', 'route', 'show'] and ns == manager.TRANSPORT:
            return subprocess.CompletedProcess(
                argv, 0, stdout=json.dumps([
                    {'dst': '192.0.2.2/32', 'dev': manager.NS_IF,
                     'gateway': manager.ROOT_IP},
                ]).encode(), stderr=b'')
        if argv == ['ip', '-4', '-j', 'route', 'show'] and ns == manager.GW:
            return subprocess.CompletedProcess(
                argv, 0, stdout=json.dumps([
                    {'dst': 'default', 'dev': 'wg0'},
                ]).encode(), stderr=b'')
        if argv == ['ip', '-6', '-j', 'route', 'show'] and ns == manager.GW:
            return subprocess.CompletedProcess(
                argv, 0, stdout=json.dumps([
                    {'dst': 'default', 'type': 'unreachable'},
                ]).encode(), stderr=b'')
        if argv == ['wg', 'show', 'wg0', 'endpoints'] and ns == manager.GW:
            return subprocess.CompletedProcess(
                argv, 0, stdout=b'peer-key\t192.0.2.2:51820\n', stderr=b'')
        if argv == ['wg', 'show', 'wg0', 'allowed-ips'] and ns == manager.GW:
            return subprocess.CompletedProcess(
                argv, 0, stdout=b'peer-key\t0.0.0.0/0\n', stderr=b'')
        if argv[:6] == ['nft', '-j', 'list', 'table', 'inet', manager.TABLE] or \
                argv[:6] == ['nft', '-j', 'list', 'table', 'inet', manager.BOOT_EMERGENCY]:
            listed = self.tables.get(argv[5])
            return subprocess.CompletedProcess(
                argv, 0 if listed is not None else 1,
                stdout=json.dumps(listed).encode() if listed is not None else b'',
                stderr=b'' if listed is not None else b'No such file or directory')
        if argv == ['nft', '-f', '-']:
            self.writes.append(data)
            if data == manager.static_boot_rules().encode():
                fixture = manager_table_fixture()
                fixture['nftables'][0]['table']['comment'] = manager.STATIC_BOOT_COMMENT
                self.tables[manager.TABLE] = fixture
            elif data == manager.boot_emergency_rules().encode():
                items = [{'table': {'family': 'inet', 'name': manager.BOOT_EMERGENCY,
                                     'comment': manager.BOOT_EMERGENCY_COMMENT}}]
                for name in ('output', 'forward'):
                    items += [
                        {'chain': {'family': 'inet', 'table': manager.BOOT_EMERGENCY,
                                   'name': name, 'type': 'filter', 'hook': name,
                                   'prio': -200, 'policy': 'drop'}},
                        {'rule': {'family': 'inet', 'table': manager.BOOT_EMERGENCY,
                                  'chain': name, 'expr': [{'counter': {}}, {'drop': None}]}}]
                self.tables[manager.BOOT_EMERGENCY] = {'nftables': items}
            else:
                self.fail('Boot hook attempted to replace a shared table')
            return subprocess.CompletedProcess(argv, 0, stdout=b'', stderr=b'')
        self.fail('Unexpected kernel operation: ' + repr(argv))

    def boot(self):
        (self.state_path / 'state.json').write_bytes(manager.encode(self.journal))
        with patch.object(manager, 'STATE', self.state_path), \
                patch.object(manager, 'private_path', side_effect=lambda path: Path(path)), \
                patch.object(manager, 'command', side_effect=self.kernel), \
                patch.object(manager, 'boot_id', return_value='current'), \
                patch.object(manager.os, 'readlink', return_value='current'), \
                patch.object(manager, 'read_profile', side_effect=AssertionError('manager private profile read')):
            instance = manager.Manager(manager.parse(['guard']))
            instance.save = Mock(side_effect=lambda: self.saved.append(
                {'phase': instance.s.get('phase'),
                 'root_namespace': instance.s.get('root_namespace'),
                 'boot_id': instance.s.get('boot_id')}))
            return instance.boot_guard()

    def test_sibling_boot_retains_exact_running_manager_without_private_manager_state(self):
        for comment in ('cor-egress:manager-owner', None):
            with self.subTest(comment=comment):
                fixture = manager_table_fixture('manager-owner', True, self.runtime, self.policy)
                if comment is None:
                    fixture['nftables'][0]['table'].pop('comment')
                self.tables = {manager.TABLE: fixture}
                before = json.loads(json.dumps(fixture))
                result = self.boot()
                self.assertEqual(result['outcome'], 'succeeded')
                self.assertEqual(self.tables[manager.TABLE], before)
                self.assertEqual(self.writes, [])
                self.assertNotIn(manager.BOOT_EMERGENCY, self.tables)

    def test_sibling_boot_accepts_single_root_source_and_no_native_bridges(self):
        runtime = dict(self.runtime, root_sources=[manager.BUS_ROOT_IP + '/32'],
                       forward_sources=[])
        self.tables[manager.TABLE] = manager_table_fixture(
            'manager-owner', True, runtime, self.policy)
        self.assertEqual(self.boot()['outcome'], 'succeeded')
        self.assertEqual(self.writes, [])

    def test_sibling_boot_retains_exact_closed_manager_with_different_owner(self):
        self.tables[manager.TABLE] = manager_table_fixture('manager-owner')
        # A closed deny can also be safely recognized for older journals.
        self.journal.pop('shared_guard_profile')
        self.assertEqual(self.boot()['outcome'], 'succeeded')
        self.assertEqual(self.writes, [])

    def test_first_sibling_boot_creates_only_static_deny(self):
        self.assertEqual(self.boot()['outcome'], 'succeeded')
        self.assertEqual(self.writes, [manager.static_boot_rules().encode()])
        self.assertIn(manager.TABLE, self.tables)
        self.assertNotIn(manager.BOOT_EMERGENCY, self.tables)

    def test_sibling_boot_preserves_unknown_manager_and_installs_independent_deny(self):
        baseline = manager_table_fixture('manager-owner', True, self.runtime, self.policy)
        mutations = []
        endpoint = json.loads(json.dumps(baseline))
        endpoint['nftables'] = json.loads(json.dumps(endpoint['nftables']).replace(
            '"192.0.2.2"', '"203.0.113.9"'))
        mutations.append(endpoint)
        resolver = json.loads(json.dumps(baseline))
        resolver['nftables'] = json.loads(json.dumps(resolver['nftables']).replace(
            '"10.77.0.1"', '"203.0.113.10"'))
        mutations.append(resolver)
        unbounded = json.loads(json.dumps(baseline))
        unbounded['nftables'].append({'rule': {
            'family': 'inet', 'table': manager.TABLE, 'chain': 'output',
            'expr': [{'accept': None}]}})
        mutations.append(unbounded)
        without_ipv6 = json.loads(json.dumps(baseline))
        without_ipv6['nftables'] = [
            item for item in without_ipv6['nftables']
            if not (item.get('rule', {}).get('chain') == 'forward' and
                    item['rule']['expr'][0].get('match', {}).get('left') ==
                    {'meta': {'key': 'nfproto'}})]
        mutations.append(without_ipv6)
        unknown_object = json.loads(json.dumps(baseline))
        unknown_object['nftables'].append({'set': {
            'family': 'inet', 'table': manager.TABLE, 'name': 'foreign'}})
        mutations.append(unknown_object)
        for fixture in mutations:
            with self.subTest(fixture=fixture):
                self.tables = {manager.TABLE: fixture}
                self.writes = []
                self.assertEqual(self.boot()['outcome'], 'blocked')
                self.assertEqual(self.tables[manager.TABLE], fixture)
                self.assertEqual(self.writes, [manager.boot_emergency_rules().encode()])

    def test_sibling_boot_refuses_running_guard_without_public_constraints(self):
        self.journal.pop('shared_guard_profile')
        self.tables[manager.TABLE] = manager_table_fixture(
            'manager-owner', True, self.runtime, self.policy)
        self.assertEqual(self.boot()['outcome'], 'blocked')
        self.assertEqual(self.writes, [manager.boot_emergency_rules().encode()])

    def test_sibling_boot_rejects_open_table_without_live_runtime(self):
        self.tables[manager.TABLE] = manager_table_fixture(
            'manager-owner', True, self.runtime, self.policy)
        with patch.object(manager, 'shared_root_runtime_matches', return_value=False) as runtime:
            self.assertEqual(self.boot()['outcome'], 'blocked')
        runtime.assert_called_once_with(self.policy, 'eth0')
        self.assertEqual(self.writes, [manager.boot_emergency_rules().encode()])

    def test_shared_uplink_classifier_rejects_virtual_link_kind(self):
        with patch.object(manager, 'json_command', return_value=[{
                'ifname': 'eth0', 'flags': ['UP'],
                'linkinfo': {'info_kind': 'veth'}}]):
            self.assertFalse(manager.valid_uplink_interface('eth0'))

    def test_shared_uplink_classifier_accepts_only_exact_isolated_ci_fixture(self):
        fixture = [{'ifname': 'fixture-uplink', 'flags': ['UP'],
                    'linkinfo': {'info_kind': 'veth'}}]
        with patch.object(manager, 'ISOLATED_TEST_ENV', True), \
                patch.object(manager, 'json_command', return_value=fixture):
            self.assertTrue(manager.valid_uplink_interface('fixture-uplink'))

    def test_shared_uplink_classifier_requires_both_isolated_ci_gates(self):
        fixture = [{'ifname': 'fixture-uplink', 'flags': ['UP'],
                    'linkinfo': {'info_kind': 'veth'}}]
        with patch.object(manager, 'ISOLATED_TEST_ENV', False), \
                patch.object(manager, 'json_command', return_value=fixture):
            self.assertFalse(manager.valid_uplink_interface('fixture-uplink'))

    def test_shared_uplink_classifier_rejects_other_virtual_fixture_name_or_kind(self):
        with patch.object(manager, 'ISOLATED_TEST_ENV', True):
            for name, kind in (('other-uplink', 'veth'),
                               ('fixture-uplink', 'wireguard')):
                with self.subTest(name=name, kind=kind), \
                        patch.object(manager, 'json_command', return_value=[{
                            'ifname': name, 'flags': ['UP'],
                            'linkinfo': {'info_kind': kind}}]):
                    self.assertFalse(manager.valid_uplink_interface(name))

    def test_shared_uplink_classifier_rejects_virtual_link_name(self):
        with patch.object(manager, 'json_command') as json_command:
            self.assertFalse(manager.valid_uplink_interface('docker0'))
        json_command.assert_not_called()

    def test_configure_persists_only_public_guard_constraints(self):
        profile = dict(self.policy, backend='wireguard', private_key='secret-key',
                       peer_public_key='public-key', unused_future_field='secret')
        instance = object.__new__(manager.Manager)
        instance.s = {}
        instance.args = manager.parse(['configure', '--generation', '71'])
        instance.save = Mock()
        instance.distro_prepare = Mock()
        instance.event = Mock()
        with patch.object(manager.sys, 'stdin', Mock(buffer=io.BytesIO(b'{}'))), \
                patch.object(manager, 'profile_validate', return_value=profile), \
                patch.object(manager.os, 'readlink', return_value='shared-netns'), \
                patch.object(manager, 'boot_id', return_value='current'):
            instance.configure()
        self.assertEqual(instance.s['shared_guard_profile'], self.policy)
        self.assertNotIn('private_key', json.dumps(instance.s))
        self.assertNotIn('peer_public_key', json.dumps(instance.s))
        self.assertNotIn('unused_future_field', json.dumps(instance.s))


class StartEmergencyGuardTests(unittest.TestCase):
    """start() must never report Running while a boot deny is still present."""

    def setUp(self):
        self.instance = object.__new__(manager.Manager)
        self.instance.s = {'phase': 'Running', 'owner': 'owned'}
        self.instance.load = Mock()
        self.instance.assert_table = Mock()
        self.instance.checks = []

    def test_start_refuses_an_existing_boot_emergency_table(self):
        with patch.object(manager, 'list_table', return_value={'nftables': []}), \
                self.assertRaises(manager.Blocked) as raised:
            manager.Manager.start(self.instance)
        self.assertEqual(str(raised.exception),
                         'Existing boot emergency table preserved; explicit recovery is required.')
        self.instance.assert_table.assert_not_called()

    def test_start_proceeds_when_no_boot_emergency_table_exists(self):
        with patch.object(manager, 'list_table', return_value=None), \
                patch.object(manager, 'shared_root_runtime_matches', return_value=True):
            # Stop before any further work so only the guard question is answered.
            self.instance.assert_table = Mock(side_effect=manager.Blocked('stop'))
            with self.assertRaises(manager.Blocked):
                manager.Manager.start(self.instance)
        self.instance.assert_table.assert_called_once()


class GatewayForwardSysctlTests(unittest.TestCase):
    """The gateway namespace global ip_forward must be journaled and restored."""

    def setUp(self):
        self.instance = object.__new__(manager.Manager)
        self.instance.s = {'uplink': 'eth0', 'forward_sources': [], 'sysctls': [],
                           'root_namespace': 'current', 'boot_id': 'current'}
        self.instance.p = {'backend': 'wireguard'}
        self.instance.save = Mock()
        self.writes = []

    def kernel(self, argv, ns=None, data=None, **kwargs):
        self.writes.append((ns, argv, data))
        if argv[0] == 'cat':
            # The disable path verifies the value it wrote before restoring.
            # Journal records hold the value the test intends to observe.
            record = next((rec for rec in self.instance.s.get('sysctls', [])
                           if rec.get('path') == argv[1]), None)
            value = record['written'] if record else '0'
            return subprocess.CompletedProcess(
                argv, 0, stdout=(value + '\n').encode(), stderr=b'')
        return subprocess.CompletedProcess(argv, 0, stdout=b'', stderr=b'')

    def links(self, argv, ns=None, data=None, **kwargs):
        return [{'ifname': ns or 'root', 'ifindex': 7}]

    def test_enable_journals_and_sets_the_namespace_global_forward(self):
        with patch.object(manager, 'command', side_effect=self.kernel), \
                patch.object(manager, 'json_command', side_effect=self.links):
            manager.Manager.sysctl_forward(self.instance, True)
        global_records = [rec for rec in self.instance.s['sysctls']
                          if rec.get('scope') == 'namespace']
        self.assertEqual(len(global_records), 1)
        self.assertEqual(global_records[0]['namespace'], manager.GW)
        self.assertEqual(global_records[0]['path'],
                         '/proc/sys/net/ipv4/ip_forward')
        self.assertEqual(global_records[0]['before'], '0')
        self.assertEqual(global_records[0]['written'], '1')
        self.assertIn((manager.GW, ['tee', '/proc/sys/net/ipv4/ip_forward'], b'1\n'),
                      self.writes)

    def test_disable_restores_the_recorded_before_value(self):
        self.instance.s['sysctls'] = [{
            'namespace': manager.GW, 'path': '/proc/sys/net/ipv4/ip_forward',
            'before': '0', 'written': '1', 'scope': 'namespace'}]
        with patch.object(manager, 'command', side_effect=self.kernel), \
                patch.object(manager, 'json_command', side_effect=self.links):
            manager.Manager.sysctl_forward(self.instance, False)
        self.assertIn((manager.GW, ['tee', '/proc/sys/net/ipv4/ip_forward'], b'0\n'),
                      self.writes)


class SharedRootRuntimeTests(unittest.TestCase):
    """A sibling distro must never require the manager's private netns binds."""

    policy = {'endpoint_ipv4': '192.0.2.2', 'endpoint_port': 51820,
              'resolver_ipv4': '10.77.0.1'}

    def kernel(self, argv, ns=None, data=None, **kwargs):
        if argv[:5] == ['ip', '-4', '-j', 'route', 'get']:
            return [{'dev': 'eth0'}]
        if argv == ['ip', '-j', 'link', 'show']:
            return [
                {'ifname': manager.ROOT_IF, 'flags': ['UP']},
                {'ifname': manager.BUS_IF, 'flags': ['UP']},
            ]
        if argv[5:] == ['show', 'table', manager.ROUTE_TABLE]:
            return [
                {'dst': 'default', 'dev': manager.BUS_IF,
                 'gateway': manager.BUS_GW_IP},
                {'dst': 'default', 'type': 'unreachable'},
            ]
        if argv == ['ip', '-4', '-j', 'rule', 'show']:
            return [{'priority': manager.PREF_DEFAULT_DENY,
                     'table': int(manager.ROUTE_TABLE)}]
        raise AssertionError('Unexpected kernel operation: ' + repr(argv))

    def test_root_only_proof_never_opens_a_private_netns(self):
        with patch.object(manager, 'valid_uplink_interface', return_value=True), \
                patch.object(manager, 'json_command', side_effect=self.kernel):
            self.assertTrue(manager.shared_root_runtime_matches(self.policy, 'eth0'))

    def test_missing_uplink_route_is_rejected(self):
        def bad_route(argv, ns=None, data=None, **kwargs):
            if argv[:5] == ['ip', '-4', '-j', 'route', 'get']:
                return [{'dev': 'other'}]
            raise AssertionError('unexpected: ' + repr(argv))

        with patch.object(manager, 'valid_uplink_interface', return_value=True), \
                patch.object(manager, 'json_command', side_effect=bad_route):
            self.assertFalse(manager.shared_root_runtime_matches(self.policy, 'eth0'))

    def test_numeric_unreachable_type_is_accepted(self):
        # iproute2 6.x (Ubuntu 26.04) reports RTN_UNREACHABLE as the number 7
        # instead of the name. A sibling distro must still recognize the
        # manager's exact closed route, or it installs a global boot emergency
        # deny on every launch.
        def numeric(argv, ns=None, data=None, **kwargs):
            if argv[5:] == ['show', 'table', manager.ROUTE_TABLE]:
                return [
                    {'dst': 'default', 'dev': manager.BUS_IF,
                     'gateway': manager.BUS_GW_IP},
                    {'dst': 'default', 'type': '7'},
                ]
            return self.kernel(argv, ns=ns, data=data, **kwargs)

        with patch.object(manager, 'valid_uplink_interface', return_value=True), \
                patch.object(manager, 'json_command', side_effect=numeric):
            self.assertTrue(manager.shared_root_runtime_matches(self.policy, 'eth0'))

    def test_unreachable_helper_accepts_both_forms(self):
        self.assertTrue(manager.unreachable_default({'type': 'unreachable'}))
        self.assertTrue(manager.unreachable_default({'type': '7'}))
        self.assertFalse(manager.unreachable_default({'type': 'unicast'}))
        self.assertFalse(manager.unreachable_default({'dst': '192.0.2.0/24',
                                                      'type': '7'}))

    def test_icmp_code_normalization_treats_name_and_number_alike(self):
        # nftables 1.1.x emits frag-needed as 4; 1.0.x keeps the name.
        named = [{'match': {'op': '==', 'left': {'payload': {'protocol': 'icmp',
                                                             'field': 'code'}},
                            'right': 'frag-needed'}}]
        numeric = [{'match': {'op': '==', 'left': {'payload': {'protocol': 'icmp',
                                                              'field': 'code'}},
                              'right': 4}}]
        self.assertEqual(manager.normalize_rule_values(named),
                         manager.normalize_rule_values(numeric))

    def test_icmp_normalization_leaves_unrelated_values(self):
        self.assertEqual(manager.normalize_rule_values({'right': 53}), {'right': 53})
        self.assertEqual(manager.normalize_rule_values({'right': 'destination-unreachable'}),
                         {'right': 'destination-unreachable'})

    def test_numeric_unreachable_type_in_gateway_namespace(self):
        # shared_manager_runtime_matches also inspects the gateway namespace's
        # IPv6 default route; the same version skew applies there.
        def numeric_ipv6(argv, ns=None, data=None, **kwargs):
            if argv == ['ip', '-6', '-j', 'route', 'show'] and ns == manager.GW:
                return [{'dst': 'default', 'type': '7'}]
            return kernel(argv, ns=ns, data=data, **kwargs)

        def kernel(argv, ns=None, data=None, **kwargs):
            if argv == ['ip', '-4', '-j', 'route', 'get', '192.0.2.2']:
                return [{'dev': 'eth0'}]
            if argv == ['ip', '-j', 'link', 'show'] and ns == manager.TRANSPORT:
                return [{'ifname': 'lo', 'flags': ['UP']},
                        {'ifname': manager.NS_IF, 'flags': ['UP']}]
            if argv == ['ip', '-j', 'link', 'show'] and ns == manager.GW:
                return [{'ifname': 'lo', 'flags': ['UP']},
                        {'ifname': 'wg0', 'flags': ['UP']},
                        {'ifname': manager.GW_BUS_IF, 'flags': ['UP']}]
            if argv == ['ip', '-j', 'link', 'show']:
                return [{'ifname': manager.ROOT_IF, 'flags': ['UP']},
                        {'ifname': manager.BUS_IF, 'flags': ['UP']}]
            if argv == ['ip', '-4', '-j', 'route', 'show'] and ns == manager.TRANSPORT:
                return [{'dst': '192.0.2.2/32', 'dev': manager.NS_IF,
                         'gateway': manager.ROOT_IP}]
            if argv == ['ip', '-4', '-j', 'route', 'show'] and ns == manager.GW:
                return [{'dst': 'default', 'dev': 'wg0'}]
            if argv == ['wg', 'show', 'wg0', 'endpoints'] and ns == manager.GW:
                return SimpleNamespace(stdout=b'peer-key\t192.0.2.2:51820\n')
            if argv == ['wg', 'show', 'wg0', 'allowed-ips'] and ns == manager.GW:
                return SimpleNamespace(stdout=b'peer-key\t0.0.0.0/0\n')
            raise AssertionError('Unexpected kernel operation: ' + repr(argv))

        with patch.object(manager, 'valid_uplink_interface', return_value=True), \
                patch.object(manager, 'command', side_effect=kernel), \
                patch.object(manager, 'json_command', side_effect=numeric_ipv6):
            self.assertTrue(manager.shared_manager_runtime_matches(self.policy, 'eth0'))


class DistroRestoreTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.instance = object.__new__(manager.Manager)
        self.instance.args = manager.parse([
            'restore-config', '--generation', '72', '--allow-unconfigured'])
        self.instance.file = Path(self.temp.name) / 'state.json'
        self.instance.s = {}
        self.instance.p = None
        self.instance.checks = []
        self.instance.save = Mock()
        self.instance.restore_files = Mock()

    def test_configure_failure_before_journal_allows_noop_restore(self):
        self.instance.args = manager.parse(['configure', '--generation', '72'])
        with patch.object(manager.sys, 'stdin', Mock(buffer=io.BytesIO(b'{}'))), \
                patch.object(manager, 'profile_validate', side_effect=manager.Blocked('invalid profile')):
            with self.assertRaises(manager.Blocked):
                self.instance.configure()
        self.instance.args = manager.parse([
            'restore-config', '--generation', '72', '--allow-unconfigured'])
        event = self.instance.restore_config()
        self.assertEqual(event['outcome'], 'succeeded')
        self.assertEqual(event['generation'], 72)
        self.assertEqual(event['phase'], 'DistroUnconfigured')
        self.assertEqual(event['facts'], {'configuration_restore': 'not_started'})
        self.assertEqual(self.instance.s, {})
        self.instance.save.assert_not_called()
        self.instance.restore_files.assert_not_called()

    def test_clean_older_retired_distro_is_preserved_on_noop_restore(self):
        state = {'schema': 1, 'generation': 71, 'role': 'distro-config',
                 'phase': 'DistroRestored', 'files': {}}
        self.instance.s = state.copy()
        event = self.instance.restore_config()
        self.assertEqual(event['outcome'], 'succeeded')
        self.assertEqual(event['generation'], 72)
        self.assertEqual(self.instance.s, state)
        self.instance.save.assert_not_called()
        self.instance.restore_files.assert_not_called()

    def test_current_transaction_still_restores_files_and_saves_retired_state(self):
        self.instance.s = {'generation': 72, 'role': 'distro-config',
                           'phase': 'ConfiguringDistro', 'files': {}}
        event = self.instance.restore_config()
        self.assertEqual(event['generation'], 72)
        self.assertEqual(event['phase'], 'DistroRestored')
        self.instance.restore_files.assert_called_once()
        self.instance.save.assert_called_once()

    def test_missing_or_retired_proof_cannot_hide_existing_or_foreign_journal(self):
        self.instance.file.write_text('{}')
        with self.assertRaises(manager.Blocked):
            self.instance.restore_config()
        self.instance.file.unlink()
        retired = {'schema': 1, 'generation': 71, 'role': 'distro-config',
                   'phase': 'DistroRestored', 'files': {}}
        for change in (
                {'schema': 2}, {'schema': True}, {'phase': 'ConfiguringDistro'}, {'generation': 73},
                {'generation': 0}, {'generation': True}, {'role': 'manager'},
                {'files': {'/etc/wsl.conf': {'pending': True}}},
                {'tables': {'root': 'hash'}}, {'namespaces': {'owned': {}}},
                {'routing': {'owned': True}}, {'sysctls': {'owned': True}}):
            with self.subTest(change=change):
                self.instance.s = dict(retired, **change)
                with self.assertRaises(manager.Blocked):
                    self.instance.restore_config()
        self.instance.restore_files.assert_not_called()
        self.instance.save.assert_not_called()

    def test_current_generation_file_drift_is_still_blocking(self):
        self.instance.s = {'generation': 72, 'role': 'distro-config',
                           'phase': 'ConfiguringDistro', 'files': {}}
        self.instance.restore_files.side_effect = manager.Blocked('Distro configuration drift')
        with self.assertRaisesRegex(manager.Blocked, 'configuration drift'):
            self.instance.restore_config()
        self.instance.save.assert_not_called()

    def test_noop_restore_requires_explicit_pending_transaction_permission(self):
        self.instance.args = manager.parse(['restore-config', '--generation', '72'])
        with self.assertRaises(manager.Blocked):
            self.instance.restore_config()
        self.instance.s = {'schema': 1, 'generation': 71, 'role': 'distro-config',
                           'phase': 'DistroRestored', 'files': {}}
        with self.assertRaisesRegex(manager.Blocked, 'Generation mismatch'):
            self.instance.restore_config()
        self.instance.restore_files.assert_not_called()
        self.instance.save.assert_not_called()

    def test_unconfigured_permission_is_restricted_to_restore_config(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                manager.parse(['rollback', '--generation', '72', '--allow-unconfigured'])


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
    def test_manager_lock_waits_for_boot_guard_before_first_start(self):
        lock = object()
        with patch.object(manager.fcntl, 'flock',
                          side_effect=[BlockingIOError(errno.EAGAIN, 'busy'), None]) as flock, \
                patch.object(manager.time, 'monotonic', side_effect=[0.0, 0.0, 0.1]), \
                patch.object(manager.time, 'sleep') as sleep:
            manager.acquire_manager_lock(lock)
        self.assertEqual(flock.call_count, 2)
        sleep.assert_called_once_with(manager.MANAGER_LOCK_POLL_SECONDS)

    def test_manager_lock_timeout_stays_fail_closed(self):
        lock = object()
        with patch.object(manager.fcntl, 'flock',
                          side_effect=BlockingIOError(errno.EAGAIN, 'busy')), \
                patch.object(manager.time, 'monotonic',
                             side_effect=[0.0, manager.MANAGER_LOCK_WAIT_SECONDS]):
            with self.assertRaisesRegex(manager.Blocked, 'manager operation remained active'):
                manager.acquire_manager_lock(lock)

    def test_boot_guard_uses_fixed_installed_wrapper(self):
        self.assertEqual(manager.boot_guard_command(),
                         '/usr/local/lib/cor-egress/manager guard')

    def test_distro_prepare_snapshots_fixed_boot_guard_for_every_role(self):
        for role in ('manager', 'distro-config'):
            with self.subTest(role=role), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                files = {
                    '/etc/wsl.conf': root / 'wsl.conf',
                    '/etc/resolv.conf': root / 'resolv.conf',
                    '/etc/hosts': root / 'hosts',
                }
                instance = object.__new__(manager.Manager)
                instance.s = {'role': role}
                instance.p = {'resolver_ipv4': '10.77.0.1'}
                instance.snapshot = Mock()

                def fixture_path(value):
                    return files.get(str(value), Path(value))

                with patch.object(manager, 'Path', side_effect=fixture_path), \
                        patch.object(manager.socket, 'gethostname', return_value='fixture-wsl'):
                    instance.distro_prepare()

                snapshots = {
                    Path(call.args[0]).name: call.args[1]
                    for call in instance.snapshot.call_args_list
                }
                wsl_conf = snapshots['wsl.conf'].decode()
                self.assertIn('[network]', wsl_conf)
                self.assertIn('generateResolvConf = false', wsl_conf)
                self.assertIn('generateHosts = false', wsl_conf)
                self.assertIn('[interop]', wsl_conf)
                self.assertIn('enabled = false', wsl_conf)
                self.assertIn('appendWindowsPath = false', wsl_conf)
                self.assertIn('[boot]', wsl_conf)
                self.assertIn('command = ' + manager.boot_guard_command(), wsl_conf)
                self.assertEqual(
                    snapshots['resolv.conf'],
                    b'nameserver 10.77.0.1\noptions timeout:2 attempts:1\n')
                self.assertIn(b'127.0.1.1 fixture-wsl\n', snapshots['hosts'])
                self.assertEqual(instance.snapshot.call_count, 3)

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
                patch.object(manager.os, 'geteuid', return_value=0, create=True), \
                patch.object(manager.os, 'O_NOFOLLOW', 0, create=True), \
                patch.object(manager.os, 'environ', {}), \
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
        instance.save = Mock()
        instance.load = Mock(side_effect=AssertionError('private profile read'))
        instance.event = Mock(return_value={'outcome': 'succeeded'})
        with patch.object(manager, 'list_table', return_value=None), \
                patch.object(manager, 'ensure_static_boot_guard', return_value='static'), \
                patch.object(manager, 'boot_id', return_value='current'), \
                patch.object(manager.os, 'readlink', return_value='current'), \
                patch.object(manager, 'command') as command:
            instance.boot_guard()
        instance.load.assert_not_called()
        command.assert_not_called()

    def test_distro_config_boot_guard_preserves_manager_or_static_table(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'role': 'distro-config', 'phase': 'DistroConfigured'}
        instance.event = Mock(return_value={'outcome': 'succeeded'})
        instance.save = Mock()
        with patch.object(manager, 'list_table', return_value=None), \
                patch.object(manager, 'ensure_static_boot_guard', return_value='static'), \
                patch.object(manager, 'boot_id', return_value='current'), \
                patch.object(manager.os, 'readlink', return_value='current'), \
                patch.object(manager, 'command') as command:
            instance.boot_guard()
        command.assert_not_called()
        # The sibling refresh persists this boot's shared-root identity.
        self.assertEqual(instance.s['root_namespace'], 'current')
        self.assertEqual(instance.s['boot_id'], 'current')

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
        instance.save = Mock()
        instance.load = Mock(side_effect=AssertionError('private profile read'))
        instance.event = Mock(return_value={'outcome': 'succeeded'})
        with patch.object(manager, 'list_table', return_value=None), \
                patch.object(manager, 'ensure_static_boot_guard', return_value='manager'), \
                patch.object(manager, 'boot_id', return_value='current'), \
                patch.object(manager.os, 'readlink', return_value='current'), \
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

    def test_static_shape_is_adopted_before_ambiguous_manager_match(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'owner': 'owned', 'phase': 'Guarded', 'tables': {}}
        instance.save = Mock()
        instance.root_rules = Mock(return_value='closed-rules')
        with patch.object(manager, 'table_hash', side_effect=['static', 'manager']), \
                patch.object(manager, 'static_boot_matches', return_value=True), \
                patch.object(manager, 'manager_table_matches', return_value=True) as manager_match, \
                patch.object(manager, 'command') as command:
            instance.install_manager_after_boot_guard()
        manager_match.assert_not_called()
        command.assert_called_once_with(
            ['nft', '-f', '-'],
            data=('delete table inet cor_egress_guard\nclosed-rules').encode())
        self.assertEqual(instance.s['tables'], {'root': 'manager'})

    def test_running_manager_is_closed_before_guarded_phase(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'owner': 'owned', 'phase': 'Running', 'tables': {}}
        instance.p = {'endpoint_ipv4': '192.0.2.2', 'endpoint_port': 51820,
                      'resolver_ipv4': '10.77.0.1'}
        instance.save = Mock()
        instance.root_rules = Mock(return_value='closed-rules')
        instance.replace_table = Mock()
        with patch.object(manager, 'table_hash', return_value='manager'), \
                patch.object(manager, 'manager_table_matches', return_value=True), \
                patch.object(manager, 'static_boot_matches', return_value=False):
            instance.install_manager_after_boot_guard()
        instance.replace_table.assert_called_once_with('closed-rules')
        self.assertEqual(instance.s['phase'], 'Guarded')

    def test_boot_reconcile_closes_open_table_before_recording_guarded(self):
        instance = object.__new__(manager.Manager)
        instance.s = {
            'owner': 'owned', 'phase': 'Running', 'root_namespace': 'old',
            'boot_id': 'old', 'namespaces': {}, 'tables': {'root': 'opened'},
            'uplink': 'eth0', 'root_sources': ['10.20.0.1/32'],
            'forward_sources': [
                {'interface': 'docker0', 'source_cidr': '172.18.0.0/16'}
            ],
        }
        instance.p = {'endpoint_ipv4': '192.0.2.2', 'endpoint_port': 51820,
                      'resolver_ipv4': '10.77.0.1'}
        instance.policy_routes = Mock(return_value=[])
        instance.root_rules = Mock(return_value='closed-rules')
        events = []
        instance.replace_table = Mock(
            side_effect=lambda rules: events.append(('close', instance.s['phase'], rules)))
        instance.save = Mock(side_effect=lambda: events.append(('save', instance.s['phase'])))
        with patch.object(manager.os, 'readlink', return_value='new'), \
                patch.object(manager, 'boot_id', return_value='new'), \
                patch.object(manager.Path, 'exists', return_value=False), \
                patch.object(manager.Path, 'is_symlink', return_value=False), \
                patch.object(manager, 'json_command', side_effect=[[], []]), \
                patch.object(manager, 'table_hash', side_effect=['opened', 'closed']), \
                patch.object(manager, 'table_classification', return_value='manager'), \
                patch.object(manager, 'manager_table_matches_opened_install', return_value=True), \
                patch.object(manager, 'static_boot_matches', return_value=True), \
                patch.object(manager, 'list_table', return_value=None):
            instance.boot_reconcile()
        self.assertEqual(events[0], ('close', 'Running', 'closed-rules'))
        self.assertEqual(instance.s['phase'], 'Guarded')
        self.assertEqual(instance.s['tables'], {'root': 'closed'})

    def test_cold_boot_running_journal_adopts_new_static_deny_before_manager_guard(self):
        instance = object.__new__(manager.Manager)
        instance.s = {
            'owner': 'owned', 'generation': 71, 'role': 'manager',
            'phase': 'Running', 'root_namespace': 'old', 'boot_id': 'old',
            'namespaces': {manager.GW: {'inode': 'old'}},
            'tables': {'root': 'old-opened', manager.GW: 'old-gateway'},
            'attestation': 'old-audit', 'veth_index': 22,
            'uplink': 'eth0',
            'root_sources': ['10.20.0.1/32', manager.BUS_ROOT_IP + '/32'],
            'forward_sources': [
                {'interface': 'docker0', 'source_cidr': '172.18.0.0/16'}
            ],
        }
        instance.args = manager.parse(['guard'])
        instance.p = None
        instance.checks = []
        instance.load = Mock()
        instance.policy_routes = Mock(return_value=[])
        instance.interop_guard = Mock()
        tables, writes, saved = {}, [], []
        instance.save = Mock(
            side_effect=lambda: saved.append(json.loads(json.dumps(instance.s))))

        def kernel(argv, ns=None, data=None, **kwargs):
            self.assertIsNone(ns)
            if argv[:5] == ['nft', '-j', 'list', 'table', 'inet']:
                listed = tables.get(argv[5])
                return subprocess.CompletedProcess(
                    argv, 0 if listed is not None else 1,
                    stdout=json.dumps(listed).encode() if listed is not None else b'',
                    stderr=b'' if listed is not None else b'No such file or directory')
            if argv == ['nft', '-f', '-']:
                writes.append(data)
                if data == manager.static_boot_rules().encode():
                    fixture = manager_table_fixture()
                    fixture['nftables'][0]['table']['comment'] = manager.STATIC_BOOT_COMMENT
                else:
                    self.assertEqual(
                        data, ('delete table inet ' + manager.TABLE + '\n' +
                               instance.root_rules()).encode())
                    fixture = manager_table_fixture('owned')
                tables[manager.TABLE] = fixture
                return subprocess.CompletedProcess(argv, 0, stdout=b'', stderr=b'')
            if argv in (['ip', '-j', 'link', 'show'],
                        ['ip', '-4', '-j', 'rule', 'show']):
                return subprocess.CompletedProcess(argv, 0, stdout=b'[]', stderr=b'')
            self.fail('Unexpected cold-boot kernel operation: ' + repr(argv))

        with patch.object(manager, 'command', side_effect=kernel), \
                patch.object(manager, 'manager_table_matches_opened_install',
                             return_value=False), \
                patch.object(manager.os, 'readlink', return_value='new'), \
                patch.object(manager, 'boot_id', return_value='new'), \
                patch.object(manager, 'table_classification',
                             side_effect=['absent', 'static', 'static', 'static']), \
                patch.object(manager.Path, 'exists', return_value=False), \
                patch.object(manager.Path, 'is_symlink', return_value=False):
            result = instance.boot_guard()
            final_hash = manager.table_hash()
            self.assertIsNotNone(final_hash)
        self.assertEqual(result['outcome'], 'succeeded')
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0], manager.static_boot_rules().encode())
        self.assertEqual(saved[0]['phase'], 'Guarded')
        self.assertNotEqual(saved[0]['tables']['root'], 'old-opened')
        self.assertEqual(instance.s['tables'], {'root': final_hash})
        self.assertEqual(instance.s['phase'], 'Guarded')
        self.assertEqual(instance.s['namespaces'], {})
        self.assertNotIn('attestation', instance.s)
        self.assertNotIn('veth_index', instance.s)

    def test_cold_boot_running_journal_closes_surviving_opened_manager_guard(self):
        instance = object.__new__(manager.Manager)
        instance.s = {
            'owner': 'owned', 'generation': 71, 'role': 'manager',
            'phase': 'Running', 'root_namespace': 'old', 'boot_id': 'old',
            'namespaces': {manager.GW: {'inode': 'old'}},
            'tables': {'root': 'old-opened', manager.GW: 'old-gateway'},
            'attestation': 'old-audit', 'veth_index': 22,
            'uplink': 'eth0',
            'root_sources': ['10.20.0.1/32', manager.BUS_ROOT_IP + '/32'],
            'forward_sources': [
                {'interface': 'docker0', 'source_cidr': '172.18.0.0/16'}
            ],
        }
        instance.args = manager.parse(['guard'])
        instance.p = dict(endpoint_ipv4='192.0.2.2', endpoint_port=51820,
                          resolver_ipv4='10.77.0.1')
        instance.checks = []
        instance.load = Mock(side_effect=lambda: setattr(instance, 'p', {
            'endpoint_ipv4': '192.0.2.2', 'endpoint_port': 51820,
            'resolver_ipv4': '10.77.0.1'}))
        instance.rollback_attempted = False
        instance.dirty = False
        instance.close_requested = True
        instance.policy_routes = Mock(return_value=[])
        instance.interop_guard = Mock()
        runtime = {'uplink': 'eth0', 'root_sources': ['10.20.0.1/32', manager.BUS_ROOT_IP + '/32'],
                   'forward_sources': [
                       {'interface': 'docker0', 'source_cidr': '172.18.0.0/16'}
                   ]}
        policy = {'endpoint_ipv4': '192.0.2.2', 'endpoint_port': 51820,
                  'resolver_ipv4': '10.77.0.1'}
        instance.s['tables']['root'] = manager.digest(
            manager.encode(manager.clean_nft(manager_table_fixture(
                'owned', True, instance.s, policy))))
        opened = manager_table_fixture('owned', True, runtime, policy)
        tables = {manager.TABLE: opened, manager.BOOT_EMERGENCY: None}
        writes, saved = [], []
        instance.save = Mock(
            side_effect=lambda: saved.append(json.loads(json.dumps(instance.s))))

        def kernel(argv, ns=None, data=None, **kwargs):
            self.assertIsNone(ns)
            if argv[:5] == ['nft', '-j', 'list', 'table', 'inet']:
                key = argv[5]
                listed = tables.get(key)
                return subprocess.CompletedProcess(
                    argv, 0 if listed is not None else 1,
                    stdout=json.dumps(listed).encode() if listed is not None else b'',
                    stderr=b'' if listed is not None else b'No such file or directory')
            if argv == ['nft', '-f', '-'] and data == manager.boot_emergency_rules().encode():
                self.fail('An existing opened manager guard must be closed before emergency recovery.')
            if argv == ['nft', '-f', '-']:
                writes.append(data)
                if data == manager.static_boot_rules().encode():
                    self.fail('An existing opened manager guard must be closed, not shadowed.')
                self.assertEqual(
                    data, ('delete table inet ' + manager.TABLE + '\n' +
                           instance.root_rules()).encode())
                tables[manager.TABLE] = manager_table_fixture('owned')
                return subprocess.CompletedProcess(argv, 0, stdout=b'', stderr=b'')
            if argv in (['ip', '-j', 'link', 'show'],
                        ['ip', '-4', '-j', 'rule', 'show']):
                return subprocess.CompletedProcess(argv, 0, stdout=b'[]', stderr=b'')
            if argv == ['ip', '-d', '-j', 'link', 'show', 'dev', 'eth0']:
                return subprocess.CompletedProcess(
                    argv, 0, stdout=json.dumps([{
                        'ifname': 'eth0', 'flags': ['UP'], 'linkinfo': {}
                    }]).encode(), stderr=b'')
            if argv == ['ip', '-4', '-j', 'route', 'get', '192.0.2.2']:
                return subprocess.CompletedProcess(
                    argv, 0, stdout=json.dumps([{'dev': 'eth0'}]).encode(), stderr=b'')
            if argv == ['ip', '-j', 'link', 'show']:
                return subprocess.CompletedProcess(
                    argv, 0, stdout=json.dumps([
                        {'ifname': 'eth0', 'flags': ['UP']},
                    ]).encode(), stderr=b'')
            self.fail('Unexpected cold-boot kernel operation: ' + repr(argv))

        with patch.object(manager, 'command', side_effect=kernel), \
                patch.object(manager, 'manager_table_matches_opened_install',
                             return_value=True), \
                patch.object(manager, 'static_boot_matches', return_value=True), \
                patch.object(manager, 'table_classification', return_value='manager'), \
                patch.object(manager.os, 'readlink', return_value='new'), \
                patch.object(manager, 'boot_id', return_value='new'), \
                patch.object(manager.Path, 'exists', return_value=False), \
                patch.object(manager.Path, 'is_symlink', return_value=False):
            def load_profile():
                instance.s['profile'] = '/etc/cor-egress/profile.json'
                instance.s['profile_hash'] = 'opened-profile-hash'
                instance.p = policy
            instance.load = load_profile
            result = instance.boot_guard()
            final_hash = manager.table_hash()
            self.assertIsNotNone(final_hash)
        self.assertEqual(result['outcome'], 'succeeded')
        self.assertEqual(len(writes), 1)
        self.assertEqual(instance.s['tables'], {'root': final_hash})
        self.assertEqual(instance.s['phase'], 'Guarded')
        self.assertEqual(instance.s['namespaces'], {})
        self.assertNotIn('attestation', instance.s)
        self.assertNotIn('veth_index', instance.s)
        self.assertNotIn('reconciled_from_running', instance.s)
        self.assertNotIn('reconciled_root_hash', instance.s)

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

    def test_cold_boot_negative_matrix_never_deletes_unproven_manager_table(self):
        """Only the exact journal/profile/runtime match may authorize deletion."""
        policy = {'endpoint_ipv4': '192.0.2.2', 'endpoint_port': 51820,
                  'resolver_ipv4': '10.77.0.1'}
        runtime = {
            'uplink': 'eth0',
            'root_sources': ['10.20.0.1/32', manager.BUS_ROOT_IP + '/32'],
            'forward_sources': [
                {'interface': 'docker0', 'source_cidr': '172.18.0.0/16'}
            ],
        }
        valid_items = manager_table_fixture('owned', True, runtime, policy)
        valid_hash = manager.digest(manager.encode(manager.clean_nft(valid_items)))
        base_state = {
            'owner': 'owned', 'role': 'manager', 'phase': 'Running',
            'profile': '/etc/cor-egress/profile.json',
            'uplink': 'eth0', 'tables': {'root': valid_hash},
        }
        base_state.update(runtime)
        cases = {
            'journal hash mismatch': (
                {**base_state, 'tables': {'root': 'different'}},
                valid_items, policy, False, valid_hash),
            'missing profile': (
                {**base_state, 'profile': '/missing/profile.json'},
                valid_items, FileNotFoundError(), False, valid_hash),
            'foreign table comment': (base_state, manager_table_fixture(
                'foreign', True, runtime, policy), policy, False, valid_hash),
            'transport namespace missing': (
                base_state, valid_items, policy, False,
                valid_hash),
            'endpoint mismatch': (
                base_state, manager_table_fixture(
                    'owned', True, runtime,
                    {**policy, 'endpoint_ipv4': '192.0.2.99'}), policy, False,
                manager.digest(manager.encode(manager.clean_nft(
                    manager_table_fixture(
                        'owned', True, runtime,
                        {**policy, 'endpoint_ipv4': '192.0.2.99'}))))),
            'root route mismatch': (
                base_state, manager_table_fixture(
                    'owned', True,
                    {**runtime, 'root_sources': ['10.20.0.99/32',
                                                 manager.BUS_ROOT_IP + '/32']},
                    policy), policy, False,
                manager.digest(manager.encode(manager.clean_nft(
                    manager_table_fixture(
                        'owned', True,
                        {**runtime, 'root_sources': ['10.20.0.99/32',
                                                     manager.BUS_ROOT_IP + '/32']},
                        policy))))),
            'not running phase': (
                {**base_state, 'phase': 'Guarded'}, valid_items, policy, False,
                valid_hash),
            'distro config role': (
                {**base_state, 'role': 'distro-config'}, valid_items, policy,
                False, valid_hash),
            'exact surviving manager': (
                base_state, valid_items, policy, True, valid_hash),
        }
        for name, (state, listed_items, loaded_profile, expected,
                   observed_hash) in cases.items():
            with self.subTest(name=name):
                with patch.object(
                        manager, 'table_items', return_value=listed_items['nftables']), \
                        patch.object(
                            manager, 'table_hash',
                            return_value=observed_hash), \
                        patch.object(manager, 'read_profile',
                                     side_effect=loaded_profile
                                     if isinstance(loaded_profile, Exception)
                                     else loaded_profile), \
                        patch.object(manager, 'manager_table_matches',
                                     return_value=True), \
                        patch.object(manager, 'shared_manager_runtime_matches',
                                     return_value=False
                                     if name == 'transport namespace missing'
                                     else True), \
                        patch.object(manager, 'command') as command:
                    observed = manager.manager_table_matches_opened_install(state)
                self.assertEqual(observed, expected, name)
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
        self.assertEqual(instance.s['tables'], {'root': 'static'})
        self.assertEqual(instance.s['namespaces'], {})

    def test_boot_reconcile_clears_absent_guard_hash(self):
        instance = object.__new__(manager.Manager)
        instance.s = {'phase': 'Guarded', 'role': 'manager', 'root_namespace': 'old',
                      'boot_id': 'old', 'namespaces': {}, 'tables': {'root': 'stale'}}
        instance.policy_routes = Mock(return_value=[])
        instance.save = Mock()
        with patch.object(manager.os, 'readlink', return_value='new'), \
                patch.object(manager, 'boot_id', return_value='new'), \
                patch.object(manager.Path, 'exists', return_value=False), \
                patch.object(manager.Path, 'is_symlink', return_value=False), \
                patch.object(manager, 'json_command', side_effect=[[], []]), \
                patch.object(manager, 'table_hash', return_value=None), \
                patch.object(manager, 'table_classification', return_value='absent'), \
                patch.object(manager, 'list_table', return_value=None):
            instance.boot_reconcile()
        self.assertEqual(instance.s['tables'], {})
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

    @unittest.skipUnless(sys.platform == 'linux', 'Requires Linux POSIX permission bits')
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
            # The mount namespace must exist before the launcher can stage the
            # manager outside a private tmpfs. Only the internal exec fragment
            # names the parent-namespace proof argument.
            exec_fragment = argv[argv.index("-c") + 1]
            self.assertIn("--_isolated-parent=", exec_fragment)
            self.assertEqual(argv[-1], '{"net": 1, "mnt": 2, "pid": 3}')
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

    @unittest.skipUnless(manager.platform.machine().lower() in manager.AUDIT_ARCHES,
                         'Requires a supported Linux architecture name')
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
