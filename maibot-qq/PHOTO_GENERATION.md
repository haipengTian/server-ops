# 两类生图与替换糯糯形象

**当前更新统一使用 [GitHub + Docker 发布](RELEASES.md)。** 下方安装包步骤仅供追溯历史，不再作为日常更新入口。

QQ 中可以直接说：

- “发张你和米切尔的合照”：使用糯糯的固定参考图。
- “画只水彩小猫”：通用绘图，不使用角色参考。
- 接着上一张说“换成夜景再来一张”：根据原消息与会话上下文判断类别及场景。

原始用户消息必须属于当前会话和发起者；模型确认生成意图后才提交图片接口。引用、否定、聊天、表情包和检索图片请求不生成。原始请求去重、单任务执行、不自动重试收费请求继续有效。工作室分别提供两种预览，预览不发送 QQ。

## 当前服务器更新

### v1.1.1：状态查询和失败后重画

`nuonuo-photo-status-fix.tar.gz` 仅包含源码、v1.1.0 基线和安装器，不含照片、Key 或配置。适用于已完成两类生图更新的当前实例。通过服务器面板上传到 `/tmp` 后运行：

```bash
mkdir -p /opt/nuonuo-photo-status-fix
tar -xzf /tmp/nuonuo-photo-status-fix.tar.gz -C /opt/nuonuo-photo-status-fix
python3 /opt/nuonuo-photo-status-fix/upgrade_photo.py /opt/maibot-qq-deploy/maibot-qq
```

更新只停止麦麦，保留当前固定形象、配置、生成结果和原请求防重记录，输出可独立执行的回退命令。完成后询问“刚才图片为什么失败了”，应查询真实状态；再明确要求“按刚才场景重新生成一张”，应使用新消息编号提交。旧 HTTP 400 的原始响应此前没有保存，升级无法补回其具体分类，需以新的实际请求或服务商请求日志为准。

### v1.1.0：两类生图与新参考图

私有安装包 `nuonuo-photo-update.tar.gz` 包含本次代码和用户指定的新参考照片，不能提交到 GitHub。上传到服务器 `/tmp`，在面板终端执行：

```bash
mkdir -p /opt/nuonuo-photo-update
tar -xzf /tmp/nuonuo-photo-update.tar.gz -C /opt/nuonuo-photo-update
python3 /opt/nuonuo-photo-update/upgrade_photo.py /opt/maibot-qq-deploy/maibot-qq
```

安装器适用于已经安装 QQ 表情覆盖配置的当前实例。先检查挂载、插件 v1.0.0 原文件、当前没有生图任务，再只停止麦麦，保存原运行代码为本地恢复镜像；更新插件、参考图与镜像覆盖后启动并等待健康检查。QQ/SnowLuma 不停止，现有 QQ 表情挂载和其他配置保留。需要服务器额外空间保存本地镜像；不要把恢复镜像推送到外部仓库。

新参考图使用独立文件名，不覆盖旧肖像。更新状态只改变 `reference` 和 `candidate`，保留已有生成结果和去重记录。安装器会输出独立回退命令；错误时自动恢复旧插件和旧参考。之后手工回退也保留新产生的请求和图片；如果后来又换了形象，不会把后来的形象替换掉。

安装后打开 [生活照工作室](https://maimai.thpvip.xyz/extensions/haipengtian.nuonuo-photo/studio)，确认固定参考显示新图、出现“画其他内容”。再用 QQ 实测两类请求。容器健康只证明启动完成，图片接口和发送结果需要真实请求验收。
