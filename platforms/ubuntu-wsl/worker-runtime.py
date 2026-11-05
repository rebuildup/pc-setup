#!/usr/bin/env python3
"""Limited user-level runtime provisioning through the existing mise backend."""
import argparse
try:
    import fcntl
except ImportError:  # The CLI reports the Linux-only target before using locks.
    fcntl = None
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import stat
import subprocess
import sys
import tomllib
import uuid

OWNER = 'pc-setup/worker-runtime/v1'
TOOLS = ('codex', 'herdr')
BACKENDS = {'codex': 'aqua:openai/codex', 'herdr': 'aqua:herdrdev/herdr'}


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d+\.\d+\.\d+', value):
        raise ValueError('a stable three-component version is required')
    return tuple(map(int, value.split('.')))


def digest(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def regular(path, executable=False):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid not in (0, os.getuid()) or info.st_mode & 0o7022:
        raise ValueError(f'unsafe regular file: {path}')
    if executable and not os.access(path, os.X_OK):
        raise ValueError(f'package executable is missing: {path}')


def directory(path, create=False, private=False):
    if not path.is_absolute():
        raise ValueError('absolute paths are required')
    # A caller must choose a canonical path, not traverse a replaceable symlink.
    for item in reversed((path, *path.parents)):
        if item.exists() or item.is_symlink():
            info = item.lstat()
            if not stat.S_ISDIR(info.st_mode):
                raise ValueError(f'directory path contains a symlink or file: {item}')
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.stat()
    if info.st_uid != os.getuid() or info.st_mode & (0o077 if private else 0o022):
        raise ValueError(f'unsafe directory ownership or permissions: {path}')


def new_file(path, data):
    if path.exists() or path.is_symlink():
        regular(path)
        if path.read_bytes() != data:
            raise ValueError(f'owned generation drift: {path}')
        return
    with path.open('xb') as file:
        os.chmod(path, 0o600)
        file.write(data)


def write_json(path, value):
    new_file(path, (json.dumps(value, sort_keys=True) + '\n').encode())


class Runtime:
    def __init__(self, repo, state, mise, minimum, *, home=None, target=None):
        self.repo, self.state, self.mise = map(Path, (repo, state, mise))
        if not self.mise.is_absolute():
            raise ValueError('an absolute mise executable is required')
        self.home = Path(home) if home else Path.home()
        self.minimum = minimum
        for tool in TOOLS:
            version(minimum[tool])
        if target is None:
            if sys.platform != 'linux':
                raise ValueError('this frontend provisions Linux workers only')
            target = {'x86_64': 'linux-x64', 'aarch64': 'linux-arm64'}.get(platform.machine())
        if target not in ('linux-x64', 'linux-arm64'):
            raise ValueError('unsupported Linux worker architecture')
        self.target = target
        self.triple = {'linux-x64': 'x86_64-unknown-linux-musl', 'linux-arm64': 'aarch64-unknown-linux-musl'}[target]

    def source(self):
        paths = [self.repo/'mise.global.toml', self.repo/'mise.global.lock']
        for path in paths:
            regular(path)
        config, lock = [tomllib.loads(p.read_text()) for p in paths]
        selected, versions = {}, {}
        for tool in TOOLS:
            spec = config.get('tools', {}).get(tool)
            request = spec if isinstance(spec, str) else spec.get('version') if isinstance(spec, dict) else None
            if not isinstance(request, str) or isinstance(spec, dict) and set(spec) - {'version', 'os'}:
                raise ValueError(f'unsupported canonical tool declaration: {tool}')
            if isinstance(spec, dict) and 'linux' not in spec.get('os', ['linux']):
                raise ValueError(f'canonical tool excludes Linux: {tool}')
            records = lock.get('tools', {}).get(tool, [])
            if len(records) != 1 or records[0].get('backend') != BACKENDS[tool] or request not in records[0].get('specifiers', []):
                raise ValueError(f'canonical lock/request/backend mismatch: {tool}')
            record = records[0]
            versions[tool] = record['version']
            if version(record['version']) < version(self.minimum[tool]):
                raise ValueError(f'lock would downgrade {tool}; update the canonical lock with mise')
            download = record.get(f'platforms.{self.target}', {})
            if not re.fullmatch(r'sha256:[a-f0-9]{64}', download.get('checksum', '')):
                raise ValueError(f'canonical lock has no platform checksum: {tool}')
            prefix = f'https://github.com/{"openai/codex" if tool == "codex" else "herdrdev/herdr"}/releases/download/'
            if not download.get('url', '').startswith(prefix):
                raise ValueError(f'canonical lock has an unexpected source: {tool}')
            if tool == 'codex' and f'/codex-package-{self.triple}.tar.gz' not in download['url']:
                raise ValueError('Codex requires the official full package')
            selected[tool] = request
        content = '[tools]\n' + ''.join(f'{tool} = {json.dumps(selected[tool])}\n' for tool in TOOLS)
        config_bytes, lock_bytes = content.encode(), paths[1].read_bytes()
        generation = hashlib.sha256(config_bytes + b'\0' + lock_bytes).hexdigest()
        return generation, config_bytes, lock_bytes, versions

    @contextmanager
    def locked(self):
        directory(self.state, create=True, private=True)
        lock = self.state/'.lock'
        fd = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1:
                raise ValueError('unsafe runtime lock file')
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ValueError('worker runtime is busy') from error
            yield
        finally:
            os.close(fd)

    def current(self):
        pointer = self.state/'current'
        if not pointer.exists() and not pointer.is_symlink():
            return None
        if not pointer.is_symlink():
            raise ValueError('unknown current runtime entry')
        target = Path(os.readlink(pointer))
        if not target.is_absolute() or target.parent != self.state/'generations' or not re.fullmatch('[a-f0-9]{64}', target.name):
            raise ValueError('foreign current runtime entry')
        directory(target)
        path = target/'manifest.json'
        regular(path)
        record = json.loads(path.read_text())
        if record.get('owner') != OWNER or record.get('uid') != os.getuid() or record.get('generation') != target.name:
            raise ValueError('unknown current runtime manifest')
        for name in ('config.toml', 'mise.lock', 'system.toml'):
            regular(target/name)
        if (target/'system.toml').read_bytes() != b'':
            raise ValueError('current system config drift')
        actual = hashlib.sha256((target/'config.toml').read_bytes()+b'\0'+(target/'mise.lock').read_bytes()).hexdigest()
        if actual != target.name:
            raise ValueError('current source generation drift')
        return record

    def environment(self, generation):
        env = {key: os.environ[key] for key in ('USER', 'LANG', 'TERM', 'HTTPS_PROXY', 'HTTP_PROXY', 'NO_PROXY', 'MISE_GITHUB_TOKEN') if key in os.environ}
        env.update(HOME=str(self.home), PATH='/usr/local/bin:/usr/bin:/bin',
                   MISE_GLOBAL_CONFIG_FILE=str(generation/'config.toml'), MISE_SYSTEM_CONFIG_FILE=str(generation/'system.toml'),
                   MISE_CONFIG_DIR=str(generation), MISE_DATA_DIR=str(self.state/'data'),
                   MISE_CACHE_DIR=str(self.state/'cache'), MISE_STATE_DIR=str(self.state/'mise-state'),
                   MISE_CEILING_PATHS=str(self.state), MISE_OVERRIDE_TOOL_VERSIONS_FILENAMES='none',
                   MISE_NO_ENV='1', MISE_NO_HOOKS='1', MISE_AUTO_INSTALL='0',
                   MISE_TRUSTED_CONFIG_PATHS=str(generation))
        return env

    def call_mise(self, generation, args):
        regular(self.mise, executable=True)
        result = subprocess.run([str(self.mise), *args], cwd=generation, env=self.environment(generation),
                                capture_output=True, text=True, timeout=600)
        if result.returncode:
            # Provider diagnostics can contain injected credentials; never echo them.
            raise ValueError(f'mise {args[0]} failed (exit {result.returncode}); inspect it locally without exposing credentials')
        return result.stdout.strip()

    def normalize_new_package_permissions(self, executables):
        # mise has just completed the locked install. Its vendor archives may
        # carry group-write bits; restrict only files in this private inventory.
        codex = Path(executables['codex'])
        if codex.parent.name != 'bin':
            raise ValueError('Codex package layout is incomplete')
        paths = [Path(executables[t]) for t in TOOLS]
        paths.extend(codex.parent.parent / relative for relative in
                     ('codex-package.json', 'bin/codex-code-mode-host', 'codex-resources/bwrap', 'codex-path/rg'))
        for path in paths:
            if not path.is_absolute() or not path.is_relative_to(self.state/'data/installs') or path.is_symlink():
                raise ValueError('package permission normalization refused an external path or symlink')
            try:
                if path.resolve(strict=True) != path:
                    raise ValueError('package permission normalization refused a symlink ancestor')
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            except OSError as error:
                raise ValueError('package permission normalization could not open its regular file') from error
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                    raise ValueError('package permission normalization requires a worker-owned regular file')
                if info.st_nlink != 1:
                    raise ValueError('package permission normalization refuses hardlinks')
                if info.st_mode & 0o7000:
                    raise ValueError('package has unexpected special permissions')
                if info.st_mode & 0o022:
                    os.fchmod(fd, stat.S_IMODE(info.st_mode) & ~0o022)
            finally:
                os.close(fd)

    def package_files(self, executables, versions):
        files = []
        for tool in TOOLS:
            path = Path(executables[tool])
            if not path.is_absolute() or not path.is_relative_to(self.state/'data/installs'):
                raise ValueError('package executable escaped the dedicated mise inventory')
            regular(path, executable=True)
            files.append(path)
        codex = Path(executables['codex'])
        if codex.parent.name != 'bin':
            raise ValueError('Codex package layout is incomplete')
        root = codex.parent.parent
        metadata = root/'codex-package.json'
        regular(metadata)
        data = json.loads(metadata.read_text())
        expected = {'layoutVersion': 1, 'version': versions['codex'], 'target': self.triple, 'variant': 'codex',
                    'entrypoint': 'bin/codex', 'resourcesDir': 'codex-resources', 'pathDir': 'codex-path'}
        if any(data.get(k) != v for k, v in expected.items()):
            raise ValueError('Codex package metadata differs from the canonical lock')
        files.append(metadata)
        for relative in ('bin/codex-code-mode-host', 'codex-resources/bwrap', 'codex-path/rg'):
            path = root/relative
            try:
                regular(path, executable=True)
            except (OSError, ValueError) as error:
                raise ValueError(f'Codex package is incomplete: {relative}') from error
            files.append(path)
        return files

    def check_record(self, record):
        if record.get('target') != self.target or set(record.get('versions', {})) != set(TOOLS) or set(record.get('executables', {})) != set(TOOLS):
            raise ValueError('runtime manifest shape or target mismatch')
        files = self.package_files(record['executables'], record['versions'])
        actual = {str(path): digest(path) for path in files}
        if actual != record.get('files'):
            raise ValueError('runtime package hash drift')
        for tool in TOOLS:
            output = subprocess.run([record['executables'][tool], '--version'], capture_output=True, text=True, timeout=15,
                                    env={'HOME': str(self.home), 'PATH': '/usr/local/bin:/usr/bin:/bin'})
            if output.returncode or not re.fullmatch(rf'{"codex-cli" if tool == "codex" else "herdr"} {re.escape(record["versions"][tool])}\s*', output.stdout):
                raise ValueError(f'{tool} executable version differs from its lock')
        return record

    def check_entrypoints(self, record):
        for tool in TOOLS:
            link = self.state/'current/bin'/tool
            if not link.is_symlink() or os.readlink(link) != record['executables'][tool]:
                raise ValueError('runtime entrypoint drift')

    def install(self):
        with self.locked():
            name, config, lock, versions = self.source()
            previous = self.current()
            if previous:
                self.check_record(previous)
                self.check_entrypoints(previous)
                if any(version(versions[t]) < version(previous['versions'][t]) for t in TOOLS):
                    raise ValueError('source update would downgrade the existing runtime')
            generation = self.state/'generations'/name
            directory(generation, create=True)
            new_file(generation/'config.toml', config)
            new_file(generation/'mise.lock', lock)
            new_file(generation/'system.toml', b'')
            self.call_mise(generation, ['install', '--locked', *TOOLS])
            executables = {tool: str(Path(self.call_mise(generation, ['which', tool])).resolve(strict=True)) for tool in TOOLS}
            self.normalize_new_package_permissions(executables)
            files = self.package_files(executables, versions)
            record = {'owner': OWNER, 'uid': os.getuid(), 'generation': name, 'target': self.target,
                      'versions': versions, 'executables': executables, 'files': {str(p): digest(p) for p in files}}
            self.check_record(record)
            # Locked installation may not rewrite the derived source or lock.
            new_file(generation/'config.toml', config)
            new_file(generation/'mise.lock', lock)
            write_json(generation/'manifest.json', record)
            directory(generation/'bin', create=True)
            for tool in TOOLS:
                link = generation/'bin'/tool
                if link.is_symlink() and os.readlink(link) == executables[tool]:
                    continue
                if link.exists() or link.is_symlink():
                    raise ValueError('foreign generation entrypoint')
                link.symlink_to(executables[tool])
            temporary = self.state/('.current-'+str(uuid.uuid4()))
            temporary.symlink_to(generation)
            os.replace(temporary, self.state/'current')
            return {'versions': versions, 'entrypoints': {t: str(self.state/'current/bin'/t) for t in TOOLS}}

    def verify(self):
        with self.locked():
            record = self.current()
            if not record:
                raise ValueError('no worker runtime has been installed')
            self.check_record(record)
            self.check_entrypoints(record)
            return {'versions': record['versions'], 'entrypoints': {t: str(self.state/'current/bin'/t) for t in TOOLS}}

    def migrate(self, tool, expected_hash):
        if tool not in TOOLS or not re.fullmatch('[a-f0-9]{64}', expected_hash):
            raise ValueError('a selected tool and explicit legacy SHA256 are required')
        with self.locked():
            record = self.current()
            if not record:
                raise ValueError('install and verify the worker runtime first')
            self.check_record(record)
            self.check_entrypoints(record)
            destination = self.home/'.local/bin'/tool
            directory(destination.parent)
            target = self.state/'current/bin'/tool
            journal = self.state/'migrations'/f'{tool}.json'
            backup = self.state/'legacy'/f'{tool}.{expected_hash}'
            intent = {'owner': OWNER, 'tool': tool, 'expectedHash': expected_hash, 'destination': str(destination), 'backup': str(backup), 'target': str(target)}
            if journal.exists() or journal.is_symlink():
                regular(journal)
                if json.loads(journal.read_text()) != intent:
                    raise ValueError('legacy migration intent differs')
                if not backup.exists() and not backup.is_symlink():
                    regular(destination, executable=True)
                    if digest(destination) != expected_hash:
                        raise ValueError('legacy hash drift before backup move')
                    os.rename(destination, backup)
                regular(backup)
                if digest(backup) != expected_hash:
                    raise ValueError('legacy backup hash drift')
            else:
                if destination.is_symlink():
                    raise ValueError('foreign legacy symlink; refusing migration')
                regular(destination, executable=True)
                if digest(destination) != expected_hash:
                    raise ValueError('legacy hash mismatch; no file was moved')
                old = subprocess.run([str(destination), '--version'], capture_output=True, text=True, timeout=15)
                match = re.fullmatch(rf'{"codex-cli" if tool == "codex" else "herdr"} (\d+\.\d+\.\d+)\s*', old.stdout)
                if old.returncode or not match or version(record['versions'][tool]) < version(match[1]):
                    raise ValueError('migration would downgrade or adopt an unknown legacy version')
                directory(journal.parent, create=True)
                directory(backup.parent, create=True)
                if backup.exists() or backup.is_symlink():
                    raise ValueError('foreign legacy backup')
                write_json(journal, intent)
                os.rename(destination, backup)
            if destination.is_symlink() and os.readlink(destination) == str(target):
                return intent
            if destination.exists() or destination.is_symlink():
                raise ValueError('legacy destination changed during migration')
            os.symlink(target, destination)
            return intent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('install', 'verify', 'migrate'))
    parser.add_argument('--mise', type=Path, required=True, help='absolute preinstalled mise executable')
    parser.add_argument('--state', type=Path, required=True, help='dedicated private user-owned canonical directory')
    parser.add_argument('--minimum-codex', required=True, help='observed current version/capability floor, not a new pin')
    parser.add_argument('--minimum-herdr', required=True)
    parser.add_argument('--tool', choices=TOOLS)
    parser.add_argument('--expected-sha256')
    args = parser.parse_args()
    runtime = Runtime(Path(__file__).resolve().parents[2], args.state, args.mise,
                      {'codex': args.minimum_codex, 'herdr': args.minimum_herdr})
    if args.action == 'migrate':
        result = runtime.migrate(args.tool, args.expected_sha256 or '')
    else:
        result = getattr(runtime, args.action)()
    print(json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
