"""固定原始肖像、按需生成生活照；不修改聊天人设。"""

from contextlib import suppress
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

import asyncio
import base64
import json
import re

from maibot_sdk import API, MaiBotPlugin, Tool

from .config import PhotoConfig
from .images import ImageAPI, ImageError, preview_data_url


class NuonuoPhotoPlugin(MaiBotPlugin):
    config_model = PhotoConfig

    def __init__(self):
        super().__init__()
        self.state: dict[str, Any] = {"reference": "", "candidate": "", "job": {}, "requests": {}}
        self._task: asyncio.Task | None = None
        self._lock = asyncio.Lock()
        self._reference_preview = ""
        self._candidate_preview = ""
        self._latest_preview = ""

    @property
    def data_dir(self) -> Path:
        return self.ctx.paths.data_dir

    async def _save(self):
        payload = json.dumps(self.state, ensure_ascii=False, indent=2)

        def write():
            self.data_dir.mkdir(parents=True, exist_ok=True)
            temp = self.data_dir / "state.tmp"
            temp.write_text(payload, encoding="utf-8")
            temp.replace(self.data_dir / "state.json")

        await asyncio.to_thread(write)

    async def on_load(self):
        def load():
            self.data_dir.mkdir(parents=True, exist_ok=True)
            path = self.data_dir / "state.json"
            return json.loads(path.read_text(encoding="utf-8")) if path.exists() else self.state

        self.state = await asyncio.to_thread(load)
        if self.state["job"].get("status") == "running":
            self.state["job"].update(status="interrupted", error="上次生成因插件重载中断，未自动重试。")
            await self._save()
        for key, attribute in (("reference", "_reference_preview"), ("candidate", "_candidate_preview")):
            if self.state[key]:
                raw = await asyncio.to_thread((self.data_dir / self.state[key]).read_bytes)
                setattr(self, attribute, await asyncio.to_thread(preview_data_url, raw))
        if self.state["job"].get("output"):
            raw = await asyncio.to_thread((self.data_dir / self.state["job"]["output"]).read_bytes)
            self._latest_preview = await asyncio.to_thread(preview_data_url, raw)

    async def on_unload(self):
        if self._task is not None and not self._task.done():
            self._task.cancel()
            with suppress(asyncio.CancelledError):
                await self._task

    async def on_config_update(self, config: dict[str, Any]) -> None:
        self.set_plugin_config(config)

    def _client(self) -> ImageAPI:
        settings = self.config.images
        return ImageAPI(settings.base_url, settings.api_key, settings.model)

    async def _begin(self, kind: str, scene: str = "", stream_id: str = "", request_id: str = "") -> dict:
        async with self._lock:
            request_key = f"{stream_id}:{request_id}" if request_id else ""
            if request_key and request_key in self.state["requests"]:
                return {"success": True, "content": "这条消息已有生成任务，请勿重复生成。", "stop_after_execution": True}
            if self._task is not None and not self._task.done():
                return {"success": False, "error": "已有一张照片正在生成，请等它完成。"}
            if not self.config.images.api_key:
                return {"success": False, "error": "请先在插件设置中配置图片接口。"}
            if kind == "life" and not self.state["reference"]:
                return {"success": False, "error": "还没有确认糯糯的固定肖像，请先在生活照工作室确认形象。"}
            if len(scene) > 1500 or (kind == "life" and not scene.strip()):
                return {"success": False, "error": "请用 1–1500 字描述照片场景。"}
            job_id = uuid4().hex
            reference = self.state["reference"] if kind == "life" else ""
            self.state["job"] = {"id": job_id, "kind": kind, "scene": scene, "status": "running",
                                 "reference": reference, "output": "", "error": "", "sent": False,
                                 "created_at": datetime.now(timezone.utc).isoformat()}
            if request_key:
                self.state["requests"][request_key] = job_id
            await self._save()
            # 先持久化请求，再提交收费调用；重载或发送失败都不会自动生成第二次。
            self._task = asyncio.create_task(self._perform(dict(self.state["job"]), stream_id))
            return {"success": True, "content": "已开始生成糯糯的生活照，完成后会发到当前聊天；不要重复调用。" if stream_id
                    else "已开始生成，完成后会显示预览。", "job_id": job_id, "stop_after_execution": True}

    async def _perform(self, job: dict, stream_id: str):
        try:
            if job["kind"] == "portrait":
                prompt = ("Create one photorealistic reference portrait of this fictional adult character. "
                          "Single person, head and upper torso, eye-level front view, soft daylight, "
                          "plain warm gray background, candid realistic photography, no text, no collage. "
                          + self.config.character.portrait_description)
                reference = None
            else:
                reference = await asyncio.to_thread((self.data_dir / job["reference"]).read_bytes)
                prompt = ("Create a photorealistic everyday photo of the SAME ADULT WOMAN in the reference image. "
                          "Keep her identity, facial structure, eye color, hair color and age consistent. "
                          "The scene may change clothing, pose, lighting and background, but must not change her face. "
                          "Natural skin texture, realistic proportions, believable candid photography, no text, no collage. "
                          "Scene: " + job["scene"])
            raw = await self._client().generate(prompt, reference=reference)
            filename = job["id"] + ".jpg"
            await asyncio.to_thread((self.data_dir / filename).write_bytes, raw)
            self._latest_preview = await asyncio.to_thread(preview_data_url, raw)
            job.update(output=filename, status="completed")
            if job["kind"] == "portrait":
                self.state["candidate"] = filename
                self._candidate_preview = self._latest_preview
            self.state["job"] = job
            await self._save()
            if stream_id:
                # 已经有图片时只尝试发送一次；发送异常不重新提交生图。
                try:
                    sent = await self.ctx.send.image(base64.b64encode(raw).decode("ascii"), stream_id, return_details=True)
                    job["sent"] = bool(sent["sent"])
                    job["message_id"] = sent["message_id"]
                    if not job["sent"]:
                        job.update(status="generated_unsent", error="照片已保存，但平台未确认发送成功；未自动重发。")
                except Exception:
                    job.update(status="generated_unsent", error="照片已保存，但发送结果未确认；未自动重发。")
                self.state["job"] = job
                await self._save()
        except asyncio.CancelledError:
            job.update(status="interrupted", error="生成任务中断，未自动重试。")
            self.state["job"] = job
            await self._save()
            raise
        except (ImageError, OSError) as exc:
            job.update(status="failed", error=str(exc) if isinstance(exc, ImageError) else "本地图片文件读写失败。")
            self.state["job"] = job
            await self._save()
            if stream_id:
                with suppress(Exception):
                    await self.ctx.send.text("这张没生成成功：" + job["error"], stream_id)
        except Exception:
            # 后台任务不能静默挂在 running；技术异常只写安全状态，不回显密钥或响应正文。
            job.update(status="failed", error="生成任务处理异常，未自动重试；请检查本地插件状态。")
            self.state["job"] = job
            await self._save()

    @API("photo_status", description="查看固定形象和最近一次生成结果")
    async def photo_status(self) -> dict:
        job = self.state["job"]
        statuses = {"running": "正在生成…", "completed": "生成完成", "failed": "生成失败",
                    "interrupted": "上次生成已中断", "generated_unsent": "图片已保存，发送未确认"}
        return {"reference_ready": bool(self.state["reference"]), "reference_image": self._reference_preview,
                "candidate_image": self._candidate_preview, "has_candidate": bool(self.state["candidate"]),
                "has_latest": bool(self._latest_preview),
                "can_preview": bool(self.state["reference"]) and job.get("status") != "running",
                "latest_image": self._latest_preview, "candidate_id": self.state["candidate"],
                "can_approve": bool(self.state["candidate"]) and job.get("status") != "running",
                "busy": job.get("status") == "running", "status": statuses.get(job.get("status"), "先生成一张肖像，再确认固定形象"),
                "error": job.get("error", ""), "reference_label": "固定形象已确认" if self.state["reference"] else "固定形象待确认",
                "job_id": job.get("id", ""), "output": job.get("output", ""), "sent": job.get("sent", False)}

    @API("create_portrait", description="生成一张待确认肖像，不发到 QQ")
    async def create_portrait(self) -> dict:
        return await self._begin("portrait")

    @API("approve_portrait", description="将页面展示的候选肖像固定为原始参考")
    async def approve_portrait(self, candidate_id: str) -> dict:
        async with self._lock:
            if self._task is not None and not self._task.done():
                raise ValueError("请等待当前图片生成完成。")
            if not candidate_id or candidate_id != self.state["candidate"]:
                raise ValueError("候选肖像已变化，请刷新页面后重新确认。")
            self.state["reference"] = candidate_id
            raw = await asyncio.to_thread((self.data_dir / candidate_id).read_bytes)
            self._reference_preview = await asyncio.to_thread(preview_data_url, raw)
            await self._save()
            return {"success": True, "message": "已固定这个形象，后续生活照始终使用这张原始参考图。"}

    @API("preview_life_photo", description="根据固定参考生成生活照预览，不发到 QQ")
    async def preview_life_photo(self, scene: str) -> dict:
        return await self._begin("life", scene)

    @Tool("nuonuo_life_photo", description="用户明确要求糯糯的自拍、生活照或照片时，按固定肖像生成并发到当前聊天。完成前不要重复调用；不能主动生成。",
          parameters={"scene": {"type": "string", "description": "用户要求的生活场景、动作及衣服，保留糯糯外貌", "required": True},
                      "request_message_id": {"type": "string", "description": "用户明确索要照片的消息编号", "required": True}})
    async def life_photo(self, scene: str, request_message_id: str, stream_id: str = "", user_id: str = "", **kwargs) -> dict:
        if not stream_id:
            return {"success": False, "error": "需要当前聊天流。"}
        message = await self.ctx.message.get_by_id(request_message_id, stream_id=stream_id)
        if not isinstance(message, dict) or message.get("session_id") != stream_id or message.get("is_notify"):
            return {"success": False, "error": "没有找到当前聊天中索要照片的原始消息。"}
        sender_id = message.get("message_info", {}).get("user_info", {}).get("user_id", "")
        if (user_id and sender_id != user_id) or (sender_id and sender_id == message.get("account_id")):
            return {"success": False, "error": "照片请求必须来自当前用户。"}
        text = message.get("processed_plain_text") or "".join(
            part["data"] for part in message.get("raw_message", []) if part.get("type") == "text")
        if (re.search(r"(不要|不用|别|不需要|不想|不必).{0,12}(发|拍|生成|画|照片|自拍|生活照)", text)
                or not re.search(r"(发|拍|来|给|生成|画|看看|看下|想看).{0,32}(自拍|生活照|照片|写真|近照|相片|你的样子|你长什么样)", text)):
            return {"success": False, "error": "只在用户明确索要自拍、生活照或照片时生成。"}
        return await self._begin("life", scene, stream_id, message["message_id"])


def create_plugin() -> NuonuoPhotoPlugin:
    return NuonuoPhotoPlugin()
