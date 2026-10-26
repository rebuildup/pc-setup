#!/usr/bin/env python3
"""Own two user LaunchAgents. No enrollment, key generation or global services."""
import argparse
import contextlib
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import stat
import subprocess
import sys
import uuid

KEYS = {'version', 'instanceId', 'sshdConfig', 'herdrBinary', 'herdrConfig', 'session', 'workingDirectory', 'path'}

def digest(data):
    return hashlib.sha256(data).hexdigest()

def regular(path, private=True):
    path = Path(path)
    info = path.lstat()
    if not path.is_absolute() or path != path.resolve() or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError('expected plain absolute regular file')
    if info.st_uid not in ({os.getuid()} if private else {0, os.getuid()}) or info.st_mode & (0o077 if private else 0o022):
        raise ValueError('unsafe file owner or permissions')
    return path

def directory(path):
    path = Path(path)
    if not path.is_absolute() or path != path.resolve():
        raise ValueError('expected plain absolute directory')
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError('unsafe directory owner or permissions')
    return path

def load_config(path):
    path = regular(path)
    if path.stat().st_size > 16384:
        raise ValueError('configuration too large')
    return json.loads(path.read_text())

def validate(config):
    if not isinstance(config, dict) or set(config) != KEYS or config['version'] != 1:
        raise ValueError('unrecognized configuration')
    if not isinstance(config['instanceId'], str) or str(uuid.UUID(config['instanceId'])) != config['instanceId']:
        raise ValueError('invalid instance ID')
    if not isinstance(config['session'], str) or not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]{0,95}', config['session']):
        raise ValueError('invalid named Herdr session')
    for key in ('sshdConfig', 'herdrBinary', 'herdrConfig'):
        item = config[key]
        if not isinstance(item, dict) or set(item) != {'path', 'sha256'} or not isinstance(item['path'], str) or not Path(item['path']).is_absolute() or not re.fullmatch(r'[a-f0-9]{64}', item['sha256']):
            raise ValueError('invalid pinned input')
    if not isinstance(config['workingDirectory'], str) or not Path(config['workingDirectory']).is_absolute():
        raise ValueError('invalid working directory')
    if not isinstance(config['path'], str) or not config['path'] or any(not part.startswith('/') or '\n' in part or '\0' in part for part in config['path'].split(':')):
        raise ValueError('PATH must contain absolute directories')
    return config

def verify_inputs(config):
    validate(config)
    for key in ('sshdConfig', 'herdrBinary', 'herdrConfig'):
        path = regular(config[key]['path'], private=key != 'herdrBinary')
        if digest(path.read_bytes()) != config[key]['sha256']:
            raise ValueError('pinned input hash changed')
    directory(config['workingDirectory'])

def write_new(path, data):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'wb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())

def launch(args):
    result = subprocess.run(['/bin/launchctl', *args], capture_output=True, text=True, timeout=20, env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'}, check=False)
    return result.returncode, result.stdout, result.stderr

class Manager:
    def __init__(self, home, uid, launch_command=launch):
        self.home, self.uid, self.launch = directory(home), uid, launch_command
        if uid != os.getuid() or uid == 0:
            raise ValueError('run as the owning standard user')

    def paths(self, config):
        validate(config)
        state = self.home / '.local/state/pc-setup/devnode-service' / config['instanceId']
        return {'state': state, 'manifest': state / 'manifest.json', 'worker': state / 'worker.py', 'config': state / 'config.json', 'agents': self.home / 'Library/LaunchAgents'}

    def plan(self, config):
        p = self.paths(config)
        jobs = []
        for role in ('ssh', 'herdr'):
            label = f'dev.rebuildup.pc-setup.devnode.{role}.{config["instanceId"]}'
            jobs.append({'role': role, 'label': label, 'plist': str(p['agents'] / (label + '.plist'))})
        return {'instanceId': config['instanceId'], 'domain': f'gui/{self.uid}', 'jobs': jobs}

    def environment(self, config):
        user = pwd.getpwuid(self.uid).pw_name
        return {'HOME': str(self.home), 'USER': user, 'LOGNAME': user, 'SHELL': '/bin/sh', 'PATH': config['path'], 'HERDR_CONFIG_PATH': config['herdrConfig']['path']}

    def definition(self, config):
        p = self.paths(config)
        files = {str(p['worker']): Path(__file__).read_bytes(), str(p['config']): (json.dumps(config, sort_keys=True) + '\n').encode()}
        for job in self.plan(config)['jobs']:
            definition = {'Label': job['label'], 'ProgramArguments': [sys.executable, '-I', str(p['worker']), '--run', job['role'], '--config', str(p['config'])], 'WorkingDirectory': config['workingDirectory'], 'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 60, 'Umask': 0o077, 'StandardOutPath': str(p['state'] / (job['role'] + '.log')), 'StandardErrorPath': str(p['state'] / (job['role'] + '.log'))}
            files[job['plist']] = plistlib.dumps(definition, sort_keys=True)
        return files

    def job_status(self, job):
        code, out, error = self.launch(['print', f'gui/{self.uid}/{job["label"]}'])
        if code == 113 and 'Could not find service' in error:
            return {'role': job['role'], 'loaded': False, 'state': 'absent'}
        if code:
            raise ValueError('launchctl query failed; absence not confirmed')
        # launchctl print is diagnostic, not a stable API. Unknown output fails closed.
        paths = re.findall(r'^\s*path = (.+)$', out, re.MULTILINE)
        states = re.findall(r'^\s*state = (.+)$', out, re.MULTILINE)
        if paths != [job['plist']] or len(states) != 1:
            raise ValueError('foreign job or unknown launchctl provenance')
        pids = re.findall(r'^\s*pid = ([0-9]+)$', out, re.MULTILINE)
        return {'role': job['role'], 'loaded': True, 'state': states[0], 'pid': int(pids[0]) if len(pids) == 1 else None}

    def inspect(self, config):
        p, plan = self.paths(config), self.plan(config)
        for path in (p['state'], p['agents']):
            if path.exists() or path.is_symlink():
                directory(path)
        statuses = [self.job_status(job) for job in plan['jobs']]
        if not p['manifest'].exists() and not p['manifest'].is_symlink():
            if any(item['loaded'] for item in statuses) or any(Path(job['plist']).exists() or Path(job['plist']).is_symlink() for job in plan['jobs']) or (p['state'].exists() and any(p['state'].iterdir())):
                raise ValueError('foreign resources cannot be adopted')
            return None, statuses
        manifest = load_config(p['manifest'])
        allowed = {str(p['worker']), str(p['config']), *(job['plist'] for job in plan['jobs'])}
        if set(manifest) != {'version', 'config', 'files'} or manifest['version'] != 1 or manifest['config'] != config or set(manifest['files']) != allowed:
            raise ValueError('owned manifest drift')
        allowed_state = {'manifest.json', 'worker.py', 'config.json', 'ssh.log', 'herdr.log'}
        if any(item.name not in allowed_state for item in p['state'].iterdir()):
            raise ValueError('foreign file in owned state')
        for path, expected in manifest['files'].items():
            item = Path(path)
            if item.exists() or item.is_symlink():
                if digest(regular(item).read_bytes()) != expected:
                    raise ValueError('owned resource drift')
        for role in ('ssh', 'herdr'):
            log = p['state'] / (role + '.log')
            if log.exists() or log.is_symlink():
                regular(log)
        return manifest, statuses

    def preflight(self, config):
        verify_inputs(config)
        result = subprocess.run(['/usr/sbin/sshd', '-T', '-f', config['sshdConfig']['path']], capture_output=True, text=True, timeout=15, env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'}, check=False)
        if result.returncode:
            raise ValueError('sshd preflight failed')
        settings = dict(line.split(' ', 1) for line in result.stdout.splitlines() if ' ' in line)
        required = {'authenticationmethods': 'publickey', 'pubkeyauthentication': 'yes', 'passwordauthentication': 'no', 'kbdinteractiveauthentication': 'no', 'permitrootlogin': 'no', 'allowtcpforwarding': 'no', 'allowstreamlocalforwarding': 'no', 'allowagentforwarding': 'no', 'x11forwarding': 'no', 'permittunnel': 'no', 'permittty': 'no', 'permituserrc': 'no', 'usepam': 'no', 'strictmodes': 'yes'}
        if any(settings.get(key) != value for key, value in required.items()):
            raise ValueError('sshd must use dedicated public-key-only restricted configuration')
        listeners = [line.split(' ', 1)[1] for line in result.stdout.splitlines() if line.startswith('listenaddress ')]
        if not listeners or settings.get('port') == '22':
            raise ValueError('dedicated listener and nonstandard port required')
        for listener in listeners:
            address = listener.rsplit(':', 1)[0].strip('[]')
            ip = ipaddress.ip_address(address)
            if ip.is_unspecified or ip.is_multicast or ip.is_loopback:
                raise ValueError('wildcard or non-VPN listener refused')
        users = settings.get('allowusers', '').split()
        if not users or any('@' not in user or '*' in user or '?' in user for user in users):
            raise ValueError('AllowUsers must restrict a user and source')
        # Do not adopt a foreground Herdr process that is outside launchd ownership.
        result = subprocess.run(['/bin/ps', '-axo', 'pid=,uid=,command='], capture_output=True, text=True, timeout=10, check=True)
        binary, session = config['herdrBinary']['path'], config['session']
        _, statuses = self.inspect(config)
        owned_pids = {item.get('pid') for item in statuses if item['role'] == 'herdr' and item['loaded']}
        for line in result.stdout.splitlines():
            fields = line.strip().split(None, 2)
            if len(fields) == 3 and fields[1] == str(self.uid) and binary in fields[2] and f'--session {session} server' in fields[2] and int(fields[0]) not in owned_pids:
                raise ValueError('named Herdr server is already running outside owned job')

    @contextlib.contextmanager
    def locked(self, config):
        parent = self.paths(config)['state'].parent
        self.make_directories(parent)
        lock = parent / (config['instanceId'] + '.lock')
        lock.mkdir(mode=0o700)
        try:
            yield
        finally:
            lock.rmdir()

    def make_directories(self, path):
        if path == self.home:
            directory(path)
            return
        if self.home not in path.parents:
            raise ValueError('managed directory must stay below the owning HOME')
        self.make_directories(path.parent)
        if path.exists() or path.is_symlink():
            directory(path)
            return
        path.mkdir(mode=0o700)

    def apply(self, config):
        verify_inputs(config)
        with self.locked(config):
            manifest, statuses = self.inspect(config)
            files, p = self.definition(config), self.paths(config)
            expected = {name: digest(data) for name, data in files.items()}
            if manifest and manifest['files'] != expected:
                raise ValueError('owned definition drift; remove with original definition before replacing')
            self.preflight(config)
            self.make_directories(p['state'])
            self.make_directories(p['agents'])
            if not manifest:
                write_new(p['manifest'], (json.dumps({'version': 1, 'config': config, 'files': expected}, sort_keys=True) + '\n').encode())
            for name, data in files.items():
                if not Path(name).exists():
                    write_new(name, data)
            for role in ('ssh', 'herdr'):
                log = p['state'] / (role + '.log')
                if not log.exists():
                    write_new(log, b'')
            started = []
            for job, status in zip(self.plan(config)['jobs'], statuses):
                if not status['loaded']:
                    if self.launch(['bootstrap', f'gui/{self.uid}', job['plist']])[0]:
                        raise ValueError('bootstrap failed; owned partial state retained for retry/status/remove')
                    started.append(job['role'])
            return {'started': started, **self.status(config)}

    def status(self, config):
        manifest, statuses = self.inspect(config)
        return {'instanceId': config['instanceId'], 'owned': manifest is not None, 'jobs': statuses}

    def remove(self, config):
        with self.locked(config):
            manifest, statuses = self.inspect(config)
            if not manifest:
                return {'removed': False}
            for job, status in zip(self.plan(config)['jobs'], statuses):
                if status['loaded'] and self.launch(['bootout', f'gui/{self.uid}/{job["label"]}'])[0]:
                    raise ValueError('bootout failed; remaining owned state retained')
            for job in self.plan(config)['jobs']:
                if self.job_status(job)['loaded']:
                    raise ValueError('job remains loaded; files retained')
            for name in manifest['files']:
                Path(name).unlink(missing_ok=True)
            p = self.paths(config)
            p['manifest'].unlink()
            archive = p['state'].parent / ('retired-' + config['instanceId'] + '-' + str(uuid.uuid4()))
            p['state'].rename(archive)
            return {'removed': True, 'logsRetained': str(archive)}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', nargs='?', choices=['plan', 'apply', 'status', 'remove'])
    parser.add_argument('--config', required=True)
    parser.add_argument('--run', choices=['ssh', 'herdr'], help=argparse.SUPPRESS)
    args = parser.parse_args()
    if sys.platform != 'darwin' or os.getuid() == 0:
        raise ValueError('macOS standard-user command; do not use sudo')
    config = validate(load_config(args.config))
    manager = Manager(Path(pwd.getpwuid(os.getuid()).pw_dir).resolve(), os.getuid())
    if args.run:
        manifest, _ = manager.inspect(config)
        if not manifest:
            raise ValueError('runtime ownership manifest missing')
        verify_inputs(config)
        os.chdir(config['workingDirectory'])
        command = ['/usr/sbin/sshd', '-D', '-e', '-f', config['sshdConfig']['path']] if args.run == 'ssh' else [config['herdrBinary']['path'], '--session', config['session'], 'server']
        os.execve(command[0], command, manager.environment(config))
    if not args.action:
        parser.error('action is required')
    print(json.dumps(getattr(manager, args.action)(config), ensure_ascii=False))

if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
