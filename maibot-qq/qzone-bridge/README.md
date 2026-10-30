# 让糯糯按你的要求发一条带图说说

**当前更新使用 [GitHub + Docker 发布](../RELEASES.md)。** 镜像启动时校验并应用这里的兼容修复，不再手动上传桥接安装包；下方保留历史安装与功能说明。

应用后，可以用 QQ 对糯糯说：

> 发一条关于傍晚散步的说说，自己配一张风景图。

糯糯通过麦麦空间生成正文、调用已经配置的图片接口生成一张图，然后发布到自己的 QQ 空间。当前发布白名单只有主人 QQ；定时发说说、主动浏览和自动回评论保持关闭。图像模型是 `gpt-image-2.5-flare`，没有接入生活照插件的固定肖像，人物配图不能保证和生活照同一张脸。

## 在服务器应用一次

后台的日记插件和麦麦空间已暂时禁用。将 `nuonuo-qzone-bridge.tar.gz` 上传到服务器 `/root/`，执行：

```bash
tar -xzf /root/nuonuo-qzone-bridge.tar.gz -C /opt/maibot-qq-deploy &&
cd /opt/maibot-qq-deploy/maibot-qq &&
docker compose cp /opt/maibot-qq-deploy/qzone-bridge/. maibot:/tmp/qzone-bridge &&
docker compose exec -T maibot /opt/maibot/.venv/bin/python /tmp/qzone-bridge/apply.py --plugins-dir /instance/plugins &&
docker compose restart maibot
```

脚本只读取这两个插件的源码、清单和主程序工具上下文文件，不读取配置、Key、QQ Cookie，也不发说说。它先核对日记 3.0.1 / 麦麦空间 3.0.3 及全部修改位置，再备份原文件并应用。主程序的小修复保证工具参数不能冒充主人 QQ。重复运行不会重复修改。版本或代码不符时停止，不覆盖未知源码。

同为麦麦空间 3.0.3，市场安装包使用同步 `OpenAI`，上游源码使用 `AsyncOpenAI`。安装器同时支持两版，保留各自调用方式，并统一关闭生图自动重试、设置 180 秒超时。

看到“补丁已安装”后重启麦麦容器，不重启 QQ 容器。启动后执行 `bash deploy.sh status` 检查主程序健康，再回到后台先启用麦麦空间、再启用日记插件。先检查插件加载与 QQ 空间登录日志；若空间仍要求扫码，完成登录后再测试。

## 怎么使用

- **按主题发带图说说**：直接对话，或 `/sendfeed 傍晚散步，配一张风景图`。这会真实发布，QQ 空间受众沿用机器人账号现有可见范围。
- **将今天的当前会话写成日记并发布**：主人在相应 QQ 群或私聊发送 `/diary generate`。只读取当前会话当天消息，不汇总其他群或私聊。日记带一张自动配图，生成内容沿用日记插件设置。
- **看日记记录**：主人使用 `/diary list`、`/diary view 日期 编号`。

对话发说说按实际调用用户 QQ 校验，不再通过昵称识别主人。日记查看也只向管理员开放。配图未成功时停止发布，不降级成纯文字；生图请求不自动重试。出现超时或发布未确认时先查看空间是否已有该条内容，避免重复要求发布。

暂未启用每日自动日记。若要每天自动写，需要先选定允许作为素材的会话；定时范围与手动命令互不影响。

## 恢复原插件

先在后台禁用这两个插件。安装输出会给出容器内原文件备份路径，例如 `/instance/backups/qzone-bridge-时间戳`，对应主机 `/opt/maibot-qq/runtime/backups/qzone-bridge-时间戳`。把该目录内的插件原文件按相同相对路径复制回 `/opt/maibot-qq/runtime/plugins/`；`__host__/component_query.py` 单独复制回容器 `/opt/maibot/src/plugin_runtime/component_query.py`，然后只重启麦麦容器。新增的 `diary_space_bridge.py` 在恢复原入口后不会被调用。配置和 Key 没有进入源码备份。

主程序身份校验已纳入 `image/local-fixes.patch`；新镜像启动时会对支持版本的日记/麦麦空间自动校验兼容修复。插件市场升级是独立操作，遇到不匹配的版本应先核对源码，不能继续使用历史安装包强行覆盖。
