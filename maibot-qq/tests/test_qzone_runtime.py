"""针对补丁实际生成的处理器测试，避免只检查文本替换。"""

import ast
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock


def transformed_handlers(source):
    tree = ast.parse(source)
    cls = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "MaizonePlugin")
    selected = {"check_permission", "handle_send_feed_tool", "handle_read_feed_tool", "send_feed_api"}
    cls.bases = []
    cls.body = [n for n in cls.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name in selected]
    for method in cls.body:
        method.decorator_list = []
    module = ast.Module(body=[cls], type_ignores=[])
    ast.fix_missing_locations(module)
    namespace = {"send_feed": AsyncMock(return_value=(True, "sent")),
                 "read_feed": AsyncMock(return_value=(True, [])),
                 "generate_images": AsyncMock(return_value=[b"image"]),
                 "renew_cookies": AsyncMock(),
                 "create_qzone_api": lambda: None}
    exec(compile(module, "<patched-maizone>", "exec"), namespace)
    return namespace, namespace["MaizonePlugin"]()


class RuntimeTests(unittest.IsolatedAsyncioTestCase):
    """设置 QZONE_FIXTURE 指向只含公开上游源码的临时目录后运行。"""

    async def asyncSetUp(self):
        import os
        fixture = os.environ.get("QZONE_FIXTURE")
        if not fixture:
            self.skipTest("真实上游源码集成检查通过 QZONE_FIXTURE 单独运行")
        self.ns, self.plugin = transformed_handlers(
            (Path(fixture) / "maizone" / "plugin.py").read_text(encoding="utf-8"))
        self.plugin.config = SimpleNamespace(
            authority=SimpleNamespace(send_authority_type="whitelist", send_whitelist=["owner"],
                send_blacklist=[], read_authority_type="whitelist", read_whitelist=["owner"], read_blacklist=[]),
            plugin=SimpleNamespace(http_host="unused", http_port="0", napcat_token=""),
            send=SimpleNamespace(enable_image=True, image_mode="only_ai", image_number=1, ai_probability=0.5))

    async def test_nickname_cannot_impersonate_owner(self):
        for kwargs in ({"user_id": "stranger"}, {}):
            result = await self.plugin.handle_send_feed_tool("topic", "owner", **kwargs)
            self.assertFalse(result[0])
        self.ns["send_feed"].assert_not_awaited()
        result = await self.plugin.handle_send_feed_tool("topic", "unrelated nickname", user_id="owner")
        self.assertTrue(result[0])
        self.ns["send_feed"].assert_awaited_once_with("topic")

    async def test_diary_image_failure_prevents_publish(self):
        qzone = SimpleNamespace(publish_emotion=AsyncMock(return_value="fid"))
        self.ns["create_qzone_api"] = lambda: qzone
        self.ns["generate_images"].return_value = []
        result = await self.plugin.send_feed_api("diary", auto_image=True)
        self.assertFalse(result["result"])
        qzone.publish_emotion.assert_not_awaited()
        self.ns["generate_images"].return_value = [b"photo"]
        result = await self.plugin.send_feed_api("diary", auto_image=True)
        self.assertTrue(result["result"])
        qzone.publish_emotion.assert_awaited_once_with(content="diary", images=[b"photo"])

    async def test_existing_api_remains_text_only_unless_requested(self):
        qzone = SimpleNamespace(publish_emotion=AsyncMock(return_value="fid"))
        self.ns["create_qzone_api"] = lambda: qzone
        self.assertTrue((await self.plugin.send_feed_api("text only"))["result"])
        self.ns["generate_images"].assert_not_awaited()
        qzone.publish_emotion.assert_awaited_once_with(content="text only", images=[])

    async def test_failed_qq_upload_never_posts_text(self):
        import os
        tree = ast.parse((Path(os.environ["QZONE_FIXTURE"]) / "maizone" / "qzone_api.py").read_text(encoding="utf-8"))
        cls = next(n for n in tree.body if isinstance(n, ast.ClassDef) and
                   any(getattr(f, "name", "") == "publish_emotion" for f in n.body))
        cls.bases = []
        cls.body = [n for n in cls.body if getattr(n, "name", "") == "publish_emotion"]
        client = unittest.mock.Mock(side_effect=AssertionError("上传失败后不应提交正文"))
        ns = {"httpx": SimpleNamespace(AsyncClient=client),
              "get_picbo_and_richval": lambda _: ("", "")}
        exec(compile(ast.fix_missing_locations(ast.Module(body=[cls], type_ignores=[])), "<qzone>", "exec"), ns)
        qzone = ns[cls.name]()
        qzone.uin = "bot"
        for upload in (None, {"invalid metadata": True}):
            qzone.upload_image = AsyncMock(return_value=upload)
            self.assertIsNone(await qzone.publish_emotion("diary", [b"image"]))
        client.assert_not_called()

    async def test_model_cannot_override_host_identity_or_session(self):
        import os
        tree = ast.parse((Path(os.environ["QZONE_FIXTURE"]) / "component_query.py").read_text(encoding="utf-8"))
        cls = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "ComponentQueryService")
        cls.bases = []
        cls.body = [n for n in cls.body if getattr(n, "name", "") in {
            "_build_tool_context_payload", "_build_tool_invocation_payload"}]
        header = ast.parse("from __future__ import annotations").body
        ns = {}
        exec(compile(ast.fix_missing_locations(ast.Module(body=header + [cls], type_ignores=[])), "<host>", "exec"), ns)
        host = ns[cls.name]
        ctx = SimpleNamespace(user_id="stranger", group_id="real-group", platform="qq",
            stream_id="real-session", session_id="real-session", metadata={})
        invocation = SimpleNamespace(arguments={"user_id": "owner", "stream_id": "fake-session", "topic": "normal"})
        entry = SimpleNamespace(invoke_method="plugin.invoke_tool")
        result = host._build_tool_invocation_payload(entry, invocation, ctx)
        self.assertEqual(result["user_id"], "stranger")
        self.assertEqual(result["stream_id"], "real-session")
        self.assertEqual(result["topic"], "normal")
        result = host._build_tool_invocation_payload(entry, invocation, None)
        self.assertNotIn("user_id", result)
        self.assertNotIn("stream_id", result)


if __name__ == "__main__":
    unittest.main()
