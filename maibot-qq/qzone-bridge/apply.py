"""给已安装的日记 3.0.1 / 麦麦空间 3.0.3 安装实例兼容补丁。

只修改插件与工具上下文源文件；全部校验通过后备份，再写入。不读取配置、Key、Cookie。
请先在后台禁用这两个插件，应用后再启用。
"""

import argparse
import ast
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import shutil


MARKER = "# server-ops qzone bridge v1"
HOST_MARKER = "# server-ops authoritative tool context v1"


def patch_host(source):
    if HOST_MARKER in source:
        return source
    return replace_once(source,
        '        context_payload = ComponentQueryService._build_tool_context_payload(context)\n'
        '        if entry.invoke_method == "plugin.invoke_action":',
        '        context_payload = ComponentQueryService._build_tool_context_payload(context)\n'
        f'        {HOST_MARKER}\n'
        '        for key in ("user_id", "group_id", "platform", "stream_id", "chat_id"):\n'
        '            payload.pop(key, None)\n'
        '        payload.update(context_payload)\n'
        '        if entry.invoke_method == "plugin.invoke_action":')


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError("插件源码与已验证版本不一致，停止修改")
    return source.replace(old, new, 1)


def patch_image(source):
    if MARKER in source:
        return source
    # 市场 3.0.3 用 OpenAI，上游同版本源码已改成 AsyncOpenAI。
    # 保留各自的同步/异步调用方式，只设置同一重试与超时策略。
    matches = list(re.finditer(
        r"(?<![\w.])(?P<client>AsyncOpenAI|OpenAI)\(base_url=base_url, api_key=api_key\)", source))
    if len(matches) != 1:
        raise ValueError("image.py 的生图客户端不属于已支持版本，停止修改")
    match = matches[0]
    replacement = (match.group("client") +
                   "(base_url=base_url, api_key=api_key, max_retries=0, timeout=180.0)")
    return MARKER + "\n" + source[:match.start()] + replacement + source[match.end():]


def patch_send_identity(source):
    return replace_once(source,
        '        users = await self.ctx.db.get(model_name="PersonInfo", filters={"person_name": nickname})\n'
        '        user_id = users[0].get("user_id") if users else ""',
        '        user_id = str(kwargs.get("user_id", "") or "").strip()')


def patch_maizone(source):
    if MARKER in source:
        return source
    source = patch_send_identity(source)
    source = replace_once(source,
        '        user_info = await self.ctx.db.get(model_name="PersonInfo", filters={"person_name": nickname})\n'
        '        user_id = user_info[0].get("user_id") if user_info else ""',
        '        user_id = str(kwargs.get("user_id", "") or "").strip()')
    # 缺少真实上下文时，即使使用黑名单模式也不能授权。
    source = source.replace('if not self.check_permission(user_id,',
                            'if not user_id or not self.check_permission(user_id,')
    source = replace_once(source,
        'from .image import set_images_plugin_context',
        'from .image import set_images_plugin_context, generate_images')
    source = replace_once(source,
        'async def send_feed_api(self, message: str = "", images: list[bytes] = [], **kwargs):',
        'async def send_feed_api(self, message: str = "", images: list[bytes] | None = None, auto_image: bool = False, **kwargs):')
    source = replace_once(source,
        '        fid = await qzone.publish_emotion(content=message, images=images)',
        '        images = images or []\n'
        '        if auto_image and not images:\n'
        '            if not self.config.send.enable_image:\n'
        '                return {"result": False, "message": "日记配图未启用，未发布"}\n'
        '            images = await generate_images(message, self.config.send.image_mode,\n'
        '                self.config.send.image_number, self.config.send.ai_probability)\n'
        '            if not images or not all(images):\n'
        '                return {"result": False, "message": "日记配图失败，未发布"}\n'
        '        fid = await qzone.publish_emotion(content=message, images=images)')
    source = replace_once(source, 'name="send_feed",\n',
                          'name="send_feed",\n        timeout_ms=300000,\n')
    source = replace_once(source, 'name="send_feed_api",\n',
                          'name="send_feed_api",\n        timeout_ms=300000,\n')
    source = replace_once(source,
        '@Command("sendfeed", pattern=r"^/sendfeed\\s+(?P<topic>.+)$")',
        '@Command("sendfeed", pattern=r"^/sendfeed\\s+(?P<topic>.+)$", timeout_ms=300000)')
    return MARKER + "\n" + source


def patch_utils(source):
    if MARKER in source:
        return source
    source = replace_once(source,
        '    # ===== 6. 发布说说 =====',
        '    if config.send.enable_image and (not images_list or not all(images_list)):\n'
        '        return False, "配图失败，未发布说说；请检查图片接口后再试"\n\n'
        '    # ===== 6. 发布说说 =====')
    return MARKER + "\n" + source


def patch_qzone(source):
    if MARKER in source:
        return source
    source = replace_once(source,
        '                if upload_result:\n'
        '                    picbo, richval = get_picbo_and_richval(upload_result)\n'
        '                    if picbo and richval:\n'
        '                        pic_bos.append(picbo)\n'
        '                        richvals.append(richval)',
        '                if not upload_result:\n'
        '                    return None\n'
        '                picbo, richval = get_picbo_and_richval(upload_result)\n'
        '                if not picbo or not richval:\n'
        '                    return None\n'
        '                pic_bos.append(picbo)\n'
        '                richvals.append(richval)')
    return MARKER + "\n" + source


def patch_diary(source):
    if MARKER in source:
        return source
    source = replace_once(source, 'from .config import DiaryPluginConfig',
        'from .config import DiaryPluginConfig\nfrom .diary_space_bridge import MaizonePublisher')
    source = replace_once(source,
        'self._qzone_publisher = QzonePublisher(uin=uin) if uin > 0 else None',
        'self._qzone_publisher = MaizonePublisher(self.ctx)')
    # 私聊生成也限定当前会话，避免默认收集所有群和私聊并公开发布。
    source = replace_once(source,
        '        return await self._pipeline.fetch_messages_for_date(\n'
        '            date,\n'
        '            ignore_filter=True,\n'
        '            ignore_min_messages_per_chat=ignore_min_messages_per_chat,\n'
        '        )',
        '        if not stream_id:\n'
        '            raise ValueError("无法确定日记会话，已停止读取消息")\n'
        '        return await self._pipeline.fetch_messages_for_date(\n'
        '            date,\n'
        '            target_chats=[stream_id],\n'
        '            ignore_min_messages_per_chat=ignore_min_messages_per_chat,\n'
        '        )')
    source = replace_once(source, 'if action not in ("view", "help"):',
                          'if action != "help":')
    source = replace_once(source,
        '            "/diary view [日期] [编号] - 查看日记\\n\\n"\n'
        '            "🔒 管理员专用:\\n"',
        '            "\\n🔒 管理员专用:\\n"\n'
        '            "/diary view [日期] [编号] - 查看日记\\n"')
    source = source.replace('群命令限定当前真实会话，私聊命令沿用全局日记范围。',
                            '手动命令只读取当前真实会话。')
    source = source.replace('# generate 命令忽略黑白名单。如果在群聊中执行,只取当前会话的消息;否则全局',
                            '# 手动生成只取当前会话，定时任务继续使用配置的范围。')
    source = replace_once(source,
        '        pattern=r"^\\s*/\\s*diary\\s+(?P<action>list|generate|help|debug|view)(?:\\s+(?P<param>.+))?\\s*$",',
        '        timeout_ms=360000,\n'
        '        pattern=r"^\\s*/\\s*diary\\s+(?P<action>list|generate|help|debug|view)(?:\\s+(?P<param>.+))?\\s*$",')
    source = replace_once(source,
        '                    "⚠️ QQ 空间发布失败,可能原因:\\n1. Napcat 服务未启动\\n2. 端口配置错误\\n3. QQ 空间权限问题",',
        '                    "⚠️ 日记已保存，但未确认发布成功。请检查麦麦空间的登录、配图和发布日志，不要连续重复生成。",')
    return MARKER + "\n" + source


def find_plugin(plugins_dir, plugin_id, version):
    matches = []
    for manifest_path in plugins_dir.glob("*/_manifest.json"):
        manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
        if manifest.get("id") == plugin_id:
            if manifest.get("version") != version:
                raise ValueError(f"{plugin_id} 需要版本 {version}，未修改文件")
            matches.append(manifest_path.parent)
    if len(matches) != 1:
        raise ValueError(f"需要唯一的已安装插件 {plugin_id}，找到 {len(matches)} 个")
    return matches[0]


def build_changes(plugins_dir, host_source):
    maizone = find_plugin(plugins_dir, "internetsb.maizone", "3.0.3")
    diary = find_plugin(plugins_dir, "bockegai.diary-plugin", "3.0.1")
    transforms = {
        maizone / "plugin.py": patch_maizone,
        maizone / "utils.py": patch_utils,
        maizone / "qzone_api.py": patch_qzone,
        diary / "plugin.py": patch_diary,
        host_source: patch_host,
    }
    changes = {}
    for path, transform in transforms.items():
        try:
            changes[path] = transform(path.read_text(encoding="utf-8"))
        except ValueError as exc:
            raise ValueError(f"{path.parent.name}/{path.name}: {exc}") from exc
    image_path = maizone / "image.py"
    changes[image_path] = patch_image(image_path.read_text(encoding="utf-8"))
    changes[diary / "diary_space_bridge.py"] = (Path(__file__).parent / "diary_space_bridge.py").read_text(encoding="utf-8")
    manifest_path = diary / "_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    if "api.call" not in manifest["capabilities"]:
        manifest["capabilities"].append("api.call")
    changes[manifest_path] = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    for path, source in changes.items():
        if path.suffix == ".py":
            ast.parse(source, filename=str(path))
    return {path: source for path, source in changes.items()
            if not path.exists() or path.read_text(encoding="utf-8") != source}


def apply_changes(plugins_dir, changes):
    if not changes:
        print("补丁已安装，无需重复修改。")
        return
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = plugins_dir.parent / "backups" / f"qzone-bridge-{stamp}"
    backup.mkdir(parents=True)
    def saved_path(path):
        try:
            relative = path.relative_to(plugins_dir)
        except ValueError:
            relative = Path("__host__") / path.name
        return backup / relative
    created = []
    try:
        for path in changes:
            if path.exists():
                target = saved_path(path)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
            else:
                created.append(path)
        for path, source in changes.items():
            temp = path.with_suffix(path.suffix + ".ops-tmp")
            temp.write_text(source, encoding="utf-8", newline="\n")
            temp.replace(path)
    except Exception:
        for path in changes:
            saved = saved_path(path)
            if saved.exists():
                shutil.copy2(saved, path)
        for path in created:
            path.unlink(missing_ok=True)
        raise
    print(f"补丁已安装，源文件备份：{backup}")
    print("请重启麦麦容器，再在后台先启用麦麦空间、再启用日记插件。尚未发布任何说说。")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugins-dir", type=Path, required=True)
    parser.add_argument("--host-source", type=Path,
        default=Path("/opt/maibot/src/plugin_runtime/component_query.py"))
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        changes = build_changes(args.plugins_dir.resolve(strict=True), args.host_source.resolve(strict=True))
        if args.check:
            print(f"校验通过，{len(changes)} 个源文件待更新；未修改实例。")
        else:
            apply_changes(args.plugins_dir.resolve(strict=True), changes)
    except (ValueError, OSError, SyntaxError) as exc:
        parser.exit(1, f"安装停止：{exc}\n")
