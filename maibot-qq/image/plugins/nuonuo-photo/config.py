from maibot_sdk import Field, PluginConfigBase


class PluginSettings(PluginConfigBase):
    __ui_label__ = "插件"
    enabled: bool = Field(default=True, description="启用糯糯生活照")
    config_version: str = "1.0.0"


class ImageSettings(PluginConfigBase):
    __ui_label__ = "图片接口"
    base_url: str = Field(default="https://proxy.thpvip.xyz/v1", description="OpenAI 兼容图片服务地址")
    api_key: str = Field(default="", repr=False, description="与聊天服务共用的 Key；本地保存，不发送到聊天",
                         json_schema_extra={"input_type": "password", "label": "API Key"})
    model: str = Field(default="gpt-image-2.5-flare", description="生图模型")


class CharacterSettings(PluginConfigBase):
    __ui_label__ = "固定形象"
    portrait_description: str = Field(default=(
        "A fictional Chinese adult woman, 25 years old. Long straight dark brown hair, "
        "dark brown eyes, soft oval face, natural eyebrows, warm relaxed smile. "
        "Natural skin texture and light everyday makeup. Cream knit cardigan over a pale blue top. "
        "A friendly, approachable everyday appearance, not a celebrity or a real person's likeness."
    ), description="生成初始肖像时的外观要求；后续生活照以确认过的原始肖像为准")


class PhotoConfig(PluginConfigBase):
    plugin: PluginSettings = Field(default_factory=PluginSettings)
    images: ImageSettings = Field(default_factory=ImageSettings)
    character: CharacterSettings = Field(default_factory=CharacterSettings)
