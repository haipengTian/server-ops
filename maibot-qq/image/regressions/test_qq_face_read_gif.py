"""Integration with pinned Read GIF; only the external LLM call is faked."""

import base64
import io
import logging
import os
from pathlib import Path
import sys
import tempfile
import unittest

from PIL import Image
from test_qq_face_visual import codec_module, ROOT
from types import SimpleNamespace

sys.path.insert(0, os.environ["READ_GIF_ROOT"])
from read_animation.config import ReadAnimationConfig
from read_animation.pipeline import AnimationProcessor
from read_animation.frames import AnimationReader


class NativeFaceAnimationTests(unittest.IsolatedAsyncioTestCase):
    async def test_palette_apng_keeps_its_colors_after_duration_scan_and_rewind(self):
        original = (ROOT / "assets/qq_faces/0.png").read_bytes()
        with Image.open(io.BytesIO(original)) as im:
            expected = im.convert("RGBA").tobytes()
        reader = AnimationReader(original, "apng", max_scan_frames=3000)
        try:
            self.assertEqual(reader.render_frame(0, max_edge=128, background="keep").tobytes(), expected)
            reader.render_frame(20, max_edge=128, background="keep")
            self.assertEqual(reader.render_frame(0, max_edge=128, background="keep").tobytes(), expected)
        finally:
            reader.close()

    async def test_original_qq_animation_reaches_multiframe_recognition_and_cache(self):
        calls = []

        async def fake_llm(**kwargs):
            calls.append(kwargs)
            return {"success": True, "response": "测试描述：画面随时间变化。"}

        codec = codec_module.QQInboundCodec(
            logging.getLogger("qq-face-integration"), None,
            SimpleNamespace(profile=SimpleNamespace(client_type="snowluma")),
            lambda: SimpleNamespace(plugin=SimpleNamespace(qq_face_parse_mode="visual")))
        segments, _ = await codec.convert_segments(
            {"message": [{"type": "face", "data": {"id": "0"}}]}, "123")
        image = next(s for s in segments if s["type"] == "image")
        original = (ROOT / "assets/qq_faces/0.png").read_bytes()
        self.assertEqual(base64.b64decode(image["binary_data_base64"]), original)
        with Image.open(io.BytesIO(original)) as im:
            self.assertGreater(im.n_frames, 1)
        with tempfile.TemporaryDirectory() as tmp:
            processor = AnimationProcessor(config=ReadAnimationConfig(), llm_generate=fake_llm,
                logger=logging.getLogger("qq-face-integration"), cache_path=Path(tmp) / "cache.json")
            await processor.initialize()
            try:
                first = await processor.process_message({"raw_message": segments})
                self.assertIsNotNone(first)
                text = " ".join(str(s.get("data", "")) for s in first["raw_message"] if s["type"] == "text")
                self.assertIn("测试描述", text)
                self.assertIn("APNG", text)
                self.assertEqual(len(calls), 1)
                self.assertEqual(calls[0]["task_name"], "vlm")
                parts = calls[0]["prompt"][1]["content"]
                sheet = next(p for p in parts if p["type"] == "image")
                sheet_bytes = base64.b64decode(sheet["image_base64"])
                with Image.open(io.BytesIO(sheet_bytes)) as im:
                    self.assertGreater(im.width * im.height, 128 * 128)
                if os.environ.get("FRAME_SHEET_OUTPUT"):
                    Path(os.environ["FRAME_SHEET_OUTPUT"]).write_bytes(sheet_bytes)
                second = await processor.process_message({"raw_message": segments})
                self.assertIsNotNone(second)
                self.assertEqual(len(calls), 1)
                # The static 虎虎生威 does not trigger invented animation analysis.
                static, _ = await codec.convert_segments(
                    {"message": [{"type": "face", "data": {"id": "334"}}]}, "123")
                self.assertIsNone(await processor.process_message({"raw_message": static}))
            finally:
                await processor.close()


if __name__ == "__main__":
    unittest.main()
