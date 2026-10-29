from contextlib import closing
from pathlib import Path
import json
import sqlite3
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import migrate


class MigrationTests(unittest.TestCase):
    def test_export_preserves_data_and_changes_only_container_addresses(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runtime = root / 'runtime'
            (runtime / 'config').mkdir(parents=True)
            (runtime / 'config/bot_config.toml').write_text(
                '[http]\nhost=["127.0.0.1"]\nport=18011\n[personality]\nname="original"\n')
            (runtime / 'config/model_config.toml').write_text('[provider]\napi_key="synthetic-secret"\n')
            plugin = runtime / 'plugins/snowluma-adapter'
            plugin.mkdir(parents=True)
            (plugin / 'config.toml').write_text('[client]\nserver="127.0.0.1"\nport=13001\ntoken="synthetic-token"\n')
            data = runtime / 'data'
            data.mkdir()
            db = sqlite3.connect(data / 'MaiBot.db')
            db.execute('pragma journal_mode=wal')
            db.execute('create table messages (text text)')
            db.execute('insert into messages values (?)', ('preserve me',))
            db.commit()
            for filename in ['eula.confirmed', 'privacy.confirmed']:
                (runtime / filename).write_text('accepted')
            photo = data / 'plugins/haipengtian.nuonuo-photo'
            photo.mkdir(parents=True)
            (photo / 'face.jpg').write_bytes(b'original-image')
            (photo / 'state.json').write_text(json.dumps({'reference': 'face.jpg'}))
            snowluma = root / 'snowluma'
            for name in ['data', 'qq-config', 'qq-data']:
                (snowluma / name).mkdir(parents=True)
            archive = root / 'migration.tar.gz'
            migrate.export_bundle(runtime, snowluma, archive, quiesced=False)
            db.close()
            target = root / 'target'
            migrate.import_bundle(archive, target, require_cutover=False)
            import tomllib
            c = tomllib.loads((target / 'runtime/config/bot_config.toml').read_text())
            self.assertEqual(c['http'], {'host': ['0.0.0.0'], 'port': 8001})
            self.assertEqual(c['personality']['name'], 'original')
            adapter = tomllib.loads((target / 'runtime/plugins/snowluma-adapter/config.toml').read_text())
            self.assertEqual(adapter['client']['server'], 'snowluma')
            self.assertEqual(adapter['client']['token'], 'synthetic-token')
            self.assertIn('synthetic-secret', (target / 'runtime/config/model_config.toml').read_text())
            with closing(sqlite3.connect(target / 'runtime/data/MaiBot.db')) as recovered:
                self.assertEqual(recovered.execute('select text from messages').fetchall(), [('preserve me',)])
            self.assertEqual((target / 'runtime/data/plugins/haipengtian.nuonuo-photo/face.jpg').read_bytes(), b'original-image')
            self.assertFalse((target / 'runtime/data/MaiBot.db-wal').exists())
            with self.assertRaises(FileExistsError):
                migrate.import_bundle(archive, target, require_cutover=False)
            with self.assertRaises(ValueError):
                migrate.import_bundle(archive, root / 'live-target', require_cutover=True)

    def test_import_rejects_archive_traversal_and_links(self):
        import io
        with tempfile.TemporaryDirectory() as tmp:
            for kind in ['traversal', 'symlink']:
                archive = Path(tmp) / f'{kind}.tar.gz'
                with tarfile.open(archive, 'w:gz') as out:
                    item = tarfile.TarInfo('../escape' if kind == 'traversal' else 'runtime/link')
                    if kind == 'symlink':
                        item.type = tarfile.SYMTYPE
                        item.linkname = '/etc/passwd'
                    out.addfile(item, io.BytesIO())
                with self.assertRaises(ValueError):
                    migrate.import_bundle(archive, Path(tmp) / kind, require_cutover=False)
            self.assertFalse((Path(tmp) / 'escape').exists())


if __name__ == '__main__':
    unittest.main()
