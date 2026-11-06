"""Export an instance without disclosing credentials; import once into an empty directory."""

from contextlib import closing
from pathlib import Path, PurePosixPath

import argparse
import json
import shutil
import sqlite3
import tarfile
import tempfile


def copy_tree(source: Path, target: Path) -> None:
    target.mkdir(parents=True, exist_ok=True)
    for item in source.iterdir():
        if item.name in {'.git', '__pycache__', '.pytest_cache', 'logs', 'config_back'}:
            continue
        if item.is_symlink():
            continue
        dest = target / item.name
        if item.is_dir():
            copy_tree(item, dest)
        elif item.is_file() and not item.name.endswith(('-wal', '-shm', '.lock', '.sock')):
            # SQLite backup includes committed WAL records without copying a changing database file.
            with item.open('rb') as stream:
                sqlite = stream.read(16) == b'SQLite format 3\x00'
            if sqlite:
                with closing(sqlite3.connect(item.resolve().as_uri() + '?mode=ro', uri=True)) as src:
                    with closing(sqlite3.connect(dest)) as dst:
                        src.backup(dst)
            else:
                shutil.copy2(item, dest)


def export_bundle(runtime: Path, snowluma: Path, archive: Path, *, quiesced: bool) -> None:
    for path in (runtime / 'config/bot_config.toml', runtime / 'config/model_config.toml',
                 runtime / 'plugins/snowluma-adapter/config.toml', runtime / 'eula.confirmed',
                 runtime / 'privacy.confirmed'):
        if not path.is_file():
            raise ValueError(f'Missing required instance file: {path.name}')
    if archive.exists():
        raise FileExistsError('Choose a new archive filename; existing backups are not overwritten.')
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='maibot-export-') as tmp:
        stage = Path(tmp)
        for name in ('config', 'data', 'plugins', 'depends-data'):
            if (runtime / name).is_dir():
                copy_tree(runtime / name, stage / 'runtime' / name)
        for name in ('eula.confirmed', 'privacy.confirmed'):
            shutil.copy2(runtime / name, stage / 'runtime' / name)
        for name in ('data', 'qq-config', 'qq-data'):
            if not (snowluma / name).is_dir():
                raise ValueError(f'Missing SnowLuma directory: {name}')
            copy_tree(snowluma / name, stage / 'snowluma' / name)
        (stage / 'migration.json').write_text(json.dumps({
            'format': 1, 'source_stopped': quiesced,
            'note': 'Contains private configuration and QQ login state. Never upload to GitHub.'
        }), encoding='utf-8')
        partial = archive.with_suffix(archive.suffix + '.partial')
        try:
            with tarfile.open(partial, 'w:gz') as out:
                for child in stage.iterdir():
                    out.add(child, arcname=child.name)
            partial.chmod(0o600)
            partial.replace(archive)
        finally:
            partial.unlink(missing_ok=True)


def import_bundle(archive: Path, target: Path, *, require_cutover: bool = True) -> None:
    import tomlkit

    if target.exists() and any(target.iterdir()):
        raise FileExistsError('Target must be empty. Existing instances are never overwritten.')
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.maibot-import-', dir=target.parent) as tmp:
        stage = Path(tmp)
        with tarfile.open(archive, 'r:gz') as source:
            members = source.getmembers()
            for member in members:
                name = PurePosixPath(member.name)
                if (name.is_absolute() or '..' in name.parts or '\\' in member.name
                        or not (member.isfile() or member.isdir())
                        or not name.parts or name.parts[0] not in {'runtime', 'snowluma', 'migration.json'}):
                    raise ValueError('Archive contains an unsafe entry.')
            source.extractall(stage, members=members, filter='data')
        metadata = json.loads((stage / 'migration.json').read_text(encoding='utf-8'))
        if metadata.get('format') != 1 or (require_cutover and metadata.get('source_stopped') is not True):
            raise ValueError('Use a final export made after stopping local MaiBot and SnowLuma.')
        config = stage / 'runtime/config/bot_config.toml'
        doc = tomlkit.parse(config.read_text(encoding='utf-8'))
        doc['http']['host'] = ['0.0.0.0']
        doc['http']['port'] = 8001
        config.write_text(tomlkit.dumps(doc), encoding='utf-8')
        adapter = stage / 'runtime/plugins/snowluma-adapter/config.toml'
        doc = tomlkit.parse(adapter.read_text(encoding='utf-8'))
        doc['client']['server'] = 'snowluma'
        doc['client']['port'] = 13001
        adapter.write_text(tomlkit.dumps(doc), encoding='utf-8')
        for name in ('data', 'qq-config', 'qq-data'):
            if not (stage / 'snowluma' / name).is_dir():
                raise ValueError('Incomplete SnowLuma archive.')
        if not (stage / 'runtime/data/MaiBot.db').is_file():
            raise ValueError('Missing MaiBot database.')
        # Only private runtime files enter this directory; restrict host access.
        for path in stage.rglob('*'):
            path.chmod(0o700 if path.is_dir() else 0o600)
        if target.exists():
            target.rmdir()  # only the verified empty directory
        stage.rename(target)
        target.chmod(0o700)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    export = commands.add_parser('export')
    export.add_argument('--runtime', type=Path, required=True)
    export.add_argument('--snowluma', type=Path, required=True)
    export.add_argument('--out', type=Path, required=True)
    export.add_argument('--quiesced', action='store_true', help='Confirm both source services have stopped')
    restore = commands.add_parser('import')
    restore.add_argument('--archive', type=Path, required=True)
    restore.add_argument('--target', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'export':
        export_bundle(args.runtime.resolve(), args.snowluma.resolve(), args.out.resolve(), quiesced=args.quiesced)
        print('Export complete. Private migration archive saved locally; do not upload it to GitHub.')
    else:
        import_bundle(args.archive.resolve(), args.target.resolve())
        print('Import complete. Configuration, database and original photo reference preserved.')


if __name__ == '__main__':
    main()
