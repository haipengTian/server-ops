"""Run with ADAPTER_ROOT pointing at the image-pinned SnowLuma adapter."""

import base64
import importlib
import io
import logging
import os
from pathlib import Path
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch

from PIL import Image


ROOT = Path(os.environ["ADAPTER_ROOT"])
PACKAGE = "qq_face_visual_test"
package = ModuleType(PACKAGE)
package.__path__ = [str(ROOT)]
sys.modules[PACKAGE] = package
codec_module = importlib.import_module(f"{PACKAGE}.codecs.inbound.message_codec")


class FaceVisualTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.assets = tempfile.TemporaryDirectory()
        self.addCleanup(self.assets.cleanup)
        self.asset_dir = Path(self.assets.name)
        self.asset_patch = patch.object(codec_module, "QQ_FACE_ASSET_DIR", self.asset_dir, create=True)
        self.asset_patch.start()
        self.addCleanup(self.asset_patch.stop)
        self.mode = "visual"
        self.codec = codec_module.QQInboundCodec(
            logging.getLogger("test.qq-face"), None,
            SimpleNamespace(profile=SimpleNamespace(client_type="snowluma")),
            lambda: SimpleNamespace(plugin=SimpleNamespace(qq_face_parse_mode=self.mode)),
        )

    def image(self, face_id="334", animated=False):
        image = Image.new("RGBA", (16, 16), "red")
        options = {"save_all": True, "append_images": [Image.new("RGBA", (16, 16), "blue")],
                   "duration": [100, 200], "loop": 0} if animated else {}
        path = self.asset_dir / f"{face_id}.png"
        image.save(path, **options)
        return path.read_bytes()

    async def convert(self, face_id="334"):
        return (await self.codec.convert_segments(
            {"message": [{"type": "face", "data": {"id": face_id}}]}, "123"))[0]

    async def test_visual_face_contains_name_and_real_image(self):
        original = self.image()
        segments = await self.convert()
        self.assertEqual([s["type"] for s in segments], ["text", "image"])
        self.assertIn("QQ原生表情", segments[0]["data"])
        self.assertIn("虎虎生威", segments[0]["data"])
        self.assertIn("334", segments[0]["data"])
        self.assertEqual(base64.b64decode(segments[1]["binary_data_base64"]), original)

    async def test_original_animation_is_not_flattened_to_first_frame(self):
        original = self.image("0", animated=True)
        segments = await self.convert("0")
        self.assertEqual([s["type"] for s in segments], ["text", "image"])
        binary = base64.b64decode(segments[1]["binary_data_base64"])
        self.assertEqual(binary, original)
        self.assertEqual(Image.open(io.BytesIO(binary)).n_frames, 2)

    async def test_legacy_modes_keep_original_contract(self):
        for mode, expected in (("description", "[虎虎生威]"), ("emoji", "[虎虎生威]")):
            self.mode = mode
            self.assertEqual(await self.convert(), [{"type": "text", "data": expected}])
        self.assertEqual(await self.convert("0"), [{"type": "text", "data": "😮"}])

    async def test_missing_asset_is_explicit_and_does_not_drop_message(self):
        with self.assertLogs("test.qq-face", level="WARNING"):
            segments = await self.convert()
        self.assertEqual(len(segments), 1)
        self.assertIn("虎虎生威", segments[0]["data"])
        self.assertIn("未取得图像", segments[0]["data"])

    async def test_untrusted_id_cannot_read_a_local_file(self):
        self.image()
        for face_id in ("../../334", "file:///etc/passwd", "99999999", "３３４"):
            with self.assertLogs("test.qq-face", level="WARNING"):
                segments = await self.convert(face_id)
            self.assertEqual([s["type"] for s in segments], ["text"])

    async def test_user_typed_label_is_not_converted(self):
        self.image()
        segments, _ = await self.codec.convert_segments(
            {"message": [{"type": "text", "data": {"text": "[虎虎生威]"}}]}, "123")
        self.assertEqual(segments, [{"type": "text", "data": "[虎虎生威]"}])

    async def test_picture_flag_and_identity_survive_message_building(self):
        self.image()
        result = await self.codec.build_message_dict(
            {"message_id": 42, "message_type": "private", "time": 123,
             "message": [{"type": "face", "data": {"id": 334}}]},
            "123", "456", {"nickname": "friend"})
        self.assertTrue(result["is_picture"])
        self.assertEqual(result["message_id"], "42")
        self.assertIn("虎虎生威", result["processed_plain_text"])


if __name__ == "__main__":
    unittest.main()
