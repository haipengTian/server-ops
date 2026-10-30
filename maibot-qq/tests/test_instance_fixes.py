import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location('instance_fixes', ROOT / 'image/instance_fixes.py')
fixes = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixes)


class InstanceFixTests(unittest.TestCase):
    def test_standalone_diary_is_not_changed_or_given_new_dependencies(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); plugin = root / 'plugins/diary'; plugin.mkdir(parents=True)
            (plugin / '_manifest.json').write_text(json.dumps({'id': 'bockegai.diary-plugin', 'version': '3.0.1'}))
            (plugin / 'plugin.py').write_text('original standalone diary')
            fixes.apply(root, ROOT / 'qzone-bridge', root / 'missing-host.py')
            self.assertEqual((plugin / 'plugin.py').read_text(), 'original standalone diary')

    def test_unsupported_installed_pair_is_not_silently_patched(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for folder, name in [('diary', 'bockegai.diary-plugin'), ('space', 'internetsb.maizone')]:
                plugin = root / 'plugins' / folder; plugin.mkdir(parents=True)
                (plugin / '_manifest.json').write_text(json.dumps({'id': name, 'version': '99.0.0'}))
            with self.assertRaises(ValueError):
                fixes.apply(root, ROOT / 'qzone-bridge', root / 'missing-host.py')
