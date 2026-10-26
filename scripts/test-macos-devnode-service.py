#!/usr/bin/env python3
"""Exercise ownership/recovery; launchd itself requires a separate macOS check."""
import hashlib
import importlib.util
import os
import sys
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

sys.dont_write_bytecode = True

SOURCE = Path(__file__).resolve().parents[1] / 'platforms/macos/devnode-service/service.py'
UUID = '14f29b3f-cda1-4acf-9f18-26d35f8d6074'

class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve()
        self.files = []
        for name in ('sshd_config', 'herdr', 'herdr.toml'):
            p = self.home / name
            p.write_text('fixture-' + name)
            p.chmod(0o600)
            self.files.append({'path': str(p), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()})
        self.config = {'version': 1, 'instanceId': UUID, 'sshdConfig': self.files[0], 'herdrBinary': self.files[1], 'herdrConfig': self.files[2], 'session': 'devnode-test', 'workingDirectory': str(self.home), 'path': '/usr/bin:/bin'}
        if not SOURCE.exists():
            self.fail('owned LaunchAgent lifecycle is not implemented')
        spec = importlib.util.spec_from_file_location('service', SOURCE)
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)
        self.loaded = {}
        self.fail_second = False
        def launch(args):
            if args[0] == 'print':
                label = args[1].split('/')[-1]
                if label not in self.loaded:
                    return 113, '', 'Could not find service'
                return 0, f'\tpath = {self.loaded[label]}\n\tstate = running\n\tpid = 4321\n', ''
            if args[0] == 'bootstrap':
                p = Path(args[2])
                label = plistlib.loads(p.read_bytes())['Label']
                if self.fail_second and '.herdr.' in label:
                    return 5, '', 'fixture bootstrap failure'
                self.loaded[label] = str(p)
                return 0, '', ''
            if args[0] == 'bootout':
                self.loaded.pop(args[1].split('/')[-1])
                return 0, '', ''
            raise AssertionError(args)
        self.manager = self.mod.Manager(self.home, os.getuid(), launch)
        self.manager.preflight = lambda config: None

    def test_apply_starts_dedicated_jobs_and_second_apply_is_noop(self):
        self.assertEqual(self.manager.apply(self.config)['started'], ['ssh', 'herdr'])
        self.assertEqual(len(self.loaded), 2)
        for path in self.loaded.values():
            plist = plistlib.loads(Path(path).read_bytes())
            self.assertTrue(plist['KeepAlive'])
            self.assertEqual(plist['ThrottleInterval'], 60)
            self.assertNotIn('UserName', plist)
            self.assertEqual(plist['ProgramArguments'][:2], [self.mod.sys.executable, '-I'])
            self.assertEqual(plist['Umask'], 0o077)
        self.assertEqual(self.manager.apply(self.config)['started'], [])
        self.assertEqual([x['state'] for x in self.manager.status(self.config)['jobs']], ['running', 'running'])
        self.manager.remove(self.config)
        self.assertFalse(self.loaded)
        self.assertFalse(self.manager.paths(self.config)['manifest'].exists())

    def test_foreign_plist_is_never_overwritten_or_removed(self):
        path = Path(self.manager.plan(self.config)['jobs'][0]['plist'])
        path.parent.mkdir(parents=True)
        path.write_text('foreign')
        for action in (self.manager.apply, self.manager.remove):
            with self.assertRaisesRegex(ValueError, 'foreign'):
                action(self.config)
        self.assertEqual(path.read_text(), 'foreign')
        self.assertFalse(self.loaded)

    def test_loaded_foreign_job_is_not_adopted(self):
        plan = self.manager.plan(self.config)
        self.loaded[plan['jobs'][0]['label']] = '/unrelated/job.plist'
        with self.assertRaisesRegex(ValueError, 'foreign'):
            self.manager.apply(self.config)
        self.assertEqual(len(self.loaded), 1)

    def test_partial_bootstrap_is_recoverable(self):
        self.fail_second = True
        with self.assertRaisesRegex(ValueError, 'bootstrap'):
            self.manager.apply(self.config)
        self.assertEqual(len(self.loaded), 1)
        self.fail_second = False
        self.assertEqual(self.manager.apply(self.config)['started'], ['herdr'])

    def test_owned_resource_drift_fails_before_mutation(self):
        self.manager.apply(self.config)
        manifest = self.manager.paths(self.config)['manifest']
        before = manifest.read_bytes()
        owned = Path(self.manager.plan(self.config)['jobs'][0]['plist'])
        owned.write_bytes(owned.read_bytes() + b'\n')
        with self.assertRaisesRegex(ValueError, 'drift'):
            self.manager.remove(self.config)
        self.assertEqual(len(self.loaded), 2)
        self.assertEqual(manifest.read_bytes(), before)

    def test_changed_pin_and_unknown_fields_are_refused(self):
        Path(self.files[1]['path']).write_text('changed')
        with self.assertRaisesRegex(ValueError, 'hash'):
            self.manager.apply(self.config)
        self.assertFalse(self.loaded)
        self.config['secret'] = 'unsupported'
        with self.assertRaises(ValueError):
            self.manager.plan(self.config)

    def test_symlink_input_and_shared_write_state_are_refused(self):
        path = Path(self.files[0]['path'])
        target = path.with_suffix('.real')
        path.rename(target)
        path.symlink_to(target)
        with self.assertRaises(ValueError):
            self.manager.apply(self.config)
        path.unlink()
        target.rename(path)
        state = self.manager.paths(self.config)['state']
        state.mkdir(parents=True)
        state.chmod(0o777)
        with self.assertRaises(ValueError):
            self.manager.apply(self.config)

    def test_remove_preserves_logs_and_allows_fresh_apply_of_same_instance(self):
        self.manager.apply(self.config)
        log = self.manager.paths(self.config)['state'] / 'ssh.log'
        log.write_text('retained diagnostic')
        self.manager.remove(self.config)
        self.assertEqual(self.manager.apply(self.config)['started'], ['ssh', 'herdr'])
        archives = list(log.parent.parent.glob('retired-*'))
        self.assertEqual(len(archives), 1)
        self.assertEqual((archives[0] / 'ssh.log').read_text(), 'retained diagnostic')

    def test_unknown_file_in_owned_state_is_not_removed(self):
        self.manager.apply(self.config)
        unrelated = self.manager.paths(self.config)['state'] / 'unrelated'
        unrelated.write_text('keep')
        with self.assertRaisesRegex(ValueError, 'foreign'):
            self.manager.remove(self.config)
        self.assertEqual(unrelated.read_text(), 'keep')
        self.assertEqual(len(self.loaded), 2)

    def test_native_preflight_refuses_wildcard_listener_and_permissive_authentication(self):
        settings = 'authenticationmethods publickey\npubkeyauthentication yes\npasswordauthentication no\nkbdinteractiveauthentication no\npermitrootlogin no\nallowtcpforwarding no\nallowstreamlocalforwarding no\nallowagentforwarding no\nx11forwarding no\npermittunnel no\npermittty no\npermituserrc no\nusepam no\nstrictmodes yes\nport 22223\nlistenaddress 100.83.203.34:22223\nallowusers fixture@100.118.123.62\n'
        for bad in [settings.replace('passwordauthentication no', 'passwordauthentication yes'), settings.replace('100.83.203.34:22223', '0.0.0.0:22223')]:
            with patch.object(self.mod.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=bad)):
                with self.assertRaises(ValueError):
                    self.mod.Manager.preflight(self.manager, self.config)
        with patch.object(self.mod.subprocess, 'run', side_effect=[SimpleNamespace(returncode=0, stdout=settings), SimpleNamespace(returncode=0, stdout='')]):
            self.mod.Manager.preflight(self.manager, self.config)

    def test_unknown_launchctl_error_is_not_absence(self):
        self.manager.launch = lambda args: (5, '', 'Input/output error')
        with self.assertRaisesRegex(ValueError, 'launchctl'):
            self.manager.apply(self.config)
        self.assertFalse(self.manager.paths(self.config)['manifest'].exists())

if __name__ == '__main__':
    unittest.main()
