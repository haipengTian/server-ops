"""投影宿主共享记忆范围；保持精确目标、同组并集、非传递关系。"""


def shared_session_ids(current_id: str, streams: list[dict], groups: list[dict], global_enabled: bool) -> set[str]:
    if global_enabled:
        return {s["session_id"] for s in streams}
    shared = {current_id}
    for group in groups:
        members: set[str] = set()
        for target in group.get("targets", []):
            platform = str(target.get("platform") or "").strip()
            item_id = str(target.get("item_id") or "").strip()
            kind = str(target.get("type") or target.get("rule_type") or "").strip()
            if not platform or not item_id or kind not in {"group", "private"}:
                continue
            for stream in streams:
                is_group = bool(stream.get("group_id"))
                stream_target = stream.get("group_id") if is_group else stream.get("user_id")
                if (str(stream.get("platform") or "").strip() == platform
                        and ("group" if is_group else "private") == kind
                        and str(stream_target or "").strip() == item_id):
                    members.add(stream["session_id"])
        if current_id in members:
            shared.update(members)
    return shared
