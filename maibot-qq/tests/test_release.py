import importlib.util
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release', Path(__file__).parents[1] / 'release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_update_and_failed_start_restore_code_without_losing_new_chat_data(self):
        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); ops = root / 'ops'; data = root / 'maibot-qq'
                ops.mkdir(); (data / 'runtime/plugins/bilibili').mkdir(parents=True)
                plugin = data / 'runtime/plugins/bilibili/plugin.py'; plugin.write_text('keep custom plugin')
                chat = data / 'runtime/chat.db'; chat.write_bytes(b'old messages')
                (ops / '.env').write_text('MAIBOT_IMAGE=old\nPRIVATE=keep\n')
                (ops / 'compose.qq-face.yaml').write_text(json.dumps({'services': {'maibot': {'image': 'local:old'}}}))
                starts = []
                def compose(ops_dir, *args, **kwargs):
                    if args[0] == 'up':
                        starts.append(args)
                        if len(starts) == 1:
                            chat.write_bytes(b'old and new messages')
                            if fail:
                                plugin.write_text('candidate startup edit')
                                raise RuntimeError('failed healthcheck')
                    return b''
                image = 'ghcr.io/haipengtian/maibot-qq:sha-123456789abc'
                with patch.object(release, 'DATA', data), patch.object(release, 'compose', side_effect=compose), \
                     patch.object(release, 'live_container', return_value='container'), \
                     patch.object(release, 'audit_code'), patch.object(release, 'run'):
                    if fail:
                        with self.assertRaisesRegex(RuntimeError, 'healthcheck'):
                            release.update(ops, image)
                        self.assertEqual(len(starts), 2)
                        restored = json.loads((ops / 'compose.qq-face.yaml').read_text())
                        self.assertTrue(restored['services']['maibot']['image'].startswith('maibot-qq-local:recovery-'))
                    else:
                        release.update(ops, image)
                        self.assertFalse((ops / 'compose.qq-face.yaml').exists())
                        self.assertIn(image, (ops / '.env').read_text())
                self.assertEqual(plugin.read_text(), 'keep custom plugin')
                self.assertEqual(chat.read_bytes(), b'old and new messages')

    def test_real_instance_mount_is_runtime_not_data_parent(self):
        mounted = [{'Destination': '/instance', 'Source': '/opt/maibot-qq/runtime'}]
        with patch.object(release, 'compose', return_value=b'container\n'), \
             patch.object(release, 'run', return_value=json.dumps(mounted).encode()):
            self.assertEqual(release.live_container(Path('/ops')), 'container')

    def test_remove_only_known_legacy_overlay(self):
        original = {'services': {'maibot': {'image': 'local:photo', 'volumes': [
            {'type': 'bind', 'source': '/opt/maibot-qq/qq-face-visual/old/config.py',
             'target': '/opt/bundled-plugins/snowluma-adapter/config.py', 'read_only': True}]}}}
        release.validate_legacy_overlay(original)
        for changed in ({'services': {'maibot': {'ports': ['8001:8001']}}},
                        {'services': {'snowluma': {'image': 'unexpected'}}},
                        {'services': {'maibot': {'volumes': [{'target': '/instance'}]}}}):
            with self.assertRaises(ValueError):
                release.validate_legacy_overlay(changed)

    def test_change_image_preserves_other_env_and_rejects_unversioned(self):
        old = '# comment\nMAIBOT_IMAGE=old\nPRIVATE_VALUE=keep\n'
        image = 'ghcr.io/haipengtian/maibot-qq:sha-123456789abc'
        self.assertEqual(release.image_env(old, image), old.replace('=old', '=' + image))
        for image in ('latest', 'ghcr.io/haipengtian/maibot-qq:latest', 'other:sha-123456789abc'):
            with self.assertRaises(ValueError):
                release.image_env(old, image)

    def test_code_inventory_compares_contents_and_reports_unknown_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            old, new = Path(tmp) / 'old', Path(tmp) / 'new'
            old.mkdir(); new.mkdir()
            (old / 'runtime.py').write_text('old fix\n')
            (new / 'runtime.py').write_text('missing fix\n')
            (old / '__pycache__').mkdir()
            (old / '__pycache__/cache.pyc').write_bytes(b'cache')
            self.assertEqual(release.code_differences(old, new), ['runtime.py'])
            (new / 'runtime.py').write_text('old fix\n')
            self.assertEqual(release.code_differences(old, new), [])

    def test_backup_round_trip_preserves_all_plugins_images_and_private_settings(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); data = root / 'maibot-qq'; ops = root / 'ops'
            for name in ('runtime/plugins/bilibili/plugin.py', 'runtime/config/models.toml',
                         'runtime/data/plugins/photo/reference.jpg', 'snowluma/data/login.json'):
                path = data / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(name.encode())
            (data / 'backups').mkdir(); (data / 'backups/old.tar').write_bytes(b'not recursive')
            ops.mkdir(); (ops / '.env').write_text('PRIVATE=synthetic\n')
            (ops / 'compose.yaml').write_text('services: {}')
            archive = root / 'backup.tar.gz'
            release.write_backup(data, ops, archive, {'image': 'versioned'})
            stage = root / 'restored'
            release.unpack_backup(archive, stage)
            self.assertEqual((stage / 'maibot-qq/runtime/plugins/bilibili/plugin.py').read_bytes(), b'runtime/plugins/bilibili/plugin.py')
            self.assertEqual((stage / 'deployment/.env').read_text(), 'PRIVATE=synthetic\n')
            self.assertFalse((stage / 'maibot-qq/backups/old.tar').exists())
            self.assertEqual(json.loads((stage / 'release.json').read_text())['image'], 'versioned')

    def test_restore_rejects_traversal_and_links_before_extracting(self):
        import io
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for filename in ('../escape', '/absolute', 'maibot-qq/../../escape'):
                archive = root / 'bad.tar'
                with tarfile.open(archive, 'w') as out:
                    item = tarfile.TarInfo(filename); item.size = 1; out.addfile(item, io.BytesIO(b'x'))
                with self.assertRaises(ValueError):
                    release.unpack_backup(archive, root / 'stage')


if __name__ == '__main__':
    unittest.main()
