#!/usr/bin/env python3
"""Filesystem integration tests; only the external mise provider is a fixture."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import subprocess
import select
import shutil
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

SCRIPT = Path(__file__).resolve().parents[1] / 'platforms/ubuntu-wsl/worker-runtime.py'

@unittest.skipIf(os.name == 'nt', 'Linux worker POSIX ownership/lock fixtures run on Linux/macOS')
class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), 'worker runtime frontend is missing')
        spec = importlib.util.spec_from_file_location('worker_runtime', SCRIPT)
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        (self.repo/'mise.global.toml').write_text('[tools]\ncodex = "latest"\nherdr = {version="latest", os=["linux", "macos"]}\nnode = "26"\n[env]\nPOISON = "do-not-inherit"\n')
        self.write_lock()
        self.state = self.root/'state'
        self.state.mkdir(mode=0o700)
        self.home = self.root/'home'
        (self.home/'.local/bin').mkdir(parents=True)
        self.codex_root = self.state/'data/installs/codex/0.165.0'
        self.herdr_root = self.state/'data/installs/herdr/0.9.5'
        for rel in ['bin/codex', 'bin/codex-code-mode-host', 'codex-path/rg', 'codex-resources/bwrap']:
            self.exe(self.codex_root/rel, 'codex-cli 0.165.0')
        (self.codex_root/'codex-package.json').write_text(json.dumps({'layoutVersion':1,'version':'0.165.0','target':'x86_64-unknown-linux-musl','variant':'codex','entrypoint':'bin/codex','resourcesDir':'codex-resources','pathDir':'codex-path'}))
        self.exe(self.herdr_root/'herdr', 'herdr 0.9.5')
        self.mise = self.root/'mise'
        self.mise.write_text('#!'+sys.executable+'\n'+f'''import os,sys,tomllib
from pathlib import Path
args=sys.argv[1:]
cfg=tomllib.loads(Path(os.environ['MISE_GLOBAL_CONFIG_FILE']).read_text())
assert set(cfg['tools']) == {{'codex','herdr'}}
assert 'env' not in cfg
assert os.environ['MISE_CEILING_PATHS'] == {str(self.state)!r}
if args == ['install','--locked','codex','herdr']: pass
elif args == ['which','codex']: print({str(self.codex_root/'bin/codex')!r})
elif args == ['which','herdr']: print({str(self.herdr_root/'herdr')!r})
else: sys.exit(91)
''')
        self.mise.chmod(0o700)

    def exe(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/bin/sh\nprintf "%s\\n" '+repr(text)+'\n')
        path.chmod(0o700)

    def write_lock(self, codex='0.165.0', herdr='0.9.5'):
        (self.repo/'mise.global.lock').write_text(f'''lockfile_version = 3
[[tools.codex]]
version = "{codex}"
backend = "aqua:openai/codex"
specifiers = ["latest"]
[tools.codex."platforms.linux-x64"]
checksum = "sha256:{'a'*64}"
url = "https://github.com/openai/codex/releases/download/rust-v{codex}/codex-package-x86_64-unknown-linux-musl.tar.gz"
[[tools.herdr]]
version = "{herdr}"
backend = "aqua:herdrdev/herdr"
specifiers = ["latest"]
[tools.herdr."platforms.linux-x64"]
checksum = "sha256:{'b'*64}"
url = "https://github.com/herdrdev/herdr/releases/download/v{herdr}/herdr-linux-x86_64"
''')

    def runtime(self, **kwargs):
        return self.mod.Runtime(self.repo, self.state, self.mise, {'codex':'0.165.0','herdr':'0.9.5'}, home=self.home, target='linux-x64', **kwargs)

    def test_selected_install_preserves_full_package_and_nonlogin_entrypoint(self):
        result = self.runtime().install()
        self.assertEqual(result['versions'], {'codex':'0.165.0','herdr':'0.9.5'})
        self.assertEqual((self.state/'current/bin/codex').resolve(), self.codex_root/'bin/codex')
        self.assertFalse((self.home/'.local/bin/codex').exists())
        self.assertEqual(self.runtime().verify()['versions'], result['versions'])
        self.runtime().install()
        self.assertEqual((self.state/'current/bin/herdr').resolve(), self.herdr_root/'herdr')

    def test_real_mise_discovers_only_generated_config_and_its_lock(self):
        mise=shutil.which('mise')
        if not mise:
            self.skipTest('mise metadata characterization requires preinstalled mise')
        with (self.repo/'mise.global.lock').open('a') as lock:
            for host,codex_target,herdr_target in [('macos-arm64','aarch64-apple-darwin','macos-aarch64'),('macos-x64','x86_64-apple-darwin','macos-x86_64')]:
                lock.write(f'\n[tools.codex."platforms.{host}"]\nchecksum = "sha256:{"a"*64}"\nurl = "https://github.com/openai/codex/releases/download/rust-v0.165.0/codex-package-{codex_target}.tar.gz"\n')
                lock.write(f'\n[tools.herdr."platforms.{host}"]\nchecksum = "sha256:{"b"*64}"\nurl = "https://github.com/herdrdev/herdr/releases/download/v0.9.5/herdr-{herdr_target}"\n')
        rt=self.runtime()
        name,cfg,lock,_=rt.source()
        generation=self.state/'generations'/name
        generation.mkdir(parents=True)
        (generation/'config.toml').write_bytes(cfg)
        (generation/'mise.lock').write_bytes(lock)
        (generation/'system.toml').write_text('')
        env=rt.environment(generation)
        env['MISE_DATA_DIR']=str(self.root/'real-mise-data')
        result=subprocess.run([mise,'config','ls','--json'],cwd=generation,env=env,capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stderr)
        configs=json.loads(result.stdout)
        self.assertEqual({item['path'] for item in configs},{str(generation/'config.toml'),str(generation/'system.toml')})
        result=subprocess.run([mise,'install','--locked','--dry-run','codex','herdr'],cwd=generation,env=env,capture_output=True,text=True,timeout=45)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('codex@0.165.0',result.stderr+result.stdout)
        self.assertIn('herdr@0.9.5',result.stderr+result.stdout)
        self.assertFalse((self.root/'real-mise-data/installs').exists())

    def test_relative_mise_path_is_rejected(self):
        with self.assertRaisesRegex(ValueError,'absolute mise'):
            self.mod.Runtime(self.repo,self.state,Path('mise'),{'codex':'0.165.0','herdr':'0.9.5'},home=self.home,target='linux-x64')

    def test_missing_helper_refuses_publication(self):
        (self.codex_root/'bin/codex-code-mode-host').unlink()
        with self.assertRaisesRegex(ValueError, 'package'):
            self.runtime().install()
        self.assertFalse((self.state/'current').exists())

    def test_older_lock_is_refused_before_install(self):
        self.write_lock(codex='0.162.1')
        with self.assertRaisesRegex(ValueError, 'downgrade'):
            self.runtime().install()
        self.assertFalse((self.state/'current').exists())

    def test_foreign_current_is_never_replaced(self):
        (self.state/'current').symlink_to(self.root/'foreign')
        with self.assertRaisesRegex(ValueError, 'current'):
            self.runtime().install()
        self.assertEqual(os.readlink(self.state/'current'), str(self.root/'foreign'))

    def test_package_drift_is_reported(self):
        self.runtime().install()
        self.exe(self.codex_root/'bin/codex-code-mode-host', 'changed')
        with self.assertRaisesRegex(ValueError, 'drift'):
            self.runtime().verify()

    def legacy(self):
        path=self.home/'.local/bin/codex'
        self.exe(path, 'codex-cli 0.165.0')
        return path,hashlib.sha256(path.read_bytes()).hexdigest()

    def test_wrong_legacy_hash_never_moves_file(self):
        self.runtime().install()
        old,_=self.legacy()
        before=old.read_bytes()
        with self.assertRaisesRegex(ValueError, 'hash'):
            self.runtime().migrate('codex','0'*64)
        self.assertEqual(old.read_bytes(), before)
        self.assertFalse((self.state/'legacy').exists())

    def test_foreign_symlink_is_never_migrated(self):
        self.runtime().install()
        old=self.home/'.local/bin/codex'
        old.symlink_to(self.root/'foreign')
        with self.assertRaisesRegex(ValueError, 'legacy'):
            self.runtime().migrate('codex','0'*64)
        self.assertEqual(os.readlink(old), str(self.root/'foreign'))

    def test_migration_rejects_a_drifted_entrypoint(self):
        self.runtime().install()
        old,expected=self.legacy()
        entry=self.state/'current/bin/codex'
        entry.unlink()
        entry.symlink_to(self.root/'foreign')
        with self.assertRaisesRegex(ValueError,'entrypoint drift'):
            self.runtime().migrate('codex',expected)
        self.assertFalse(old.is_symlink())

    def test_concurrent_process_is_rejected_and_crash_releases_lock(self):
        code = """import sys,importlib.util,time
from pathlib import Path
sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location('worker_runtime',sys.argv[1])
mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
r=mod.Runtime(*map(Path,sys.argv[2:5]),{'codex':'0.165.0','herdr':'0.9.5'},home=Path(sys.argv[5]),target='linux-x64')
with r.locked():
 print('READY',flush=True)
 time.sleep(30)
"""
        child=subprocess.Popen([sys.executable,'-c',code,str(SCRIPT),str(self.repo),str(self.state),str(self.mise),str(self.home)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            ready,_,_=select.select([child.stdout],[],[],5)
            self.assertTrue(ready,'lock holder did not become ready')
            self.assertEqual(child.stdout.readline().strip(),'READY')
            with self.assertRaisesRegex(ValueError,'busy'):
                self.runtime().install()
        finally:
            child.terminate()
            child.wait(timeout=5)
            child.stdout.close();child.stderr.close()
        self.runtime().install()
        self.assertEqual(self.runtime().verify()['versions']['codex'],'0.165.0')

    def test_migration_cannot_downgrade_a_newer_legacy_binary(self):
        self.runtime().install()
        old=self.home/'.local/bin/codex'
        self.exe(old,'codex-cli 0.166.0')
        expected=hashlib.sha256(old.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError,'downgrade'):
            self.runtime().migrate('codex',expected)
        self.assertFalse(old.is_symlink())

    def test_current_version_floor_survives_a_lower_requested_minimum(self):
        self.runtime().install()
        self.write_lock(codex='0.162.1')
        rt=self.mod.Runtime(self.repo,self.state,self.mise,{'codex':'0.0.0','herdr':'0.0.0'},home=self.home,target='linux-x64')
        with self.assertRaisesRegex(ValueError,'downgrade'):
            rt.install()
        self.assertEqual((self.state/'current/bin/codex').resolve(),self.codex_root/'bin/codex')

    def test_migration_resumes_when_backup_move_failed(self):
        self.runtime().install()
        old,digest=self.legacy()
        with patch.object(self.mod.os,'rename',side_effect=OSError('interrupted before move')):
            with self.assertRaisesRegex(OSError,'interrupted before move'):
                self.runtime().migrate('codex',digest)
        self.assertTrue(old.is_file())
        self.runtime().migrate('codex',digest)
        self.assertEqual(old.resolve(),self.codex_root/'bin/codex')

    def test_migration_preserves_backup_and_can_resume_after_interruption(self):
        self.runtime().install()
        old,digest=self.legacy()
        before=old.read_bytes()
        with patch.object(self.mod.os,'symlink',side_effect=OSError('interrupted')):
            with self.assertRaisesRegex(OSError,'interrupted'):
                self.runtime().migrate('codex',digest)
        self.assertFalse(old.exists())
        self.assertEqual((self.state/'legacy'/('codex.'+digest)).read_bytes(),before)
        result=self.runtime().migrate('codex',digest)
        self.assertEqual(old.resolve(),self.codex_root/'bin/codex')
        self.assertEqual(Path(result['backup']).read_bytes(),before)
        self.runtime().migrate('codex',digest)

if __name__ == '__main__': unittest.main()
