from maibot_sdk import Field, PluginConfigBase


class PluginSettings(PluginConfigBase):
    __ui_label__ = "插件"
    enabled: bool = True
    config_version: str = "1.0.0"


class Link(PluginConfigBase):
    platform: str = "qq"
    account_id: str = Field(default="", description="机器人 QQ 号，防止混入其他登录账号")
    user_id: str = Field(default="", description="允许接续自己私聊的用户 QQ 号")
    group_id: str = Field(default="", description="关联的群号；只允许该用户接续自己的私聊")


class ContinuitySettings(PluginConfigBase):
    __ui_label__ = "跨会话接续"
    links: list[Link] = Field(default_factory=list, description="明确授权的私聊与群聊配对。空列表不读取其他会话。")
    recent_hours: int = Field(default=6, ge=1, le=24, description="关联近期上下文的时间范围（小时）")
    message_limit: int = Field(default=24, ge=4, le=40, description="每个关联会话最多读取的近期消息数")


class ContinuityConfig(PluginConfigBase):
    plugin: PluginSettings = Field(default_factory=PluginSettings)
    continuity: ContinuitySettings = Field(default_factory=ContinuitySettings)
