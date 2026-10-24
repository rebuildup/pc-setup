"""Exercise the filesystem ownership boundary without Docker or root."""
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name('prepare.sh')


class MaterializeTests(unittest.TestCase):
    def run_prepare(self, path):
        return subprocess.run(['bash', str(SCRIPT), str(path)], capture_output=True)

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
