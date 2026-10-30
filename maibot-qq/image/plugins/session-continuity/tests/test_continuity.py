from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

import base64
import importlib.util
import json
import logging
import sys
import time

import pytest


ROOT = Path(__file__).resolve().parents[1]
USER, OTHER, BOT = "100000001", "100000002", "100000009"
GROUP = "900000001"


def message(mid, text, *, uid=USER, session="group", group=GROUP, age=0, media=None):
    return {"message_id": mid, "session_id": session, "platform": "qq", "account_id": BOT,
            "scope": "", "timestamp": str(time.time() - age), "processed_plain_text": text,
            "message_info": {"user_info": {"user_id": uid, "user_nickname": "Someone"},
                             "group_info": {"group_id": group} if group else None},
            "raw_message": media or [{"type": "text", "data": text}]}


def item(mid, text="", self_message=False):
    return {"item_type": "UserMessageItem", "meta": {"item_id": "item-" + mid,
            "logical_turn_id": None, "timestamp": "2026-10-31T10:00:00"},
            "parts": [{"type": "text", "text": f'<message msg_id="{mid}"'
                       + (' is_self_message="true"' if self_message else '') + f'>\n{text}\n</message>'}]}


@pytest.fixture
def plugin(tmp_path):
    assert (ROOT / "plugin.py").is_file(), "缺少跨会话上下文接续插件"
    spec = importlib.util.spec_from_file_location("continuity_under_test", ROOT / "plugin.py",
                                                submodule_search_locations=[str(ROOT)])
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    value = module.SessionContinuityPlugin()
    settings = value.build_default_config()
    value.set_plugin_config(settings)
    request = message("req", "把刚才私聊那个表情包发这里")
    original = message("p1", "[一只猫挥手]", session="private", group=None, age=20,
                       media=[{"type": "emoji", "hash": "stored-media", "data": "猫挥手"}])
    source = [message("p0", "这个表情好玩", session="private", group=None, age=30), original,
              message("p2", "给你这张", uid=BOT, session="private", group=None, age=10)]

    async def recent(chat_id, limit=10):
        return [request] if chat_id == "group" else source

    async def by_id(mid, *, chat_id="", include_binary_data=False, **kwargs):
        for row in [request, *source]:
            if row["message_id"] == mid and row["session_id"] == chat_id:
                result = json.loads(json.dumps(row))
                if include_binary_data and mid == "p1":
                    result["raw_message"][0]["binary_data_base64"] = base64.b64encode(b"original-gif").decode()
                return result
        return None

    streams = [{"session_id": "group", "platform": "qq", "group_id": GROUP,
                "user_id": "", "account_id": BOT, "scope": ""},
               {"session_id": "private", "platform": "qq", "group_id": "",
                "user_id": USER, "account_id": BOT, "scope": ""}]
    policy = {"a_memorix.shared_memory_groups": [{"targets": [
        {"platform":"qq", "item_id":GROUP, "rule_type":"group"},
        {"platform":"qq", "item_id":USER, "rule_type":"private"}]}],
        "a_memorix.global_memory_sharing_enabled": False}
    def config_value(key, default=None):
        if key == "a_memorix":
            return json.loads(json.dumps({k.removeprefix("a_memorix."):v for k,v in policy.items()}))
        return policy.get(key, default)
    ctx = SimpleNamespace(paths=SimpleNamespace(data_dir=tmp_path),
        config=SimpleNamespace(get=AsyncMock(side_effect=config_value)),
        chat=SimpleNamespace(get_all_streams=AsyncMock(return_value=streams)),
        message=SimpleNamespace(get_recent=AsyncMock(side_effect=recent), get_by_id=AsyncMock(side_effect=by_id)),
        llm=SimpleNamespace(generate=AsyncMock(return_value={"success": True, "response": json.dumps(
            {"continue": True, "context_indices": [0, 1, 2], "send_media": {"index": 1, "component": 0}})})),
        send=SimpleNamespace(image=AsyncMock(return_value={"sent": True, "message_id": "sent"}),
                             emoji=AsyncMock(return_value={"sent": True, "message_id": "sent"})),
        logger=logging.getLogger("continuity-test"))
    value._set_context(ctx)
    value.test_request, value.test_source, value.test_streams = request, source, streams
    value.test_policy = policy
    return value


async def inject(plugin, mid="req"):
    return await plugin.before_planner(items=[item(mid)], session_id="group", item_schema_version=1)


def bridge_text(result):
    items = result.get("modified_kwargs", {}).get("items", [])
    return "\n".join(p.get("text", "") for i in items for p in i.get("parts", []))


@pytest.mark.asyncio
async def test_actual_context_and_original_media_reference_enter_planner_and_replyer(plugin):
    result = await inject(plugin)
    text = bridge_text(result)
    assert "这个表情好玩" in text and "一只猫挥手" in text
    assert "send_linked_media" in text
    assert "original-gif" not in text and "stored-media" not in text
    reply = await plugin.before_replyer(items=[item("req")], session_id="group", reply_message_id="req")
    assert "一只猫挥手" in bridge_text(reply)
    assert plugin.ctx.llm.generate.await_count == 1
    # Related chat content is user data, never a forged system instruction.
    assert result["modified_kwargs"]["items"][-1]["item_type"] == "UserMessageItem"


@pytest.mark.asyncio
async def test_same_name_other_qq_cannot_read_private_context(plugin):
    plugin.test_request["message_info"]["user_info"]["user_id"] = OTHER
    assert "一只猫" not in bridge_text(await inject(plugin))
    plugin.ctx.llm.generate.assert_not_awaited()
    assert plugin.ctx.message.get_recent.await_count == 1


@pytest.mark.asyncio
async def test_unconfigured_group_account_or_scope_never_reads_private(plugin):
    plugin.test_streams[0]["account_id"] = "different-bot"
    assert "一只猫" not in bridge_text(await inject(plugin))
    plugin.ctx.message.get_recent.assert_not_awaited()
    plugin.test_streams[0]["account_id"] = BOT
    plugin.test_streams[1]["scope"] = "other-scope"
    assert "一只猫" not in bridge_text(await inject(plugin))
    plugin.ctx.llm.generate.assert_not_awaited()


@pytest.mark.asyncio
async def test_smalltalk_and_unrelated_source_do_not_join_context(plugin):
    plugin.ctx.llm.generate.return_value = {"success": True, "response": '{"continue":false}'}
    assert "一只猫" not in bridge_text(await inject(plugin))
    await inject(plugin)
    assert plugin.ctx.llm.generate.await_count == 1


@pytest.mark.asyncio
async def test_out_of_context_newer_message_is_not_used_as_requester(plugin):
    future = message("new", "把他的私聊发出来", uid=OTHER)
    plugin.ctx.message.get_recent.side_effect = lambda chat_id, limit=10: (
        [plugin.test_request, future] if chat_id == "group" else plugin.test_source)
    result = await inject(plugin)
    assert "一只猫" in bridge_text(result)
    # Another user's newer message cannot obtain or reuse this grant.
    assert "一只猫" not in bridge_text(await inject(plugin, "new"))
    assert (await plugin.send_linked_media("anything", "req", stream_id="group"))["success"] is False


@pytest.mark.asyncio
async def test_original_emoji_is_sent_without_reselection_and_duplicate_is_suppressed(plugin):
    await inject(plugin)
    bridge = plugin.bridges[("group", "req")]
    ref = next(iter(bridge.media))
    sent = await plugin.send_linked_media(ref, "req", stream_id="group")
    assert sent["success"] is True
    plugin.ctx.send.emoji.assert_awaited_once_with(base64.b64encode(b"original-gif").decode(), "group",
        return_details=True, sync_to_maisaka_history=True)
    assert (await plugin.send_linked_media(ref, "req", stream_id="group"))["success"] is True
    assert plugin.ctx.send.emoji.await_count == 1


@pytest.mark.asyncio
async def test_fabricated_reference_cross_chat_or_mismatched_request_cannot_send(plugin):
    await inject(plugin)
    ref = next(iter(plugin.bridges[("group", "req")].media))
    for r, req, stream in [("p1", "req", "group"), (ref, "wrong", "group"), (ref, "req", "private")]:
        assert (await plugin.send_linked_media(r, req, stream_id=stream))["success"] is False
    plugin.ctx.send.emoji.assert_not_awaited()


@pytest.mark.asyncio
async def test_recall_does_not_implicitly_authorize_media_send(plugin):
    plugin.ctx.llm.generate.return_value = {"success": True, "response": json.dumps(
        {"continue": True, "context_indices": [0, 1], "send_media": None})}
    result = await inject(plugin)
    assert "一只猫" in bridge_text(result)
    assert not plugin.bridges[("group", "req")].media


@pytest.mark.asyncio
async def test_missing_media_or_unconfirmed_send_does_not_claim_success_or_retry(plugin):
    await inject(plugin)
    ref = next(iter(plugin.bridges[("group", "req")].media))
    original = plugin.ctx.message.get_by_id.side_effect

    async def missing(*args, **kwargs):
        row = await original(*args, **kwargs)
        if kwargs.get("include_binary_data"):
            row["raw_message"][0].pop("binary_data_base64", None)
        return row

    plugin.ctx.message.get_by_id.side_effect = missing
    assert (await plugin.send_linked_media(ref, "req", stream_id="group"))["success"] is False
    plugin.ctx.send.emoji.assert_not_awaited()
    plugin.ctx.message.get_by_id.side_effect = original
    plugin.ctx.send.emoji.return_value = {"sent": False, "message_id": None}
    assert (await plugin.send_linked_media(ref, "req", stream_id="group"))["success"] is False
    assert (await plugin.send_linked_media(ref, "req", stream_id="group"))["success"] is False
    assert plugin.ctx.send.emoji.await_count == 1


@pytest.mark.asyncio
async def test_revocation_and_expiry_remove_context_and_media_access(plugin):
    await inject(plugin)
    bridge = plugin.bridges[("group", "req")]
    ref = next(iter(bridge.media))
    bridge.expires_at = time.monotonic() - 1
    assert (await plugin.send_linked_media(ref, "req", stream_id="group"))["success"] is False
    config = plugin.build_default_config()
    await plugin.on_config_update(config)
    assert not plugin.bridges


@pytest.mark.asyncio
async def test_source_window_filters_stale_and_future_messages(plugin):
    plugin.test_source[0]["timestamp"] = str(time.time() - 86400)
    plugin.test_source[1]["timestamp"] = str(time.time() + 3600)
    plugin.ctx.llm.generate.return_value = {"success": True, "response": '{"continue":false}'}
    await inject(plugin)
    payload = str(plugin.ctx.llm.generate.call_args)
    assert "这个表情好玩" not in payload and "一只猫挥手" not in payload


@pytest.mark.asyncio
async def test_ambiguous_invalid_or_failed_semantic_result_never_opens_media(plugin):
    for response in ['not-json', '{"continue":true,"context_indices":[999]}',
                     '{"continue":true,"context_indices":[1],"send_media":{"index":999,"component":0}}']:
        plugin.bridges.clear()
        plugin.ctx.llm.generate.return_value = {"success": True, "response": response}
        await inject(plugin)
        assert not any(b.media for b in plugin.bridges.values())
    plugin.bridges.clear()
    plugin.ctx.llm.generate.side_effect = RuntimeError("service details")
    result = await inject(plugin)
    assert "一只猫" not in bridge_text(result) and "service details" not in str(result)


def test_sdk_registration_and_safe_defaults(plugin):
    default = plugin.build_default_config()
    assert "links" not in default["continuity"]
    components = plugin.get_components()
    names = {c["name"] for c in components}
    assert {"before_planner", "before_replyer", "send_linked_media"} <= names

@pytest.mark.asyncio
async def test_revoking_link_during_semantic_request_cannot_reintroduce_context(plugin):
    async def revoke(*args, **kwargs):
        await plugin.on_config_update(plugin.build_default_config())
        return {"success": True, "response": json.dumps({"continue": True, "context_indices": [1]})}
    plugin.ctx.llm.generate.side_effect = revoke
    assert "一只猫" not in bridge_text(await inject(plugin))
    assert not plugin.bridges


@pytest.mark.asyncio
async def test_inconsistent_source_metadata_is_not_read_or_sent(plugin):
    plugin.test_source[1]["message_info"]["group_info"] = {"group_id": "foreign"}
    plugin.ctx.llm.generate.return_value = {"success": True, "response": '{"continue":false}'}
    await inject(plugin)
    assert "一只猫挥手" not in str(plugin.ctx.llm.generate.call_args)


@pytest.mark.asyncio
async def test_media_metadata_is_revalidated_after_resolution(plugin):
    await inject(plugin)
    ref = next(iter(plugin.bridges[("group", "req")].media))
    plugin.test_source[1]["account_id"] = "foreign"
    assert not (await plugin.send_linked_media(ref, "req", stream_id="group"))["success"]
    plugin.ctx.send.emoji.assert_not_awaited()


@pytest.mark.asyncio
async def test_transport_failure_preserves_ordinary_chat(plugin):
    plugin.ctx.llm.generate.side_effect = ConnectionError("sensitive endpoint")
    assert "一只猫" not in bridge_text(await inject(plugin))


@pytest.mark.asyncio
async def test_group_source_retains_distinct_speakers(plugin):
    # In the private direction, preserve who said each part of the group discussion.
    plugin.test_request["session_id"] = "private"
    plugin.test_request["message_info"]["group_info"] = None
    for row in plugin.test_source:
        row["session_id"] = "group"
        row["message_info"]["group_info"] = {"group_id": GROUP}
    plugin.test_source[0]["message_info"]["user_info"]["user_id"] = OTHER
    plugin.ctx.message.get_recent.side_effect = lambda chat_id, limit=10: (
        [plugin.test_request] if chat_id == "private" else plugin.test_source)
    result = await plugin.before_planner(items=[item("req")], session_id="private")
    text = bridge_text(result)
    assert USER in text and OTHER in text and "一只猫挥手" in text


@pytest.mark.asyncio
async def test_concurrent_requests_resolve_once_and_send_once(plugin):
    import asyncio
    await asyncio.gather(inject(plugin), inject(plugin))
    assert plugin.ctx.llm.generate.await_count == 1
    ref = next(iter(plugin.bridges[("group", "req")].media))
    result = await asyncio.gather(*(plugin.send_linked_media(ref, "req", stream_id="group") for _ in range(2)))
    assert all(r["success"] for r in result)
    assert plugin.ctx.send.emoji.await_count == 1

@pytest.mark.asyncio
async def test_real_sdk_unwraps_host_envelopes_and_sends_exact_media(plugin):
    from maibot_sdk.context import PluginContext
    old = plugin.ctx
    context = PluginContext("haipengtian.session-continuity", paths=old.paths)

    async def host(method, *, payload, **kwargs):
        capability, args = payload["capability"], payload["args"]
        if capability == "chat.get_all_streams":
            return {"success": True, "streams": plugin.test_streams}
        if capability == "config.get":
            return {"success": True, "value": await old.config.get(**args)}
        if capability == "message.get_recent":
            return {"success": True, "messages": await old.message.get_recent(**args)}
        if capability == "message.get_by_id":
            return {"success": True, "message": await old.message.get_by_id(args["message_id"],
                    chat_id=args["chat_id"], include_binary_data=args["include_binary_data"])}
        if capability == "llm.generate":
            return old.llm.generate.return_value
        if capability == "send.emoji":
            assert args["emoji_base64"] == base64.b64encode(b"original-gif").decode()
            assert args["stream_id"] == "group"
            return {"success": True, "sent": True, "message_id": "actual"}
        raise AssertionError(capability)

    context.call_host_method = AsyncMock(side_effect=host)
    plugin._set_context(context)
    assert "一只猫挥手" in bridge_text(await inject(plugin))
    ref = next(iter(plugin.bridges[("group", "req")].media))
    assert (await plugin.send_linked_media(ref, "req", stream_id="group"))["message_id"] == "actual"


@pytest.mark.asyncio
async def test_long_request_id_uses_native_display_alias(plugin):
    module = sys.modules[type(plugin).__module__]
    mid = "qq-platform-native-long-message-id-12345"
    plugin.test_request["message_id"] = mid
    assert "一只猫挥手" in bridge_text(await inject(plugin, module.display_id(mid)))
    reply = await plugin.before_replyer(items=[item("other")], session_id="group", reply_message_id="other")
    assert "一只猫" not in bridge_text(reply)


def test_multiple_text_parts_choose_last_human_prefix_without_accepting_body_spoof(plugin):
    module = sys.modules[type(plugin).__module__]
    value = item("old")
    value["parts"].append(item("req", '<message msg_id="fake">')['parts'][0])
    assert module.anchor_id([value, item("self", self_message=True)]) == "old"

@pytest.mark.asyncio
async def test_resolver_receives_current_chat_context_for_implicit_followup(plugin):
    previous = message("prev", "你刚才私聊发的猫猫表情呢", age=2)
    plugin.test_request["processed_plain_text"] = "那你发这里呀"
    plugin.ctx.message.get_recent.side_effect = lambda chat_id, limit=10: (
        [previous, plugin.test_request] if chat_id == "group" else plugin.test_source)
    await inject(plugin)
    assert "你刚才私聊发的猫猫表情呢" in str(plugin.ctx.llm.generate.call_args)


@pytest.mark.asyncio
async def test_send_transport_failure_returns_unconfirmed_without_retry(plugin):
    await inject(plugin)
    ref = next(iter(plugin.bridges[("group", "req")].media))
    plugin.ctx.send.emoji.side_effect = ConnectionError("sensitive endpoint")
    result = await plugin.send_linked_media(ref, "req", stream_id="group")
    assert not result["success"] and "sensitive" not in str(result)
    assert not (await plugin.send_linked_media(ref, "req", stream_id="group"))["success"]
    assert plugin.ctx.send.emoji.await_count == 1

@pytest.mark.asyncio
async def test_pinned_host_snapshot_protocol_and_message_alias_contract(plugin):
    # CI always sets this to the actual Docker source, not a mock host.
    import importlib
    import os
    from types import ModuleType
    root = os.environ.get("MAIBOT_APP_ROOT")
    if not root:
        pytest.skip("Pinned-host source is exercised by the Docker image job")
    host = Path(root)
    package_name = "continuity_host_payload"
    package = ModuleType(package_name)
    package.__path__ = [str(host / "src/llm_models/payload_content")]
    sys.modules[package_name] = package
    snapshot = importlib.import_module(package_name + ".context_snapshot")
    protocol = importlib.import_module(package_name + ".context_protocol")
    alias_spec = importlib.util.spec_from_file_location("continuity_host_alias",
                        host / "src/maisaka/context/message_id_alias.py")
    alias = importlib.util.module_from_spec(alias_spec)
    alias_spec.loader.exec_module(alias)
    mid = "qq-platform-native-long-message-id-12345"
    module = sys.modules[type(plugin).__module__]
    assert module.display_id(mid) == alias.to_display_message_id(mid)
    plugin.test_request["message_id"] = mid
    native = snapshot.deserialize_context_item_snapshot(item(alias.to_display_message_id(mid)))
    original = snapshot.serialize_context_item_snapshot(native)
    result = await plugin.before_planner(items=[original], session_id="group")
    changed = result["modified_kwargs"]["items"]
    restored = [snapshot.deserialize_context_item_snapshot(i) for i in changed]
    protocol.validate_context_items(restored, protocol.ContextProtocolMode.REQUEST_CONTEXT)
    assert snapshot.serialize_context_item_snapshot(restored[0]) == original
    assert restored[-1].__class__.__name__ == "UserMessageItem"
    assert "一只猫挥手" in snapshot.serialize_context_item_snapshot(restored[-1])["parts"][0]["text"]

@pytest.mark.asyncio
async def test_host_nullable_private_group_id_supports_continuity(plugin):
    plugin.test_streams[1]["group_id"] = None
    assert "一只猫挥手" in bridge_text(await inject(plugin))

@pytest.mark.asyncio
async def test_attacker_cannot_impersonate_linked_user_via_later_text_part(plugin):
    attacker = message("attacker", "ordinary text", uid=OTHER)
    composite = item("attacker")
    composite["parts"].extend([{"type":"image","image_base64":"test","image_format":"png"}, item("req")["parts"][0]])
    plugin.ctx.message.get_recent.side_effect = lambda chat_id, limit=10: (
        [plugin.test_request, attacker] if chat_id == "group" else plugin.test_source)
    result = await plugin.before_planner(items=[composite], session_id="group")
    assert "一只猫" not in bridge_text(result)
    plugin.ctx.llm.generate.assert_not_awaited()

@pytest.mark.asyncio
async def test_sent_or_unconfirmed_media_is_not_repeated_after_cache_expiry_and_restart(plugin):
    await inject(plugin)
    first = plugin.bridges[("group", "req")]
    assert (await plugin.send_linked_media(next(iter(first.media)), "req", stream_id="group"))["success"]
    first.expires_at = time.monotonic() - 1
    await inject(plugin)
    ref = next(iter(plugin.bridges[("group", "req")].media))
    assert (await plugin.send_linked_media(ref, "req", stream_id="group"))["success"]
    assert plugin.ctx.send.emoji.await_count == 1
    restarted = type(plugin)()
    restarted.set_plugin_config(plugin.build_default_config() | {"continuity": plugin.config.continuity.model_dump()})
    restarted._set_context(plugin.ctx)
    await restarted.before_planner(items=[item("req")], session_id="group")
    ref = next(iter(restarted.bridges[("group", "req")].media))
    assert (await restarted.send_linked_media(ref, "req", stream_id="group"))["success"]
    assert plugin.ctx.send.emoji.await_count == 1
    ledger = (plugin.ctx.paths.data_dir / "send-ledger.json").read_text()
    assert "一只猫" not in ledger and "original-gif" not in ledger


@pytest.mark.asyncio
async def test_unconfirmed_send_survives_restart_and_old_request_is_rejected(plugin):
    await inject(plugin)
    ref = next(iter(plugin.bridges[("group", "req")].media))
    plugin.ctx.send.emoji.return_value = {"sent": False}
    assert not (await plugin.send_linked_media(ref, "req", stream_id="group"))["success"]
    restarted = type(plugin)()
    restarted.set_plugin_config(plugin.build_default_config() | {"continuity": plugin.config.continuity.model_dump()})
    restarted._set_context(plugin.ctx)
    await restarted.before_planner(items=[item("req")], session_id="group")
    ref = next(iter(restarted.bridges[("group", "req")].media))
    assert not (await restarted.send_linked_media(ref, "req", stream_id="group"))["success"]
    assert plugin.ctx.send.emoji.await_count == 1
    plugin.test_request["timestamp"] = str(time.time() - 90000)
    plugin.bridges.clear()
    plugin.ctx.llm.generate.reset_mock()
    assert "一只猫" not in bridge_text(await inject(plugin))
    plugin.ctx.llm.generate.assert_not_awaited()

@pytest.mark.asyncio
async def test_revoke_during_ledger_write_prevents_media_send(plugin):
    await inject(plugin)
    ref = next(iter(plugin.bridges[("group", "req")].media))
    save = plugin._save_ledger
    async def revoke():
        await plugin.on_config_update(plugin.build_default_config())
        await save()
    plugin._save_ledger = revoke
    assert not (await plugin.send_linked_media(ref, "req", stream_id="group"))["success"]
    plugin.ctx.send.emoji.assert_not_awaited()

@pytest.mark.asyncio
async def test_existing_shared_memory_group_is_the_only_routing_authority(plugin):
    # An empty plugin configuration still uses the bot's existing shared-memory group.
    plugin.set_plugin_config(plugin.build_default_config())
    assert "一只猫挥手" in bridge_text(await inject(plugin))
    plugin.test_policy["a_memorix.shared_memory_groups"] = []
    assert "一只猫" not in bridge_text(await inject(plugin))
    assert "一只猫" not in bridge_text(await plugin.before_replyer(
        items=[item("req")], session_id="group", reply_message_id="req"))


@pytest.mark.asyncio
async def test_legacy_plugin_links_cannot_bypass_shared_memory_policy(plugin):
    legacy = plugin.build_default_config()
    legacy["continuity"]["links"] = [{"platform":"qq","account_id":BOT,"user_id":USER,"group_id":GROUP}]
    plugin.set_plugin_config(legacy)
    plugin.test_policy["a_memorix.shared_memory_groups"] = []
    assert "一只猫" not in bridge_text(await inject(plugin))
    plugin.ctx.llm.generate.assert_not_awaited()
    plugin.ctx.message.get_recent.assert_not_awaited()


@pytest.mark.asyncio
async def test_bot_policy_revocation_during_semantic_request_prevents_injection(plugin):
    async def revoke(*args, **kwargs):
        plugin.test_policy["a_memorix.shared_memory_groups"] = []
        return {"success": True, "response": json.dumps({"continue": True, "context_indices": [1]})}
    plugin.ctx.llm.generate.side_effect = revoke
    assert "一只猫" not in bridge_text(await inject(plugin))
    assert not plugin.bridges


@pytest.mark.asyncio
async def test_bot_policy_revocation_prevents_cached_reply_and_media_send(plugin):
    await inject(plugin)
    ref = next(iter(plugin.bridges[("group", "req")].media))
    plugin.test_policy["a_memorix.shared_memory_groups"] = []
    assert "一只猫" not in bridge_text(await plugin.before_replyer(
        items=[item("req")], session_id="group", reply_message_id="req"))
    assert not (await plugin.send_linked_media(ref, "req", stream_id="group"))["success"]
    plugin.ctx.send.emoji.assert_not_awaited()


@pytest.mark.asyncio
async def test_multiple_users_share_one_group_without_sharing_each_others_private_chat(plugin):
    plugin.test_policy["a_memorix.shared_memory_groups"][0]["targets"].append(
        {"platform":"qq", "item_id": OTHER, "rule_type":"private"})
    plugin.test_streams.append({"session_id":"other-private", "platform":"qq", "group_id":None,
                              "user_id":OTHER, "account_id":BOT, "scope":""})
    reads = []
    old = plugin.ctx.message.get_recent.side_effect
    async def read(chat_id, limit=10):
        reads.append(chat_id)
        return await old(chat_id,limit)
    plugin.ctx.message.get_recent.side_effect = read
    assert "一只猫挥手" in bridge_text(await inject(plugin))
    assert "other-private" not in reads


@pytest.mark.asyncio
async def test_global_memory_setting_is_respected_without_opening_other_private_chats(plugin):
    plugin.test_policy["a_memorix.shared_memory_groups"] = []
    plugin.test_policy["a_memorix.global_memory_sharing_enabled"] = True
    assert "一只猫挥手" in bridge_text(await inject(plugin))


@pytest.mark.asyncio
async def test_overlapping_shared_groups_are_not_transitively_merged(plugin):
    plugin.test_policy["a_memorix.shared_memory_groups"] = [
        {"targets":[{"platform":"qq","item_id":GROUP,"rule_type":"group"},
                    {"platform":"qq","item_id":"other-group","rule_type":"group"}]},
        {"targets":[{"platform":"qq","item_id":"other-group","rule_type":"group"},
                    {"platform":"qq","item_id":USER,"rule_type":"private"}]}]
    assert "一只猫" not in bridge_text(await inject(plugin))
    plugin.ctx.message.get_recent.assert_not_awaited()


@pytest.mark.asyncio
async def test_bot_policy_revocation_during_ledger_write_prevents_media_send(plugin):
    await inject(plugin)
    ref = next(iter(plugin.bridges[("group", "req")].media))
    save = plugin._save_ledger
    async def revoke():
        plugin.test_policy["a_memorix.shared_memory_groups"] = []
        await save()
    plugin._save_ledger = revoke
    assert not (await plugin.send_linked_media(ref, "req", stream_id="group"))["success"]
    plugin.ctx.send.emoji.assert_not_awaited()

@pytest.mark.asyncio
async def test_private_followup_can_select_correct_media_from_multiple_shared_groups(plugin):
    plugin.test_request.update(session_id="private", processed_plain_text="把二群刚才那张猫猫图发给我")
    plugin.test_request["message_info"]["group_info"] = None
    plugin.test_streams.append({"session_id":"group2", "platform":"qq", "group_id":"900000002",
                               "group_name":"二群", "user_id":"", "account_id":BOT, "scope":""})
    plugin.test_policy["a_memorix.shared_memory_groups"][0]["targets"].append(
        {"platform":"qq", "item_id":"900000002", "rule_type":"group"})
    first = message("g1", "一群的篮球", age=30)
    second = message("g2", "二群的猫猫图", session="group2", group="900000002", age=20,
                     media=[{"type":"emoji", "hash":"cat2", "data":"猫猫"}])
    rows = {"private":[plugin.test_request], "group":[first], "group2":[second]}
    plugin.ctx.message.get_recent.side_effect = lambda chat_id,limit=10: rows[chat_id]
    plugin.ctx.llm.generate.return_value = {"success":True, "response":json.dumps(
        {"continue":True,"context_indices":[1],"send_media":{"index":1,"component":0}})}
    async def original(mid, **kwargs):
        assert mid == "g2" and kwargs["chat_id"] == "group2"
        return {**second, "raw_message":[{**second["raw_message"][0],"binary_data_base64":"b3JpZ2luYWw="}]}
    plugin.ctx.message.get_by_id.side_effect = original
    result = await plugin.before_planner(items=[item("req")], session_id="private")
    assert "二群的猫猫图" in bridge_text(result) and "一群的篮球" not in bridge_text(result)
    ref = next(iter(plugin.bridges[("private","req")].media))
    assert (await plugin.send_linked_media(ref,"req",stream_id="private"))["success"]
    plugin.ctx.send.emoji.assert_awaited_once_with("b3JpZ2luYWw=", "private",
        return_details=True, sync_to_maisaka_history=True)


def test_sharing_projection_uses_host_exact_targets_and_nontransitive_union(plugin):
    module = sys.modules[type(plugin).__module__]
    sharing = sys.modules[module.__package__ + ".sharing"]
    streams = plugin.test_streams
    cases = [([], {"group"}),
             ([{"targets":[{"platform":"qq","item_id":GROUP,"rule_type":"group"},
                           {"platform":"qq","item_id":USER,"rule_type":"private"}]}], {"group","private"}),
             ([{"targets":[{"platform":"qq","item_id":"*","rule_type":"group"},
                           {"platform":"qq","item_id":USER,"rule_type":"private"}]}], {"group"}),
             ([{"targets":[{"platform":"other","item_id":GROUP,"rule_type":"group"},
                           {"platform":"qq","item_id":USER,"rule_type":"private"}]}], {"group"})]
    for groups, expected in cases:
        assert sharing.shared_session_ids("group", streams, groups, False) == expected

@pytest.mark.asyncio
async def test_pinned_host_config_get_serialization_and_shared_group_projection(plugin):
    import ast
    import os
    import typing
    from pydantic import BaseModel, Field, create_model
    root = os.environ.get("MAIBOT_APP_ROOT")
    if not root:
        pytest.skip("Pinned host config contract is exercised by the Docker image job")
    host = Path(root)
    env = {"__name__":"continuity_config_contract", **vars(typing), "BaseModel":BaseModel,
           "ConfigBase":BaseModel, "Field":Field, "RULE_TYPE_OPTION_DESCRIPTIONS":{}}

    def definitions(path, names):
        tree = ast.parse((host / path).read_text(encoding="utf-8-sig"))
        selected = [n for n in tree.body if getattr(n,"name",None) in names]
        assert len(selected) == len(names)
        exec(compile(ast.Module(body=selected,type_ignores=[]), str(host/path), "exec"), env)

    # Use the pinned Host's actual target fields, nested config reader and RPC response model.
    definitions("src/config/official_configs.py", {"TargetItem", "ChatStreamGroup"})
    definitions("src/plugin_runtime/capabilities/core.py", {"_get_nested_config_value"})
    definitions("src/plugin_runtime/protocol/envelope.py", {"CapabilityResponsePayload"})
    native_groups = [env["ChatStreamGroup"](**g) for g in plugin.test_policy["a_memorix.shared_memory_groups"]]
    memory_type = create_model("MemorySettings", shared_memory_groups=(list[env["ChatStreamGroup"]],...),
                               global_memory_sharing_enabled=(bool,False))
    native_config = SimpleNamespace(a_memorix=memory_type(shared_memory_groups=native_groups))
    value = env["_get_nested_config_value"](native_config,"a_memorix",{})
    wire = env["CapabilityResponsePayload"](success=True,result={"success":True,"value":value}).model_dump()
    groups = wire["result"]["value"]["shared_memory_groups"]
    assert isinstance(groups[0],dict) and groups[0]["targets"][1]["item_id"] == USER
    plugin.test_policy["a_memorix.shared_memory_groups"] = groups
    assert "一只猫挥手" in bridge_text(await inject(plugin))

    # Run the native direct-group union against exactly the same resolved real stream IDs.
    target_map = {("qq",GROUP,"group"):{"group"}, ("qq",USER,"private"):{"private"}}
    env["global_config"] = native_config
    env["ChatConfigUtils"] = SimpleNamespace(get_target_session_ids=lambda t: target_map.get(
        (t.platform,t.item_id,t.rule_type), set()))
    definitions("src/common/utils/utils_config.py", {"AMemorixConfigUtils"})
    native_ids = env["AMemorixConfigUtils"].get_shared_memory_session_ids("group")
    sharing = sys.modules[sys.modules[type(plugin).__module__].__package__ + ".sharing"]
    assert sharing.shared_session_ids("group",plugin.test_streams,groups,False) == native_ids

@pytest.mark.asyncio
async def test_active_request_changed_during_policy_recheck_prevents_stale_injection(plugin):
    await inject(plugin)
    old = plugin._bridge_route
    async def changed(stream_id, bridge):
        route = await old(stream_id, bridge)
        plugin.active[stream_id] = "different-request"
        return route
    plugin._bridge_route = changed
    assert "一只猫" not in bridge_text(await inject(plugin))

@pytest.mark.asyncio
async def test_routing_reads_one_memory_policy_snapshot_not_mixed_versions(plugin):
    await inject(plugin)
    ref = next(iter(plugin.bridges[("group", "req")].media))
    old = plugin.ctx.config.get.side_effect
    reads = 0
    def revoke(key, default=None):
        nonlocal reads
        if key in {"a_memorix", "a_memorix.global_memory_sharing_enabled"}:
            reads += 1
            if reads == 2:
                plugin.test_policy["a_memorix.shared_memory_groups"] = []
        return old(key,default)
    plugin.ctx.config.get.side_effect = revoke
    plugin.ctx.config.get.reset_mock()
    assert not (await plugin.send_linked_media(ref,"req",stream_id="group"))["success"]
    plugin.ctx.send.emoji.assert_not_awaited()
    assert all(call.args[0] == "a_memorix" for call in plugin.ctx.config.get.await_args_list)
