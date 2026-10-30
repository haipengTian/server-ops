import importlib.util
from pathlib import Path
import unittest
import json
import tempfile
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("face_install", Path(__file__).parents[1] / "install_qq_face_visual.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def test_only_face_mode_changes_and_comments_remain(self):
        original = '# keep\n[plugin]\ntoken = "keep-private"\nqq_face_parse_mode = "emoji" # mode\n\n[other]\nqq_face_parse_mode = "description"\n'
        changed = installer.visual_config(original)
        self.assertEqual(changed, original.replace('= "emoji" # mode', '= "visual" # mode'))

    def test_missing_mode_is_added_only_inside_plugin(self):
        original = '[plugin]\nenabled = true\n[connection]\nport = 13001\n'
        self.assertIn('[plugin]\nqq_face_parse_mode = "visual"\n', installer.visual_config(original))
        with self.assertRaises(ValueError):
            installer.visual_config('[connection]\nport = 13001\n')

    def test_current_deploy_helper_is_preserved_and_upgrade_is_idempotent(self):
        current = (Path(__file__).parents[1] / "deploy.sh").read_text(encoding="utf-8")
        self.assertEqual(installer.deployment_helper(current), current)
        self.assertIn('"${extra[@]}"', current)
        original = '# keep\n' + installer.OLD_HELPER + '\n# keep too\n'
        changed = installer.deployment_helper(original)
        self.assertTrue(changed.startswith('# keep\n'))
        self.assertTrue(changed.endswith('\n# keep too\n'))
        with self.assertRaises(ValueError):
            installer.deployment_helper('something unexpected')

    def test_invalid_candidate_does_not_block_rollback_or_discard_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ops, backup = root / "ops", root / "backup"
            ops.mkdir()
            backup.mkdir()
            helper, overlay = ops / "deploy.sh", ops / "compose.qq-face.yaml"
            helper.write_text(installer.NEW_HELPER)
            overlay.write_text('invalid compose: [')
            (backup / "saved-0").write_text(installer.OLD_HELPER)
            (backup / "restore.json").write_text(json.dumps({
                "ops": str(ops), "files": {str(helper): True, str(overlay): False},
                "snapshot_image": "maibot-qq-local:recovery", "container_name": "maibot-qq-maibot-1"}))
            calls = []

            def fake_run(args, **kwargs):
                calls.append(args)
                return b'maibot-qq-maibot-1\n' if args[1] == 'ps' else None

            def fake_compose(ops_path, *args):
                self.assertNotIn('stop', args)
                recovered = json.loads(overlay.read_text())
                self.assertEqual(recovered['services']['maibot']['image'], 'maibot-qq-local:recovery')

            with patch.object(installer, 'run', side_effect=fake_run), patch.object(installer, 'compose', side_effect=fake_compose):
                installer.restore(backup)
            self.assertIn(['docker', 'stop', 'maibot-qq-maibot-1'], calls)
            self.assertEqual(helper.read_text(), installer.NEW_HELPER)


if __name__ == "__main__":
    unittest.main()
