from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

import importlib.util
import json
import sys
import os

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
        llm=SimpleNamespace(generate=AsyncMock(return_value={"success": True, "response": '{"kind":"none","scene":""}'})),
        message=SimpleNamespace(get_by_id=AsyncMock(), get_recent=AsyncMock(return_value=[]))))
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
    plugin.ctx.message.get_by_id.return_value = request("今天吃什么？")
    assert (await plugin.life_photo("吃饭", "message-1", stream_id="chat-1"))["success"] is False
    plugin.ctx.llm.generate.assert_awaited_once()
    assert plugin._task is None


@pytest.mark.parametrize("text", ["不要发照片", "不用拍自拍", "再来一张表情包", "再来一张"])
@pytest.mark.asyncio
async def test_tool_rejects_negation_and_ambiguous_repeat(plugin, text):
    plugin.ctx.message.get_by_id.return_value = request(text)
    plugin._begin = AsyncMock()
    assert (await plugin.life_photo("公园", "message-1", stream_id="chat-1"))["success"] is False
    plugin._begin.assert_not_awaited()
    plugin.ctx.llm.generate.assert_awaited_once()


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
    host = Path(os.environ.get("MAIBOT_APP_ROOT", str(ROOT.parents[2] / "app")))
    sys.path.insert(0, str(host))
    from src.plugin_runtime.runner.manifest_validator import PluginManifest
    from src.plugin_runtime.runner.plugin_loader import PluginLoader
    from src.plugin_runtime.webui_schema import WebUIExtension

    manifest = PluginManifest.model_validate(json.loads((ROOT / "_manifest.json").read_text(encoding="utf-8")))
    extension = WebUIExtension.model_validate(json.loads((ROOT / "webui.json").read_text(encoding="utf-8")))
    PluginLoader._validate_sdk_plugin_contract(manifest.id, module.create_plugin())
    assert extension.pages[0].id == "studio"


def request(text, sender="user-1", chat="chat-1"):
    return {"session_id": chat, "message_id": "req-1", "account_id": "bot-1", "timestamp": "100.0",
            "message_info": {"user_info": {"user_id": sender}}, "processed_plain_text": text}


@pytest.mark.asyncio
async def test_semantic_request_accepts_group_photo_without_keyword_gate(plugin):
    plugin.ctx.message.get_by_id.return_value = request("发一张你和米切尔的合照")
    plugin.ctx.llm.generate.return_value = {"success": True, "response": json.dumps({"kind": "life", "scene": "糯糯和米切尔在球馆合影"})}
    plugin._begin = AsyncMock(return_value={"success": True})
    assert (await plugin.life_photo("合影", "req-1", stream_id="chat-1", user_id="user-1"))["success"]
    plugin.ctx.llm.generate.assert_awaited_once()
    assert plugin._begin.call_args.args == ("life", "糯糯和米切尔在球馆合影", "chat-1", "req-1")


@pytest.mark.asyncio
async def test_general_drawing_uses_no_character_reference_or_portrait_style(plugin, monkeypatch):
    plugin.state["reference"] = "existing-portrait.jpg"
    (plugin.data_dir / "existing-portrait.jpg").write_bytes(sample_image())
    generate = AsyncMock(return_value=sample_image())
    monkeypatch.setattr(plugin, "_client", lambda: SimpleNamespace(generate=generate))
    plugin.ctx.message.get_by_id.return_value = request("画一只水彩风格的小猫，写上你好")
    plugin.ctx.llm.generate.return_value = {"success": True, "response": '{"kind":"general","scene":"水彩小猫，文字：你好"}'}
    assert (await plugin.generate_image("小猫", "req-1", stream_id="chat-1", user_id="user-1"))["success"]
    await settle(plugin)
    assert generate.call_args.kwargs["reference"] is None
    assert generate.call_args.args[0] == "水彩小猫，文字：你好"
    assert plugin.state["job"]["kind"] == "general"
    assert plugin.state["reference"] == "existing-portrait.jpg"
    assert plugin.state["job"]["sent"]
    assert plugin.state["job"]["reference"] == ""


@pytest.mark.asyncio
async def test_general_drawing_works_before_portrait_is_set(plugin, monkeypatch):
    generate = AsyncMock(return_value=sample_image())
    monkeypatch.setattr(plugin, "_client", lambda: SimpleNamespace(generate=generate))
    assert (await plugin.preview_image("油画风格的海边"))["success"]
    await settle(plugin)
    assert generate.call_args.kwargs["reference"] is None
    assert not plugin.state["reference"]


@pytest.mark.asyncio
async def test_semantic_route_uses_original_request_and_context_not_tool_scene(plugin):
    plugin.ctx.message.get_by_id.return_value = request("换成夜景再来一张")
    plugin.ctx.message.get_recent.return_value = [
        {**request("发张你在海边的照片"), "message_id": "req-0", "timestamp": "99.0"},
        {**request("后来不要了"), "message_id": "req-2", "timestamp": "101.0"}]
    plugin.ctx.llm.generate.return_value = {"success": True, "response": '{"kind":"life","scene":"糯糯在海边的夜景照片"}'}
    plugin._begin = AsyncMock(return_value={"success": True})
    assert (await plugin.generate_image("a misleading drawing hint", "req-1", stream_id="chat-1"))["success"]
    payload = json.loads(plugin.ctx.llm.generate.call_args.kwargs["prompt"][1]["content"])
    assert payload["request"] == "换成夜景再来一张"
    assert payload["context"][0]["text"] == "发张你在海边的照片"
    assert "后来不要了" not in json.dumps(payload["context"], ensure_ascii=False)
    assert plugin._begin.call_args.args[0] == "life"


@pytest.mark.parametrize("response", ["not JSON", '{"kind":"other","scene":"猫"}', '{"kind":"general","scene":""}'])
@pytest.mark.asyncio
async def test_invalid_semantic_result_does_not_start_paid_generation(plugin, response):
    plugin.ctx.message.get_by_id.return_value = request("画只猫")
    plugin.ctx.llm.generate.return_value = {"success": True, "response": response}
    plugin._begin = AsyncMock()
    assert not (await plugin.life_photo("猫", "req-1", stream_id="chat-1"))["success"]
    plugin._begin.assert_not_awaited()


@pytest.mark.asyncio
async def test_wrong_sender_and_bot_messages_never_reach_semantic_model(plugin):
    for sender in ("someone-else", "bot-1", ""):
        plugin.ctx.message.get_by_id.return_value = request("画只猫", sender=sender)
        assert not (await plugin.life_photo("猫", "req-1", stream_id="chat-1", user_id="user-1"))["success"]
    plugin.ctx.llm.generate.assert_not_awaited()


@pytest.mark.asyncio
async def test_both_tools_share_persistent_request_dedup_before_classification(plugin):
    plugin.ctx.message.get_by_id.return_value = request("画只猫")
    plugin.state["requests"]["chat-1:req-1"] = "existing-job"
    for tool in (plugin.generate_image, plugin.life_photo):
        assert (await tool("猫", "req-1", stream_id="chat-1"))["success"]
    plugin.ctx.llm.generate.assert_not_awaited()
    assert plugin._task is None


@pytest.mark.asyncio
async def test_semantic_service_failure_never_starts_image_request(plugin):
    plugin.ctx.message.get_by_id.return_value = request("画只猫")
    plugin.ctx.llm.generate.side_effect = RuntimeError("private service error")
    plugin._begin = AsyncMock()
    result = await plugin.generate_image("猫", "req-1", stream_id="chat-1")
    assert not result["success"]
    assert "private" not in result["error"]
    plugin._begin.assert_not_awaited()


@pytest.mark.asyncio
async def test_real_sdk_unwraps_host_messages_before_semantic_routing(plugin):
    from maibot_sdk.context import PluginContext
    context = PluginContext("haipengtian.nuonuo-photo", paths=plugin.ctx.paths)
    original = request("换成夜景再来一张")
    prompts = []

    async def host(method, *, payload, **kwargs):
        capability = payload["capability"]
        if capability == "message.get_by_id":
            return {"success": True, "message": original}
        if capability == "message.get_recent":
            return {"success": True, "messages": [
                {**request("发张你在海边的照片"), "message_id": "req-0", "timestamp": "99"},
                {**request("未来的消息"), "message_id": "req-2", "timestamp": "101"}]}
        if capability == "llm.generate":
            prompts.append(payload["args"]["prompt"])
            return {"success": True, "response": '{"kind":"life","scene":"糯糯在海边的夜景照片"}'}
        raise AssertionError(capability)

    context.call_host_method = AsyncMock(side_effect=host)
    plugin._set_context(context)
    plugin._begin = AsyncMock(return_value={"success": True})
    assert (await plugin.generate_image("夜景", "req-1", stream_id="chat-1"))["success"]
    payload = json.loads(prompts[0][1]["content"])
    assert [item["text"] for item in payload["context"]] == ["发张你在海边的照片"]
    plugin._begin.assert_awaited_once_with("life", "糯糯在海边的夜景照片", "chat-1", "req-1")


@pytest.mark.asyncio
async def test_failure_reaches_chat_history_and_new_request_can_generate(plugin, monkeypatch):
    generate = AsyncMock(side_effect=module.ImageError("图片接口返回 HTTP 400：内容审核拒绝。"))
    monkeypatch.setattr(plugin, "_client", lambda: SimpleNamespace(generate=generate))
    await plugin._begin("general", "日落", "chat-1", "req-1")
    await settle(plugin)
    assert plugin.ctx.send.text.call_args.kwargs["sync_to_maisaka_history"] is True
    status = await plugin.image_status(stream_id="chat-1")
    assert status["status"] == "failed"
    assert "400" in status["error"]
    assert status["can_generate"] is True
    duplicate = await plugin._begin("general", "日落", "chat-1", "req-1")
    assert duplicate["status"] == "failed"
    assert generate.await_count == 1
    generate.side_effect = None
    generate.return_value = sample_image()
    assert (await plugin._begin("general", "重新画日落", "chat-1", "req-2"))["success"]
    await settle(plugin)
    assert (await plugin.image_status(stream_id="chat-1"))["status"] == "completed"
    assert plugin.ctx.send.image.call_args.kwargs["sync_to_maisaka_history"] is True
    assert generate.await_count == 2


@pytest.mark.asyncio
async def test_status_is_scoped_to_chat_and_survives_restart(plugin, monkeypatch):
    monkeypatch.setattr(plugin, "_client", lambda: SimpleNamespace(generate=AsyncMock(return_value=sample_image())))
    await plugin._begin("general", "chat one private scene", "chat-1", "req-1")
    await settle(plugin)
    await plugin._begin("general", "chat two private scene", "chat-2", "req-2")
    await settle(plugin)
    await plugin.on_load()
    first = await plugin.image_status(stream_id="chat-1")
    assert first["status"] == "completed"
    assert first["job_id"] == plugin.state["requests"]["chat-1:req-1"]
    missing = await plugin.image_status(stream_id="chat-3")
    assert missing["status"] == "not_found"
    assert "private scene" not in json.dumps(missing)


@pytest.mark.asyncio
async def test_running_status_prevents_second_request_but_terminal_state_does_not(plugin, monkeypatch):
    import asyncio
    gate = asyncio.Event()
    async def generate(*args, **kwargs):
        await gate.wait()
        return sample_image()
    monkeypatch.setattr(plugin, "_client", lambda: SimpleNamespace(generate=generate))
    await plugin._begin("general", "猫", "chat-1", "req-1")
    status = await plugin.image_status(stream_id="chat-1")
    assert status["status"] == "running"
    assert not status["can_generate"]
    assert not (await plugin._begin("general", "猫", "chat-1", "req-2"))["success"]
    gate.set()
    await settle(plugin)
    assert (await plugin.image_status(stream_id="chat-1"))["can_generate"]


@pytest.mark.asyncio
async def test_legacy_failed_job_can_be_queried_without_changing_portrait(plugin):
    plugin.state.update(reference="", job={"id": "old-job", "status": "failed", "error": "HTTP 400"},
                        requests={"chat-1:old-request": "old-job"})
    await plugin._save()
    await plugin.on_load()
    result = await plugin.image_status(stream_id="chat-1")
    assert result["status"] == "failed"
    assert result["can_generate"]
    assert (await plugin.image_status(stream_id="chat-2"))["status"] == "not_found"


@pytest.mark.asyncio
async def test_explicit_regeneration_has_previous_scene_even_after_many_chat_messages(plugin):
    plugin.state["jobs"] = {
        "other": {"id": "other", "stream_id": "chat-2", "scene": "other private scene", "kind": "life"},
        "failed": {"id": "failed", "stream_id": "chat-1", "scene": "糯糯在酒吧喝酒", "kind": "life", "status": "failed"}}
    plugin.ctx.message.get_by_id.return_value = request("我让你重新生成呢")
    plugin.ctx.llm.generate.return_value = {"success": True, "response": '{"kind":"life","scene":"糯糯在酒吧喝酒"}'}
    plugin._begin = AsyncMock(return_value={"success": True})
    await plugin.life_photo("重新生成", "req-1", stream_id="chat-1")
    payload = json.loads(plugin.ctx.llm.generate.call_args.kwargs["prompt"][1]["content"])
    assert payload["previous_image"] == {"kind": "life", "scene": "糯糯在酒吧喝酒"}
    assert "other private scene" not in json.dumps(payload, ensure_ascii=False)


@pytest.mark.asyncio
async def test_unexpected_failure_is_notified_and_notification_failure_is_queryable(plugin, monkeypatch):
    monkeypatch.setattr(plugin, "_client", lambda: SimpleNamespace(generate=AsyncMock(side_effect=RuntimeError("private details"))))
    plugin.ctx.send.text.side_effect = RuntimeError("notification unavailable")
    await plugin._begin("general", "猫", "chat-1", "req-1")
    await settle(plugin)
    plugin.ctx.send.text.assert_awaited_once()
    assert plugin.state["job"]["failure_notified"] is False
    status = await plugin.image_status(stream_id="chat-1")
    assert status["status"] == "failed"
    assert "private details" not in json.dumps(status)
