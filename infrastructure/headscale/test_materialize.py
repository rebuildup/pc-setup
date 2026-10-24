"""Exercise the filesystem ownership boundary without Docker or root."""
import pathlib
import os
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name('prepare.sh')


class MaterializeTests(unittest.TestCase):
    def run_prepare(self, path):
        return subprocess.run(['bash', str(SCRIPT), str(path)], capture_output=True)

    def test_verify_executes_headscale_binary(self):
        # Compose exec bypasses the image ENTRYPOINT: service then executable.
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp).resolve()
            tools = root / 'bin'
            tools.mkdir()
            docker = tools / 'docker'
            docker.write_text("""#!/usr/bin/env bash
set -eu
if [[ "$1" = compose ]]; then
  while (( $# )); do
    if [[ "$1" = exec ]]; then
      shift
      [[ "$1" = -T && "$2" = headscale && "$3" = headscale ]] || exit 127
      printf '%s\\n' "$4" >> "$CLI_TEST_CALLS"
      exit 0
    fi
    shift
  done
  exit 0
fi
[[ "$1" = info ]] && exit 0
exit 1
""")
            docker.chmod(0o755)
            curl = tools / 'curl'
            curl.write_text('#!/bin/sh\nexit 0\n')
            curl.chmod(0o755)
            calls = root / 'calls'
            env = dict(os.environ, PATH=f'{tools}:{os.environ["PATH"]}',
                       CLI_TEST_CALLS=str(calls))
            result = subprocess.run(
                ['bash', str(SCRIPT.with_name('manage.sh')), 'verify',
                 str(root / 'service')], capture_output=True, env=env)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(calls.read_text().splitlines(), ['health', 'policy'])

    def test_fresh_and_repeat(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp).resolve() / 'service'
            self.assertEqual(self.run_prepare(target).returncode, 0)
            first = {p.name: p.read_bytes() for p in target.iterdir()}
            self.assertEqual(self.run_prepare(target).returncode, 0)
            self.assertEqual(first, {p.name: p.read_bytes() for p in target.iterdir()})

    def test_foreign_directory_and_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp).resolve() / 'service'
            target.mkdir()
            self.assertNotEqual(self.run_prepare(target).returncode, 0)
            link = pathlib.Path(tmp).resolve() / 'link'
            link.symlink_to(target, target_is_directory=True)
            self.assertNotEqual(self.run_prepare(link).returncode, 0)
            self.assertEqual(list(target.iterdir()), [])

    def test_modified_file_is_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp).resolve() / 'service'
            self.assertEqual(self.run_prepare(target).returncode, 0)
            config = target / 'config.yaml'
            config.write_text('foreign')
            self.assertNotEqual(self.run_prepare(target).returncode, 0)
            self.assertEqual(config.read_text(), 'foreign')

    def test_managed_file_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp).resolve() / 'service'
            self.assertEqual(self.run_prepare(target).returncode, 0)
            policy = target / 'policy.json'
            policy.unlink()
            policy.symlink_to(SCRIPT.with_name('policy.json'))
            self.assertNotEqual(self.run_prepare(target).returncode, 0)


if __name__ == '__main__':
    unittest.main()
