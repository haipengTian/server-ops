"""通过麦麦空间发布日记，复用已登录的 QQ 连接与配图配置。"""


class MaizonePublisher:
    def __init__(self, ctx):
        self.ctx = ctx

    async def publish(self, content: str, **unused) -> bool:
        result = await self.ctx.call_capability(
            "api.call", timeout_ms=300000,
            api_name="internetsb.maizone.send_feed_api", version="1",
            args={"message": content, "auto_image": True},
        )
        return isinstance(result, dict) and result.get("result") is True
