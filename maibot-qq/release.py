"""Versioned Docker updates, code audit, private backups and recoverable migration."""

from contextlib import contextmanager
from datetime import datetime, timezone
import argparse
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile


DATA = Path('/opt/maibot-qq')
IMAGE = re.compile(r'ghcr\.io/haipengtian/maibot-qq:sha-[a-f0-9]{12}')


def image_env(text, image):
    if not IMAGE.fullmatch(image):
        raise ValueError('Use the sha image tag from a successful GitHub Actions run')
    if len(re.findall(r'^MAIBOT_IMAGE=.*$', text, re.M)) != 1:
        raise ValueError('Expected exactly one MAIBOT_IMAGE in .env')
    return re.sub(r'^MAIBOT_IMAGE=.*$', 'MAIBOT_IMAGE=' + image, text, flags=re.M)


def validate_legacy_overlay(value):
    allowed = {'/opt/bundled-plugins/snowluma-adapter/' + name for name in (
        'config.py', 'codecs/inbound/message_codec.py', 'assets/qq_faces')}
    if set(value) != {'services'} or set(value['services']) != {'maibot'}:
        raise ValueError('Unknown legacy override; review before removing it')
    service = value['services']['maibot']
    if set(service) - {'image', 'volumes'}:
        raise ValueError('Legacy override has settings other than the known image/QQ face mounts')
    for volume in service.get('volumes', []):
        if not isinstance(volume, dict) or volume.get('target') not in allowed or not volume.get('read_only'):
            raise ValueError('Unknown legacy mount; review before removing it')


def code_differences(old, new):
    def inventory(root):
        return {str(p.relative_to(root)).replace('\\', '/'): p.read_text(encoding='utf-8')
                for p in root.rglob('*.py') if '__pycache__' not in p.parts}
    before, after = inventory(old), inventory(new)
    return sorted(name for name in before.keys() | after.keys() if before.get(name) != after.get(name))


def run(args, capture=False):
    return subprocess.run([str(a) for a in args], check=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def compose(ops, *args, legacy=True):
    cmd = ['docker', 'compose', '--project-directory', ops, '--env-file', ops / '.env', '-f', ops / 'compose.yaml']
    overlay = ops / 'compose.qq-face.yaml'
    if legacy and overlay.is_file():
        cmd += ['-f', overlay]
    return run(cmd + list(args), capture=args[:1] in (('ps',), ('config',)))


def stamp():
    return datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ').lower()


@contextmanager
def operation(ops):
    import fcntl
    with (ops / '.release.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another release/backup/restore operation is running') from None
        yield


def live_container(ops):
    cid = compose(ops, 'ps', '-q', 'maibot').decode().strip()
    if not cid or '\n' in cid:
        raise ValueError('Expected one running MaiBot container')
    mounts = json.loads(run(['docker', 'inspect', '--format', '{{json .Mounts}}', cid], True))
    if not any(m['Destination'] == '/instance' and Path(m['Source']).resolve() == (DATA / 'runtime').resolve() for m in mounts):
        raise ValueError('Unexpected instance mount; no changes made')
    return cid


def audit_code(cid, image):
    """Compare source contents; refuse to drop unrecorded core/adapter edits."""
    candidate = run(['docker', 'create', image], True).decode().strip()
    try:
        with tempfile.TemporaryDirectory(prefix='maibot-audit-') as tmp:
            root = Path(tmp)
            for label, container in (('live', cid), ('next', candidate)):
                for name, source in (('src', '/opt/maibot/src'), ('adapter', '/opt/bundled-plugins/snowluma-adapter')):
                    dest = root / label / name; dest.parent.mkdir(parents=True, exist_ok=True)
                    run(['docker', 'cp', container + ':' + source, dest])
            differences = code_differences(root / 'live/src', root / 'next/src')
            # The one new core change has a bounded, source-checked transform.
            if 'plugin_runtime/component_query.py' in differences:
                import importlib.util
                spec = importlib.util.spec_from_file_location('qzone_release_patch', Path(__file__).parent / 'qzone-bridge/apply.py')
                patch = importlib.util.module_from_spec(spec); spec.loader.exec_module(patch)
                live = (root / 'live/src/plugin_runtime/component_query.py').read_text(encoding='utf-8')
                expected = (root / 'next/src/plugin_runtime/component_query.py').read_text(encoding='utf-8')
                if patch.patch_host(live) == expected:
                    differences.remove('plugin_runtime/component_query.py')
            differences += ['adapter/' + name for name in code_differences(root / 'live/adapter', root / 'next/adapter')]
            if differences:
                raise ValueError('Unrecorded live source differences; keep current service and incorporate these first: ' + ', '.join(differences))
    finally:
        run(['docker', 'rm', candidate], True)
    print('Core and adapter source audit passed; market plugin directories remain instance data.')


def write_backup(data, ops, archive, record):
    def include(item):
        if any(part in {'backups', 'logs', '__pycache__', '.git', '.pytest_cache'} for part in PurePosixPath(item.name).parts):
            return None
        return item if item.isfile() or item.isdir() else None
    if archive.exists():
        raise FileExistsError('Backup already exists')
    partial = archive.with_suffix('.partial')
    try:
        with tarfile.open(partial, 'w:gz') as out:
            out.add(data, arcname='maibot-qq', filter=include)
            out.add(ops, arcname='deployment', filter=lambda item: include(item) if
                    not any(part in {'dist', 'sources', '.release.lock'} for part in PurePosixPath(item.name).parts) else None)
            payload = json.dumps(record).encode()
            info = tarfile.TarInfo('release.json'); info.size = len(payload); info.mode = 0o600
            out.addfile(info, io.BytesIO(payload))
        partial.chmod(0o600); partial.replace(archive)
    finally:
        partial.unlink(missing_ok=True)


def unpack_backup(archive, stage):
    with tarfile.open(archive) as source:
        for item in source.getmembers():
            name = PurePosixPath(item.name)
            if (name.is_absolute() or '..' in name.parts or '\\' in item.name or not name.parts
                    or name.parts[0] not in {'maibot-qq', 'deployment', 'release.json'}
                    or not (item.isfile() or item.isdir())):
                raise ValueError('Unsafe backup entry; nothing extracted')
        source.extractall(stage, filter='data')


def backup(ops):
    live_container(ops)
    config = json.loads(compose(ops, 'config', '--format', 'json'))
    image = config['services']['maibot']['image']
    if not IMAGE.fullmatch(image) or (ops / 'compose.qq-face.yaml').exists():
        raise ValueError('Complete adoption of a published image before creating a portable backup')
    target = Path('/opt/maibot-qq-backups'); target.mkdir(mode=0o700, exist_ok=True)
    archive = target / ('release-' + stamp() + '.tar.gz')
    compose(ops, 'stop')
    try:
        write_backup(DATA, ops, archive, {'format': 1, 'image': image})
    finally:
        compose(ops, 'up', '-d', '--wait', '--wait-timeout', '300')
    print('Private portable backup (includes credentials; never publish): ' + str(archive))


def rollback(ops, transaction):
    record = json.loads((transaction / 'transaction.json').read_text())
    if Path(record['ops']).resolve() != ops or transaction.resolve().parent != DATA / 'backups':
        raise ValueError('Transaction does not belong to this deployment')
    compose(ops, 'stop', 'maibot')
    plugins = DATA / 'runtime/plugins'
    # Move, never delete: retain later plugin files/config for manual recovery.
    plugins.rename(plugins.with_name('plugins-before-rollback-' + stamp()))
    shutil.copytree(transaction / 'plugins', plugins)
    shutil.copy2(transaction / '.env', ops / '.env')
    overlay = json.loads((transaction / 'legacy.json').read_text())
    overlay['services']['maibot']['image'] = record['recovery_image']
    (ops / 'compose.qq-face.yaml').write_text(json.dumps(overlay, indent=2) + '\n')
    compose(ops, 'up', '-d', '--no-deps', '--wait', '--wait-timeout', '300', 'maibot')
    print('Previous code restored; current chat/database/image data retained. Recheck QQ behavior.')


def update(ops, image):
    env = (ops / '.env').read_text()
    new_env = image_env(env, image)
    legacy_file = ops / 'compose.qq-face.yaml'
    legacy = json.loads(legacy_file.read_text()) if legacy_file.exists() else {'services': {'maibot': {}}}
    validate_legacy_overlay(legacy)
    cid = live_container(ops)
    photo = DATA / 'runtime/data/plugins/haipengtian.nuonuo-photo/state.json'
    if photo.is_file() and json.loads(photo.read_text()).get('job', {}).get('status') == 'running':
        raise ValueError('A photo is generating; wait for its terminal result before updating')
    run(['docker', 'pull', image])
    audit_code(cid, image)
    tag = stamp(); transaction = DATA / 'backups' / ('release-' + tag)
    transaction.mkdir(mode=0o700, parents=True)
    recovery_image = 'maibot-qq-local:recovery-' + tag
    shutil.copy2(__file__, transaction / 'release.py')
    print('Recovery command: python3 ' + str(transaction / 'release.py') + ' --ops ' + str(ops) + ' rollback ' + str(transaction), flush=True)
    compose(ops, 'stop', 'maibot')
    try:
        run(['docker', 'commit', cid, recovery_image], True)
        shutil.copytree(DATA / 'runtime/plugins', transaction / 'plugins')
        shutil.copy2(ops / '.env', transaction / '.env')
        (transaction / 'legacy.json').write_text(json.dumps(legacy))
        (transaction / 'transaction.json').write_text(json.dumps({'ops': str(ops), 'recovery_image': recovery_image}))
    except Exception:
        run(['docker', 'start', cid], True)
        raise
    try:
        (ops / '.env').write_text(new_env)
        if legacy_file.exists():
            legacy_file.rename(transaction / 'compose.qq-face.yaml')
        compose(ops, 'config', '--quiet')
        compose(ops, 'up', '-d', '--no-deps', '--wait', '--wait-timeout', '300', 'maibot')
    except Exception:
        print('Update failed; restoring previous code.', flush=True)
        rollback(ops, transaction)
        raise
    print('Published image active: ' + image + '\nQQ/SnowLuma was not restarted. Verify real messages and image requests.')


def restore(ops, archive):
    if DATA.exists():
        raise ValueError('Restore requires an empty target server: /opt/maibot-qq must not exist')
    with tempfile.TemporaryDirectory(prefix='.maibot-restore-', dir='/opt') as tmp:
        stage = Path(tmp); unpack_backup(archive, stage)
        record = json.loads((stage / 'release.json').read_text())
        image = record['image']; image_env('MAIBOT_IMAGE=old\n', image)
        if (stage / 'deployment/compose.qq-face.yaml').exists():
            raise ValueError('Backup uses a server-local legacy override, not a portable published release')
        run(['docker', 'pull', image])
        for name in ('compose.yaml', '.env'):
            if not (stage / 'deployment' / name).is_file():
                raise ValueError('Incomplete deployment backup')
        destination = Path('/opt') / ('maibot-qq-restored-' + stamp())
        (stage / 'deployment').rename(destination)
        try:
            (stage / 'maibot-qq').rename(DATA)
        except Exception:
            destination.rename(stage / 'deployment')
            raise
    print('Restored without starting QQ. Run: cd ' + str(destination) +
          ' && bash deploy.sh start --local-stopped; then verify account/login and HTTPS domains.')


if __name__ == '__main__':
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ops', type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument('command', choices=['update', 'backup', 'rollback', 'restore'])
    parser.add_argument('value', nargs='?')
    args = parser.parse_args(); ops = args.ops.resolve()
    with operation(ops):
        if args.command == 'update':
            update(ops, args.value or '')
        elif args.command == 'backup':
            backup(ops)
        elif args.command == 'rollback':
            rollback(ops, Path(args.value).resolve())
        else:
            restore(ops, Path(args.value).resolve())
