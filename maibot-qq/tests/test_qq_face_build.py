import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location("build_qq_faces", Path(__file__).parents[1] / "image/build_qq_faces.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def entry(kind="png", face_id="334"):
    return {"type": kind, "path": f"assets/qq_emoji/{face_id}/{kind}/{face_id}.png"}


class AssetSelectionTests(unittest.TestCase):
    def test_prefers_original_apng_over_static_preview(self):
        index = {"emojis": {"334": {"describe": "/虎虎生威", "assets": [entry(), entry("apng")]}}}
        selected = builder.select_assets(index)
        self.assertEqual(selected["334"]["source_type"], "apng")
        self.assertEqual(selected["334"]["name"], "虎虎生威")

    def test_unicode_ids_and_unavailable_assets_are_not_fabricated(self):
        index = {"emojis": {
            "334": {"describe": "/虎虎生威", "assets": [entry()]},
            "999": {"describe": "/无图", "assets": []},
            "🐯": {"describe": "/虎", "assets": [entry(face_id="🐯")]}}}
        self.assertEqual(list(builder.select_assets(index)), ["334"])

    def test_unexpected_asset_paths_fail_instead_of_downloading_them(self):
        index = {"emojis": {"334": {"describe": "/虎虎生威", "assets": [
            {"type": "png", "path": "https://other.example/334.png"}]}}}
        with self.assertRaises(ValueError):
            builder.select_assets(index)


if __name__ == "__main__":
    unittest.main()
