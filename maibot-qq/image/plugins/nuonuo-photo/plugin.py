"""固定原始肖像、按需生成生活照；不修改聊天人设。"""

from contextlib import suppress
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

import asyncio
import base64
import json

from maibot_sdk import API, MaiBotPlugin, Tool

from .config import PhotoConfig
from .images import ImageAPI, ImageError, preview_data_url
from .intent import SYSTEM_PROMPT, parse_intent, text_of


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
        job = self.state["job"]
        if job.get("id"):
            # 兼容旧状态：用原始请求记录确定所属聊天，不能把全局最近任务泄露到别的聊天。
            if not job.get("stream_id"):
                for key, job_id in self.state["requests"].items():
                    if job_id == job["id"]:
                        job["stream_id"] = key.rsplit(":", 1)[0]
                        break
            self.state.setdefault("jobs", {})[job["id"]] = dict(job)
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
        self.state.setdefault("jobs", {})
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
        # 记录旧版最后一个任务的归属，旧请求继续去重。
        await self._save()

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
                return self._duplicate_result(request_key)
            if self._task is not None and not self._task.done():
                return {"success": False, "error": "已有一张照片正在生成，请等它完成。"}
            if not self.config.images.api_key:
                return {"success": False, "error": "请先在插件设置中配置图片接口。"}
            if kind == "life" and not self.state["reference"]:
                return {"success": False, "error": "还没有确认糯糯的固定肖像，请先在生活照工作室确认形象。"}
            if len(scene) > 1500 or (kind in {"life", "general"} and not scene.strip()):
                return {"success": False, "error": "请用 1–1500 字描述图片内容。"}
            job_id = uuid4().hex
            reference = self.state["reference"] if kind == "life" else ""
            self.state["job"] = {"id": job_id, "kind": kind, "scene": scene, "status": "running",
                                 "stream_id": stream_id,
                                 "reference": reference, "output": "", "error": "", "sent": False,
                                 "created_at": datetime.now(timezone.utc).isoformat()}
            if request_key:
                self.state["requests"][request_key] = job_id
            await self._save()
            # 先持久化请求，再提交收费调用；重载或发送失败都不会自动生成第二次。
            self._task = asyncio.create_task(self._perform(dict(self.state["job"]), stream_id))
            label = "糯糯的照片" if kind == "life" else "图片"
            return {"success": True, "content": f"已开始生成{label}。完成后尝试发送到当前聊天；催进度时调用 get_image_status 查询，不要仅凭本次开始通知判断仍在运行。同一条消息不要重复提交；任务结束后用户用新消息明确要求重画，可以再次生成。" if stream_id
                    else "已开始生成，完成后会显示预览。", "job_id": job_id, "stop_after_execution": True}

    async def _perform(self, job: dict, stream_id: str):
        try:
            if job["kind"] == "portrait":
                prompt = ("Create one photorealistic reference portrait of this fictional adult character. "
                          "Single person, head and upper torso, eye-level front view, soft daylight, "
                          "plain warm gray background, candid realistic photography, no text, no collage. "
                          + self.config.character.portrait_description)
                reference = None
            elif job["kind"] == "general":
                reference = None
                prompt = job["scene"]
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
                    sent = await self.ctx.send.image(base64.b64encode(raw).decode("ascii"), stream_id,
                        return_details=True, sync_to_maisaka_history=True)
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
                await self._notify_failure(job, stream_id)
        except Exception:
            # 后台任务不能静默挂在 running；技术异常只写安全状态，不回显密钥或响应正文。
            job.update(status="failed", error="生成任务处理异常，未自动重试；请检查本地插件状态。")
            self.state["job"] = job
            await self._save()
            if stream_id:
                await self._notify_failure(job, stream_id)

    async def _notify_failure(self, job: dict, stream_id: str):
        try:
            sent = await self.ctx.send.text("这张没生成成功：" + job["error"] +
                " 当前任务已结束；需要重画可以发新消息明确要求重新生成。", stream_id,
                return_details=True, sync_to_maisaka_history=True)
            job["failure_notified"] = isinstance(sent, dict) and bool(sent.get("sent"))
        except Exception:
            job["failure_notified"] = False
        self.state["job"] = job
        await self._save()

    def _job_status(self, job: dict) -> dict:
        status = job.get("status", "not_found")
        labels = {"running": "正在生成", "completed": "图片已生成", "failed": "生成失败，任务已结束",
                  "interrupted": "任务已中断", "generated_unsent": "图片已保存，但发送未确认",
                  "not_found": "当前聊天没有可查询的生成任务"}
        can_generate = self._task is None or self._task.done()
        guidance = ("用户用新消息明确要求重新生成时可以调用生图工具；使用新消息编号，不能重用旧请求。"
                    if can_generate else "当前有生成任务未结束，请等待；不要重复提交。")
        return {"success": True, "status": status, "job_id": job.get("id", ""),
                "error": job.get("error", ""), "sent": bool(job.get("sent")),
                "can_generate": can_generate, "content": labels.get(status, status) + "。" + guidance}

    def _duplicate_result(self, request_key: str) -> dict:
        job_id = self.state["requests"][request_key]
        job = self.state.get("jobs", {}).get(job_id, {})
        if self.state["job"].get("id") == job_id:
            job = self.state["job"]
        result = self._job_status(job)
        result.update(content="这条消息已提交过，未再次生成。" + result["content"], stop_after_execution=True)
        return result

    @Tool("get_image_status", description="查询当前聊天最近一次生图的真实状态和失败原因，不收费、不生成图片。用户催进度、问失败原因或要求重新生成时先查询，不能凭旧的开始通知假定仍在生成。任务结束后，用户新消息明确要求重画时可调用生图工具；同一原始消息始终防重复。",
          parameters={})
    async def image_status(self, stream_id: str = "", **kwargs) -> dict:
        if not stream_id:
            return {"success": False, "error": "需要当前聊天流。"}
        for job in reversed(list(self.state.get("jobs", {}).values())):
            if job.get("stream_id") == stream_id:
                return self._job_status(job)
        return self._job_status({})

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

    @API("preview_image", description="通用生图预览，不使用糯糯肖像，不发到 QQ")
    async def preview_image(self, drawing_scene: str) -> dict:
        return await self._begin("general", drawing_scene)

    @Tool("nuonuo_life_photo", description="用户要求包含糯糯本人的图片：自拍、生活照、换装、与人或宠物合照/合影，使用固定肖像生成并发到当前聊天。按语义理解；纯绘图用 generate_image。用户要求重画时先用 get_image_status 查真实状态，任务结束后可按用户新的明确请求生成，使用新消息编号；不能因旧开始通知拒绝新请求。同一条消息不要重复提交。",
          parameters={"scene": {"type": "string", "description": "用户要求的生活场景、动作及衣服，保留糯糯外貌", "required": True},
                      "request_message_id": {"type": "string", "description": "用户明确索要照片的消息编号", "required": True}})
    async def life_photo(self, scene: str, request_message_id: str, stream_id: str = "", user_id: str = "", **kwargs) -> dict:
        return await self._image_request(scene, request_message_id, stream_id, user_id)

    @Tool("generate_image", description="用户明确要求生成不包含糯糯的图片时调用，如动物、风景、海报、动漫等，保留画风和文字。包含糯糯用 nuonuo_life_photo。用户要求重画时先用 get_image_status 查真实状态，任务结束后可按新的明确请求生成，使用新消息编号。同一条消息不要重复提交；不能把闲聊、引用、否定当成生图请求。",
          parameters={"scene": {"type": "string", "description": "用户要画的主体、风格和内容", "required": True},
                      "request_message_id": {"type": "string", "description": "用户要求生成图片的原始消息编号", "required": True}})
    async def generate_image(self, scene: str, request_message_id: str, stream_id: str = "", user_id: str = "", **kwargs) -> dict:
        return await self._image_request(scene, request_message_id, stream_id, user_id)

    async def _image_request(self, scene: str, request_message_id: str, stream_id: str, user_id: str) -> dict:
        if not stream_id:
            return {"success": False, "error": "需要当前聊天流。"}
        message = await self.ctx.message.get_by_id(request_message_id, stream_id=stream_id)
        if not isinstance(message, dict) or message.get("session_id") != stream_id or message.get("is_notify"):
            return {"success": False, "error": "没有找到当前聊天中要求生成图片的原始消息。"}
        sender_id = message.get("message_info", {}).get("user_info", {}).get("user_id", "")
        if not sender_id or (user_id and sender_id != user_id) or sender_id == message.get("account_id"):
            return {"success": False, "error": "照片请求必须来自当前用户。"}
        message_id = str(message.get("message_id") or request_message_id)
        if f"{stream_id}:{message_id}" in self.state["requests"]:
            return self._duplicate_result(f"{stream_id}:{message_id}")
        if self._task is not None and not self._task.done():
            return {"success": False, "error": "已有一张图片正在生成，请等它完成。"}
        try:
            recent = await self.ctx.message.get_recent(stream_id, limit=8)
            if not isinstance(recent, list):
                raise ValueError("Cannot retrieve image request context")
            context = []
            request_time = float(message["timestamp"])
            previous_image = {}
            for previous in reversed(list(self.state.get("jobs", {}).values())):
                if previous.get("stream_id") != stream_id:
                    continue
                created = previous.get("created_at")
                if created and datetime.fromisoformat(created).timestamp() > request_time:
                    continue
                previous_image = {"kind": previous.get("kind", ""), "scene": previous.get("scene", "")[:1500]}
                break
            for item in recent:
                if item.get("session_id") != stream_id or item.get("is_notify"):
                    continue
                if str(item.get("message_id")) == message_id or float(item["timestamp"]) > request_time:
                    continue
                context_sender = item.get("message_info", {}).get("user_info", {}).get("user_id", "")
                context.append({"text": text_of(item)[:1500], "sender": context_sender,
                    "is_bot": context_sender == message.get("account_id")})
            result = await asyncio.wait_for(self.ctx.llm.generate(task_name="utils", temperature=0,
                max_tokens=2048, prompt=[{"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": json.dumps({"request": text_of(message)[:6000], "request_sender": sender_id,
                        "context": context, "previous_image": previous_image,
                        "suggested_scene": scene[:1500]}, ensure_ascii=False)}]), timeout=30)
            kind, accepted_scene = parse_intent(result)
        except Exception:
            return {"success": False, "error": "图片请求的语义识别未完成，尚未提交生图，请稍后再试。"}
        if kind == "none":
            return {"success": False, "error": "这条消息没有明确要求生成新图片，未提交生图。"}
        return await self._begin(kind, accepted_scene, stream_id, message_id)


def create_plugin() -> NuonuoPhotoPlugin:
    return NuonuoPhotoPlugin()
