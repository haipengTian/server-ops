import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
import textwrap
from unittest.mock import AsyncMock


ROOT = Path(__file__).resolve().parents[1] / "qzone-bridge"


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DiaryPublishTests(unittest.IsolatedAsyncioTestCase):
    async def test_diary_uses_existing_space_api_and_requests_images(self):
        module = load_module("diary_space_bridge", "diary_space_bridge.py")
        call = AsyncMock(return_value={"result": True})
        publisher = module.MaizonePublisher(SimpleNamespace(call_capability=call))
        self.assertTrue(await publisher.publish("日记正文", napcat_token="unused"))
        call.assert_awaited_once_with(
            "api.call", timeout_ms=300000,
            api_name="internetsb.maizone.send_feed_api", version="1",
            args={"message": "日记正文", "auto_image": True},
        )

    async def test_failed_or_malformed_publish_is_not_success(self):
        module = load_module("diary_space_bridge", "diary_space_bridge.py")
        for response in ({"result": False}, None, {"result": "false"}):
            call = AsyncMock(return_value=response)
            self.assertFalse(await module.MaizonePublisher(
                SimpleNamespace(call_capability=call)).publish("日记"))


class PatchGuardTests(unittest.TestCase):
    def test_image_patch_supports_installed_sync_client(self):
        module = load_module("apply_qzone_bridge", "apply.py")
        source = ('from openai import OpenAI\n'
                  'def generate_image(base_url, api_key, body):\n'
                  '    client = OpenAI(base_url=base_url, api_key=api_key)\n'
                  '    response = client.images.generate(**body)\n'
                  '    return response\n')
        patched = module.patch_image(source)
        calls = []
        def fake_client(**kwargs):
            calls.append(kwargs)
            return SimpleNamespace(images=SimpleNamespace(generate=lambda **body: body))
        namespace = {}
        exec(patched.replace('from openai import OpenAI', ''),
             {"OpenAI": fake_client}, namespace)
        self.assertEqual(namespace["generate_image"]("https://example.test/v1", "test-only", {"n": 1}), {"n": 1})
        self.assertEqual(calls, [{"base_url": "https://example.test/v1", "api_key": "test-only",
                                 "max_retries": 0, "timeout": 180.0}])
        self.assertEqual(module.patch_image(patched), patched)

    def test_image_patch_supports_async_client(self):
        module = load_module("apply_qzone_bridge", "apply.py")
        source = 'client = AsyncOpenAI(base_url=base_url, api_key=api_key)\n'
        patched = module.patch_image(source)
        self.assertIn('AsyncOpenAI(base_url=base_url, api_key=api_key, max_retries=0, timeout=180.0)', patched)
        self.assertEqual(module.patch_image(patched), patched)

    def test_ambiguous_or_unknown_client_is_rejected(self):
        module = load_module("apply_qzone_bridge", "apply.py")
        for source in ('client = OtherClient()',
                       'a = OpenAI(base_url=base_url, api_key=api_key)\n'
                       'b = AsyncOpenAI(base_url=base_url, api_key=api_key)'):
            with self.assertRaises(ValueError):
                module.patch_image(source)

    def test_changed_upstream_is_rejected(self):
        module = load_module("apply_qzone_bridge", "apply.py")
        with self.assertRaises(ValueError):
            module.replace_once("upstream changed", "expected block", "new block")

    def test_permission_patch_uses_runtime_identity(self):
        module = load_module("apply_qzone_bridge", "apply.py")
        source = ('        users = await self.ctx.db.get(model_name="PersonInfo", filters={"person_name": nickname})\n'
                  '        user_id = users[0].get("user_id") if users else ""\n')
        patched = module.patch_send_identity(source)
        self.assertNotIn("PersonInfo", patched)
        scope = {"kwargs": {"user_id": "222"}, "nickname": "主人"}
        exec(textwrap.dedent(patched), {}, scope)
        self.assertEqual(scope["user_id"], "222")


if __name__ == "__main__":
    unittest.main()
