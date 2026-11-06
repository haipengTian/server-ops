# 让糯糯看懂 QQ 原生表情

**当前更新统一使用 [GitHub + Docker 发布](RELEASES.md)。** 新镜像已包含适配器和素材，下方局部安装包仅保留历史操作记录。

Read GIF 在麦麦插件市场安装并启用后，还需要适配器把原生 `face` 转成“名称 + 原始图片”。只装 Read GIF 无法识别当前仅有名字的 `[虎虎生威]`。

本补丁新增适配器 `plugin.qq_face_parse_mode = "visual"`，旧的 `description`、`emoji` 行为不变。图片从固定 QFace 版本构建期下载并打包，聊天时无需下载。327 种可用图片中 284 种含多帧，43 种是静态图；没有素材时明确显示“未取得图像”。仅有 Lottie 的动画不转换。

“虎虎生威”（334）的该版本原资源只有一帧：戴虎头帽的 QQ 企鹅，按静态图片识别。有动画的表情交给 Read GIF 抽帧并使用现有 `vlm`；每种新动画增加视觉调用及数秒延迟，重复动画用插件缓存。视觉能力仍取决于实际配置的模型。

## 在现有服务器安装

为避免整镜像更新覆盖服务器上的其他补丁，现有实例使用仅包含本次适配器文件的 Compose 覆盖配置。安装器要求当前适配器代码可应用补丁、Read GIF v0.1.2 可应用调色板修复、实例挂载为 `/opt/maibot-qq/runtime`；不匹配时停止，不强制覆盖。

在面板把 `qq-face-visual.tar.gz` 上传到 `/tmp`，执行：

```bash
mkdir -p /opt/maibot-qq-face-package
tar -xzf /tmp/qq-face-visual.tar.gz -C /opt/maibot-qq-face-package
python3 /opt/maibot-qq-face-package/install_qq_face_visual.py /opt/maibot-qq-deploy/maibot-qq
```

需要服务器已有 Python 3、Git、Docker Compose v2。安装器先完成补丁检查、配置解析、素材准备、候选 Compose 验证及备份，然后把当前容器（包括可写层中的主程序修复）保存为服务器本地恢复镜像，再只停止和重建 `maibot`，保留 SnowLuma/QQ 会话；健康检查最长等待 300 秒。报错时自动恢复备份配置并使用该恢复镜像启动原代码。恢复镜像会额外占用本机磁盘，只留在服务器，不要推送镜像仓库。

备份目录为 `/opt/maibot-qq/backups/qq-face-时间/`，包含私有配置，不能上传 GitHub。终端会打印该次安装独立可用的回退命令。也可手工执行：

```bash
python3 /opt/maibot-qq/backups/qq-face-时间/install_qq_face_visual.py --rollback /opt/maibot-qq/backups/qq-face-时间
```

`deploy.sh` 已接入 `compose.qq-face.yaml`；后续启动、停止、备份沿用它。回退后此文件保留仅含本地恢复镜像的配置，以保住原来的容器内修复。不要删除恢复镜像。直接调用 Compose 时也必须带两个 `-f`，否则会丢掉本次挂载和镜像选择。

升级官方适配器前先回退本覆盖配置，再改用仓库中包含补丁的新镜像，并移除本地镜像覆盖。新镜像在启动时对已安装的 Read GIF 应用同一份有版本检查的调色板修复；刚从市场安装后重启一次麦麦才会应用。现有实例使用本次安装器立即修复。Read GIF 市场升级会覆盖它，需要核对新版本是否已修复 APNG 倒序 seek 变黑的问题。

## 验证生效

用 QQ **新发**原生“虎虎生威”，再发原生“惊讶”（0）并询问样子/动作。后台入站应有图片，静态图可描述虎头帽和企鹅；惊讶动画应有多帧描述。手工打字 `[虎虎生威]` 仍是普通文本。旧消息不会自动补图或重新识别。

本地回归覆盖原字节保留、旧模式、缺图、不可信 ID、消息身份、多帧注入、缓存及颜色。模型调用在集成测试中替换为测试响应，生产视觉理解须用上述真实 QQ 消息验收。

素材来自 [QFace](https://github.com/koishijs/QFace)，固定版本 `c96fa14ff894147ac0442dda0fce6a4523e5fcbd`。腾讯素材版权归腾讯，包内包含来源说明；仓库只保存下载脚本。Read GIF 固定测试版本 `b69ed723156fd7a05d2af212c9881cf76602ab42`（v0.1.2）。
