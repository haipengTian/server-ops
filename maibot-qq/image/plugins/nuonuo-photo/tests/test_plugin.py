from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

import importlib.util
import json
import sys

import pytest

from test_images import sample_image

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("nuonuo_photo_test", ROOT / "plugin.py", submodule_search_locations=[str(ROOT)])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


@pytest.fixture
async def plugin(tmp_path):
    value = module.NuonuoPhotoPlugin()
    config = value.build_default_config()
    config["images"]["api_key"] = "test-only-key"
    value.set_plugin_config(config)
    value._set_context(SimpleNamespace(paths=SimpleNamespace(data_dir=tmp_path),
        send=SimpleNamespace(image=AsyncMock(return_value={"sent": True, "message_id": "sent-1"}), text=AsyncMock()),
        message=SimpleNamespace(get_by_id=AsyncMock())))
    await value.on_load()
    yield value
    await value.on_unload()


async def settle(plugin):
    await plugin._task


@pytest.mark.asyncio
async def test_life_photo_requires_approved_portrait(plugin, monkeypatch):
    generate = AsyncMock(return_value=sample_image())
    monkeypatch.setattr(plugin, "_client", lambda: SimpleNamespace(generate=generate))
    result = await plugin.preview_life_photo("咖啡店看书")
    assert result["success"] is False
    generate.assert_not_awaited()
    await plugin.create_portrait()
    await settle(plugin)
    candidate = plugin.state["candidate"]
    assert not plugin.state["reference"]
    await plugin.approve_portrait(candidate)
    await plugin.preview_life_photo("咖啡店看书")
    await settle(plugin)
    assert generate.call_args.kwargs["reference"] == sample_image()
    assert plugin.state["reference"] == candidate
    assert plugin.state["job"]["output"] != candidate
    assert plugin.state["job"]["reference"] == candidate


@pytest.mark.asyncio
async def test_dedup_survives_restart_and_send_failure_does_not_regenerate(plugin, monkeypatch):
    generate = AsyncMock(return_value=sample_image())
    monkeypatch.setattr(plugin, "_client", lambda: SimpleNamespace(generate=generate))
    await plugin.create_portrait()
    await settle(plugin)
    await plugin.approve_portrait(plugin.state["candidate"])
    plugin.ctx.send.image.return_value = {"sent": False, "message_id": None}
    await plugin._begin("life", "公园散步", "chat-1", "request-1")
    await settle(plugin)
    assert plugin.state["job"]["status"] == "generated_unsent"
    count = generate.await_count
    result = await plugin._begin("life", "公园散步", "chat-1", "request-1")
    assert result["success"] is True
    assert generate.await_count == count
    await plugin.on_load()
    await plugin._begin("life", "公园散步", "chat-1", "request-1")
    assert generate.await_count == count
    assert plugin.ctx.send.image.await_count == 1


@pytest.mark.asyncio
async def test_tool_rejects_cross_chat_message_and_ordinary_conversation(plugin):
    plugin.ctx.message.get_by_id.return_value = {"session_id": "different-chat", "processed_plain_text": "发张自拍"}
    assert (await plugin.life_photo("自拍", "message-1", stream_id="chat-1"))["success"] is False
    plugin.ctx.message.get_by_id.return_value = {"session_id": "chat-1", "processed_plain_text": "今天吃什么？"}
    assert (await plugin.life_photo("吃饭", "message-1", stream_id="chat-1"))["success"] is False
    assert plugin._task is None


@pytest.mark.parametrize("text", ["不要发照片", "不用拍自拍", "再来一张表情包", "再来一张"])
@pytest.mark.asyncio
async def test_tool_rejects_negation_and_ambiguous_repeat(plugin, text):
    plugin.ctx.message.get_by_id.return_value = {"session_id": "chat-1", "processed_plain_text": text}
    plugin._begin = AsyncMock()
    assert (await plugin.life_photo("公园", "message-1", stream_id="chat-1"))["success"] is False
    plugin._begin.assert_not_awaited()


@pytest.mark.asyncio
async def test_stale_approval_cannot_replace_reference(plugin, monkeypatch):
    monkeypatch.setattr(plugin, "_client", lambda: SimpleNamespace(generate=AsyncMock(return_value=sample_image())))
    await plugin.create_portrait()
    await settle(plugin)
    previous = plugin.state["candidate"]
    await plugin.create_portrait()
    await settle(plugin)
    with pytest.raises(ValueError, match="候选肖像已变化"):
        await plugin.approve_portrait(previous)
    assert plugin.state["reference"] == ""


@pytest.mark.asyncio
async def test_interrupted_job_is_not_retried(plugin):
    plugin.state["job"] = {"status": "running"}
    await plugin._save()
    await plugin.on_load()
    assert plugin.state["job"]["status"] == "interrupted"
    assert plugin._task is None


def test_plugin_manifest_webui_and_factory_match_host_contract():
    # 宿主主程序源码只用于验证声明，不导入或修改生产配置。
    host = ROOT.parents[2] / "app"
    sys.path.insert(0, str(host))
    from src.plugin_runtime.runner.manifest_validator import PluginManifest
    from src.plugin_runtime.runner.plugin_loader import PluginLoader
    from src.plugin_runtime.webui_schema import WebUIExtension

    manifest = PluginManifest.model_validate(json.loads((ROOT / "_manifest.json").read_text(encoding="utf-8")))
    extension = WebUIExtension.model_validate(json.loads((ROOT / "webui.json").read_text(encoding="utf-8")))
    PluginLoader._validate_sdk_plugin_contract(manifest.id, module.create_plugin())
    assert extension.pages[0].id == "studio"
