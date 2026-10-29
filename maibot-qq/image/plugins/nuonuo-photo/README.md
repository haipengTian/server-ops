# 糯糯生活照

在[糯糯生活照工作室](http://127.0.0.1:18011/extensions/haipengtian.nuonuo-photo/studio)生成并确认她的肖像，然后在 QQ 对她说：

> 发张你在咖啡店看书的生活照。

她会带着固定的原始肖像生成一张照片，通过当前聊天的图片发送通道发回来。默认是一名 25 岁的成年虚构女性，接近真人的摄影风格。可在插件配置中调整初始外观描述；调整描述不会自动更换已经确认的参考图。

## 先确认形象

1. 在工作室点击“生成一张候选肖像”。会调用一次图片接口，预览完成后显示在左侧。
2. 喜欢这张脸后，点击“就用这个形象”。候选图只有经过这一步才成为固定参考。
3. 输入场景生成生活照预览，或到 QQ 明确要求自拍、生活照等。工作室预览不发到 QQ。

重新生成候选不会自动替换固定参考。生活照也不会反过来成为下一次生成的参考。相貌一致性取决于图片模型对参考图的遵循程度。

## 接口配置

插件配置页的“图片接口”提供地址、API Key 密码框和模型名。当前模型为 `gpt-image-2.5-flare`，使用 OpenAI 兼容的 `/v1/images/generations` 和带参考图的 `/v1/images/edits`，响应需要 `data[].b64_json`。

安装时通过已认证的原生 WebUI 接口沿用现有聊天服务地址和 Key，仅在本机保存；聊天服务日后换 Key 时，也需同步更新这里。插件不读宿主私有配置文件，不把 Key 传入聊天、模型提示或工具结果。

每个请求只生成一张，最多同时处理一个生成任务。网络失败或超时不自动重试；上游可能仍已计费。当前用户消息会持久化去重，生成后发送失败不会重新生图或自动重发。

## 文件、状态和停用

原始肖像、候选和生成照片保存在 `E:\workspace\personal\ai\maibot-qq\runtime\data\plugins\haipengtian.nuonuo-photo`，状态在同目录 `state.json`。保留原件；页面只发送小预览图。生成后发送未确认时，可从这里取回已生成的 JPG。

插件代码位于 `E:\workspace\personal\ai\maibot-qq\runtime\plugins\nuonuo-photo`，是独立 Git 仓库，没有推送。无需改动麦麦主程序、人设、聊天模型或 QQ 白名单。

在插件管理中停用“糯糯生活照”即可关闭生图能力；停用不删除图片和状态。图片生成期间不要修改插件源码或重载插件，以免中断任务。中断的请求不会自动重试。

## 本地测试

```powershell
cd E:\workspace\personal\ai\maibot-qq\runtime\plugins\nuonuo-photo
& E:\workspace\personal\ai\maibot-qq\app\.venv\Scripts\python.exe -m pytest tests -q --asyncio-mode=auto
```

测试使用虚构 Key 和本地 HTTP 模拟，不调用收费服务或发 QQ 消息。
