"""OpenAI Images 客户端；每次只提交一次，不自动重试收费请求。"""

from io import BytesIO
from typing import Optional

import asyncio
import base64
import binascii

import httpx
from PIL import Image, ImageOps, UnidentifiedImageError

MAX_IMAGE_BYTES = 24 * 1024 * 1024


class ImageError(ValueError):
    """可直接展示的图片服务错误，不包含认证信息或上游原始响应。"""


def http_error(response: httpx.Response) -> str:
    """把标准错误分类转成固定说明，不回显上游正文、提示词或认证信息。"""
    try:
        payload = response.json()
    except ValueError:
        payload = {}
    error = payload.get("error", {}) if isinstance(payload, dict) else {}
    if not isinstance(error, dict):
        error = {"message": error}
    code = error.get("code") or error.get("type")
    message = str(error.get("message", "")).lower()
    param = error.get("param")
    if code in {"content_policy_violation", "moderation_blocked", "safety_violation"} or any(
        word in message for word in ("safety system", "content policy", "moderation", "内容审核", "安全审核")
    ):
        reason = "服务商内容审核拒绝；需要调整场景或参考图后再提出新请求。"
    elif code in {"invalid_image", "image_parse_error", "invalid_image_format"}:
        reason = "服务商无法处理参考图片，请检查图片格式和大小。"
    elif param in {"model", "image", "size", "quality", "response_format", "n", "prompt"}:
        reason = f"服务商报告参数 {param} 不符合要求，请核对该接口支持的参数。"
    elif response.status_code in {401, 403}:
        reason = "认证或模型访问被拒绝，请检查接口配置及模型权限。"
    elif response.status_code == 429:
        reason = "服务商限流或额度不足，请检查额度和限流状态。"
    else:
        reason = "服务商未提供可识别的错误分类，需要查看该服务的请求日志。"
    return f"图片接口返回 HTTP {response.status_code}：{reason}未自动重试。"


def normalize_image(raw: bytes) -> bytes:
    if len(raw) > MAX_IMAGE_BYTES:
        raise ImageError("图片超过 24 MB，未保存。")
    try:
        with Image.open(BytesIO(raw)) as image:
            if image.width * image.height > 24_000_000:
                raise ImageError("图片像素超过限制，未保存。")
            image.load()
            image = ImageOps.exif_transpose(image).convert("RGB")
            output = BytesIO()
            image.save(output, "JPEG", quality=95)
            return output.getvalue()
    except (OSError, UnidentifiedImageError, Image.DecompressionBombError) as exc:
        raise ImageError("接口没有返回有效图片。") from exc


def preview_data_url(raw: bytes) -> str:
    with Image.open(BytesIO(raw)) as image:
        image = image.convert("RGB")
        image.thumbnail((240, 320))
        # Host 每图上限 24000 字符；三份预览各控制在 14000 字符内，避免放大轮询流量。
        # 原件不受预览缩放影响。
        while True:
            output = BytesIO()
            image.save(output, "JPEG", quality=65)
            result = "data:image/jpeg;base64," + base64.b64encode(output.getvalue()).decode("ascii")
            if len(result) <= 14000:
                return result
            image = image.resize((max(1, image.width * 4 // 5), max(1, image.height * 4 // 5)))


class ImageAPI:
    def __init__(self, base_url: str, api_key: str, model: str, *, transport: Optional[httpx.AsyncBaseTransport] = None):
        base = base_url.rstrip("/")
        self.base_url = base if base.endswith("/v1") else base + "/v1"
        self.api_key = api_key
        self.model = model
        self.transport = transport

    async def generate(self, prompt: str, *, reference: Optional[bytes] = None) -> bytes:
        if not self.api_key or not self.base_url.startswith("https://"):
            raise ImageError("请先配置 HTTPS 图片接口及 API Key。")
        fields = {"model": self.model, "prompt": prompt, "n": "1", "size": "1024x1536",
                  "quality": "auto", "response_format": "b64_json"}
        # 独立请求不记录头部/响应正文；错误只暴露 HTTP 状态，避免上游回显密钥。
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(180, connect=20), transport=self.transport) as client:
                headers = {"Authorization": "Bearer " + self.api_key, "User-Agent": "Mozilla/5.0 NuonuoPhoto/1.0"}
                if reference is None:
                    response = await client.post(self.base_url + "/images/generations", headers=headers,
                                                 json={**fields, "n": 1})
                else:
                    response = await client.post(self.base_url + "/images/edits", headers=headers, data=fields,
                                                 files={"image": ("nuonuo-reference.jpg", reference, "image/jpeg")})
            if response.status_code != 200:
                raise ImageError(http_error(response))
            payload = response.json()
            items = payload.get("data", [])
            if not items or not isinstance(items[0], dict) or not items[0].get("b64_json"):
                raise ImageError("图片接口未返回 b64_json 图片，请确认该服务支持标准 Images 响应。")
            encoded = items[0]["b64_json"]
            if len(encoded) > MAX_IMAGE_BYTES * 4 // 3 + 4:
                raise ImageError("接口图片超过 24 MB，未保存。")
            raw = base64.b64decode(encoded, validate=True)
            return await asyncio.to_thread(normalize_image, raw)
        except httpx.TimeoutException as exc:
            raise ImageError("图片接口等待超时；上游可能仍在处理，未自动重试。") from exc
        except httpx.HTTPError as exc:
            raise ImageError("图片接口连接失败，未自动重试。") from exc
        except ImageError:
            raise
        except (ValueError, binascii.Error, KeyError, TypeError, AttributeError) as exc:
            raise ImageError("图片接口返回格式无效。") from exc
