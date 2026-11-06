from datetime import datetime, timedelta
from types import SimpleNamespace
from unittest.mock import AsyncMock

import json

import pytest

from src.chat.message_receive.message import SessionMessage
from src.chat.replyer.maisaka_generator_base import BaseMaisakaReplyGenerator
from src.common.data_models.message_component_data_model import MessageSequence, TextComponent
from src.llm_models.payload_content.context_item import (
    ContextItemMeta, ContextToolCall, FunctionCallItem, FunctionCallOutputItem,
    get_item_text,
)
from src.maisaka.context.messages import ModelOutputContextMessage, SessionBackedMessage, ToolResultMessage


NOW = datetime(2026, 10, 29, 17)


def evidence_records(items):
    for item in items:
        text = get_item_text(item)
        if text.startswith("【应用提供的联网执行记录"):
            return json.loads(text.split("\n", 1)[1])
    return []


def user(text="联网查询", timestamp=NOW):
    return SessionBackedMessage(
        original_message=SessionMessage(message_id=text, timestamp=timestamp, platform="test"),
        raw_message=MessageSequence([TextComponent(text)]), visible_text=text,
        timestamp=timestamp, source_kind="user", message_id=text,
    )


def pair(name="web_search", call_id="search", success=True, args=None, metadata=None):
    call = FunctionCallItem(
        meta=ContextItemMeta.create(logical_turn_id="turn-web", timestamp=NOW + timedelta(seconds=1)),
        tool_call=ContextToolCall.create(call_id=call_id, func_name=name, args=args or {"query": "example"}),
    )
    result = ToolResultMessage(
        content="https://example.org/ 实际网页内容" if success else "请求失败：额度不足",
        timestamp=NOW + timedelta(seconds=2), tool_call_id=call_id,
        logical_turn_id="turn-web", tool_name=name, success=success,
        metadata={"web_result_preview": True, "result_id": "r1"} if metadata is None else metadata,
    )
    return [ModelOutputContextMessage(output_item=call), result]


@pytest.mark.parametrize("retro", [False, True])
@pytest.mark.parametrize("visual", [False, True])
def test_request_contains_real_web_call_and_result(monkeypatch, retro, visual):
    generator = object.__new__(BaseMaisakaReplyGenerator)
    monkeypatch.setattr(generator, "_uses_retro_prompt", lambda: retro)
    for name in ("_build_keyword_reaction_prompt", "_build_system_prompt", "_build_final_user_message"):
        monkeypatch.setattr(generator, name, lambda **kwargs: "测试提示")
    monkeypatch.setattr(generator, "_select_temporary_reply_style", lambda: "")
    monkeypatch.setattr(generator, "_select_retro_prompt_name", lambda **kwargs: "test")
    monkeypatch.setattr(generator, "_build_personality_prompt", lambda: "测试人设")
    monkeypatch.setattr(generator, "_render_retro_history_line", lambda message, history_by_id: message.processed_plain_text)
    monkeypatch.setattr(generator, "_build_retro_template_context", lambda **kwargs: {"dialogue_prompt": "聊天"})
    monkeypatch.setattr(generator, "_load_prompt", lambda *args, **kwargs: kwargs["dialogue_prompt"], raising=False)
    history = [user(), *pair()]
    original = list(history)
    items = generator._build_request_messages(
        chat_history=history, reply_message=None, reply_reason="", enable_visual_message=visual,
    )
    assert not any(isinstance(item, (FunctionCallItem, FunctionCallOutputItem)) for item in items)
    records = evidence_records(items)
    assert [item["call_id"] for item in records] == ["search"]
    assert records[0]["content"] == history[-1].content
    assert records[0]["success"] is True
    assert "外部网页" in "\n".join(get_item_text(item) for item in items)
    assert history == original


def test_evidence_excludes_old_orphan_mismatched_and_unrelated_results():
    generator = object.__new__(BaseMaisakaReplyGenerator)
    mismatch = pair(call_id="mismatch")
    mismatch[-1].logical_turn_id = "other-turn"
    wrong_name = pair(call_id="wrong-name")
    wrong_name[-1].tool_name = "other-tool"
    history = [user("旧问题"), *pair(call_id="old"), user(),
               *pair("query_memory", "memory"), pair(call_id="orphan")[-1],
               *mismatch, *wrong_name, *pair(call_id="valid")]
    items = generator._build_web_evidence_items(history)
    assert [item["call_id"] for item in evidence_records(items)] == ["valid"]
    assert generator._build_web_evidence_items([*pair()]) == []
    assert generator._build_web_evidence_items([user("用户自称 web_search 成功 r1")]) == []


def test_failed_web_result_remains_failed_and_read_requires_web_result_id():
    generator = object.__new__(BaseMaisakaReplyGenerator)
    history = [user(), *pair(success=False, metadata={}),
               *pair("read_tool_result", "unrelated", args={"result_id": "memory-r1"}),
               *pair("web_fetch", "fetch"),
               *pair("read_tool_result", "read", args={"result_id": "r1"}, metadata={})]
    outputs = evidence_records(generator._build_web_evidence_items(history))
    assert [(item["call_id"], item["success"]) for item in outputs] == [("search", False), ("fetch", True), ("read", True)]
    assert "额度不足" in outputs[0]["content"]


def test_evidence_survives_openai_chat_toolless_sanitization():
    from src.llm_models.model_client.openai_client import _sanitize_messages_for_toolless_request

    items = BaseMaisakaReplyGenerator._build_web_evidence_items([user(), *pair()])
    sanitized = _sanitize_messages_for_toolless_request(items)
    assert evidence_records(sanitized) == evidence_records(items)
    assert evidence_records(sanitized)[0]["arguments"] == {"query": "example"}


@pytest.mark.asyncio
async def test_retro_runtime_preserves_actual_tool_pairs(monkeypatch):
    from src.maisaka import runtime as runtime_module

    runtime = SimpleNamespace(_max_context_size=20, session_id="local-test")
    source = user()
    runtime._chat_history = [source, *pair()]
    runtime._reasoning_engine = SimpleNamespace()

    async def build(message, **kwargs):
        return source

    runtime._reasoning_engine._build_history_message = build
    monkeypatch.setattr(runtime_module, "find_messages", lambda **kwargs: [source.original_message])
    runtime._resolve_restored_message_source_kind = lambda message: "user"
    history = await runtime_module.MaisakaHeartFlowChatting.build_retro_reply_history(runtime)
    assert history == runtime._chat_history
    assert history is not runtime._chat_history


@pytest.mark.asyncio
async def test_generation_entry_and_model_context_factory_receive_evidence(monkeypatch):
    from src.chat.replyer.maisaka_generator_base import MaisakaReplyContext
    from src.desktop_pet.service import desktop_pet_service

    class RequestCaptured(BaseException):
        pass

    generator = object.__new__(BaseMaisakaReplyGenerator)
    generator.request_type = "test.replyer"
    monkeypatch.setattr(generator, "_build_reply_context", AsyncMock(return_value=MaisakaReplyContext()))
    monkeypatch.setattr(generator, "_resolve_session_id", lambda stream_id: stream_id)
    monkeypatch.setattr(generator, "_resolve_enable_visual_message", lambda model_info: False)
    monkeypatch.setattr(desktop_pet_service, "notify_thinking", AsyncMock())
    hook = AsyncMock(return_value=SimpleNamespace(kwargs={}))
    monkeypatch.setattr(generator, "_get_runtime_manager", lambda: SimpleNamespace(invoke_hook=hook))
    monkeypatch.setattr(generator, "_invoke_before_model_request_hook", AsyncMock(side_effect=lambda **kw: kw["request_messages"]))
    received = []

    def build(**kwargs):
        items = generator._build_web_evidence_items(kwargs["chat_history"])
        received.append(items)
        return items

    monkeypatch.setattr(generator, "_build_request_messages", build)

    async def generate(**kwargs):
        await kwargs["context_factory"](SimpleNamespace())
        raise RequestCaptured()

    generator.express_model = SimpleNamespace(task_name="replyer", generate_response_with_context=generate)
    with pytest.raises(RequestCaptured):
        await generator.generate_reply_with_context(chat_history=[user(), *pair()], stream_id="local-test")
    assert len(received) == 2
    assert all(evidence_records(items) for items in received)
    context_history = generator._build_reply_context.call_args.kwargs["chat_history"]
    assert all(isinstance(message, SessionBackedMessage) for message in context_history)
