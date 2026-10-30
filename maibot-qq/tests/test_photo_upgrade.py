import importlib.util
import json
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location("photo_upgrade", Path(__file__).parents[1] / "upgrade_photo.py")
upgrade = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upgrade)


class PhotoUpgradeTests(unittest.TestCase):
    def test_code_only_update_keeps_portrait_and_entire_saved_state(self):
        state = {"reference": "private.jpg", "candidate": "candidate.jpg", "job": {"status": "failed"},
                 "requests": {"chat:req": "job"}}
        changed = upgrade.reference_state(state, "")
        self.assertEqual(changed, state)
        self.assertIsNot(changed, state)

    def test_reference_update_preserves_requests_and_generated_outputs(self):
        old = {"reference": "old.jpg", "candidate": "older.jpg", "requests": {"chat:req": "job"},
               "job": {"status": "completed", "output": "photo.jpg"}}
        changed = upgrade.reference_state(old, "new.jpg")
        self.assertEqual(changed["reference"], "new.jpg")
        self.assertEqual(changed["candidate"], "new.jpg")
        self.assertEqual(changed["requests"], old["requests"])
        self.assertEqual(changed["job"], old["job"])
        self.assertEqual(old["reference"], "old.jpg")

    def test_running_generation_prevents_reference_change(self):
        with self.assertRaises(ValueError):
            upgrade.reference_state({"job": {"status": "running"}}, "new.jpg")

    def test_image_change_preserves_qq_face_mounts_and_extra_settings(self):
        original = {"services": {"maibot": {"image": "local:old", "volumes": [{"source": "qq-face"}],
                    "environment": {"TZ": "Asia/Shanghai"}}}}
        updated = json.loads(upgrade.image_override(json.dumps(original), "local:new"))
        self.assertEqual(updated["services"]["maibot"]["image"], "local:new")
        self.assertEqual(updated["services"]["maibot"]["volumes"], original["services"]["maibot"]["volumes"])
        self.assertEqual(updated["services"]["maibot"]["environment"], {"TZ": "Asia/Shanghai"})

    def test_rollback_preserves_new_chats_and_does_not_replace_a_later_portrait(self):
        previous = {"reference": "old.jpg", "candidate": "old-candidate.jpg"}
        current = {"reference": "new.jpg", "candidate": "new.jpg", "requests": {"new-request": "new-job"}, "job": {"output": "new-output.jpg"}}
        restored = upgrade.restore_reference(current, previous, "new.jpg")
        self.assertEqual(restored["reference"], "old.jpg")
        self.assertEqual(restored["requests"], current["requests"])
        self.assertEqual(restored["job"], current["job"])
        current["reference"] = "later.jpg"
        self.assertEqual(upgrade.restore_reference(current, previous, "new.jpg")["reference"], "later.jpg")


if __name__ == "__main__":
    unittest.main()
