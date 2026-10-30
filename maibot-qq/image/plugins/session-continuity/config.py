from maibot_sdk import Field, PluginConfigBase


class PluginSettings(PluginConfigBase):
    __ui_label__ = "插件"
    enabled: bool = True
    config_version: str = "1.0.0"


class ContinuitySettings(PluginConfigBase):
    __ui_label__ = "跨会话接续"
    recent_hours: int = Field(default=6, ge=1, le=24, description="关联近期上下文的时间范围（小时）")
    message_limit: int = Field(default=24, ge=4, le=40, description="参与关联的近期消息总数上限。关联范围沿用机器人设置中的共享记忆配置。")


class ContinuityConfig(PluginConfigBase):
    plugin: PluginSettings = Field(default_factory=PluginSettings)
    continuity: ContinuitySettings = Field(default_factory=ContinuitySettings)
