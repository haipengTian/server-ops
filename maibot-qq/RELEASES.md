# 更新、回退和搬到新服务器

以后使用 [MaiBot QQ Docker](https://github.com/haipengTian/server-ops/actions/workflows/maibot-qq.yml) 成功运行发布的 `ghcr.io/haipengtian/maibot-qq:sha-…` 镜像，不再叠加临时安装包。一个提交对应核心修复、适配器、QQ 表情素材、糯糯生图插件和已支持的实例插件兼容修复。

## 当前服务器切到统一镜像

在面板终端取回对应版本的部署脚本，然后更新。两个占位值须来自**同一次成功构建**：

```bash
cd /opt/server-ops
git fetch origin codex/maibot-docker
git archive 完整提交号 maibot-qq | tar -x -C /opt/maibot-qq-deploy
cd /opt/maibot-qq-deploy/maibot-qq
bash deploy.sh update ghcr.io/haipengtian/maibot-qq:sha-12位提交号
```

脚本拉取镜像后逐文件比较当前核心、适配器源码。已知工具身份校验差异可升级；其他不一致会列出文件名，在停服前退出，应先把这些改动收进仓库。比较不输出源码或凭证。

通过后仅停止麦麦，保存独立回退脚本、插件源码/配置和服务器本地恢复镜像。更新 `.env`，撤下已识别的旧 `compose.qq-face.yaml` 本地镜像/表情挂载，由新镜像提供代码和素材。未知挂载或其他覆盖设置不会直接删除。QQ/SnowLuma 不重启。

更新不替换参考肖像，不清空聊天、记忆、表情、B站登录、QQ 登录或插件配置。第三方插件源码仍在 `/opt/maibot-qq/runtime/plugins`，更新不删除；完整备份一起带走。插件市场升级是独立操作，不随镜像更新自动进行。

## 后续更新仍用同一个入口

取回对应版本部署文件，再执行 `bash deploy.sh update 镜像标签`。不使用 `latest`。镜像启动时应用仓库里有版本检查的 Read GIF、日记/空间兼容修复，不强行覆盖未知版本。

`healthy` 只证明 HTTP 服务启动。实际验收检查 QQ 入站/回复、原生表情、联网、生图。失败后询问原因，再用新消息明确要求重画，检查真实状态与新任务。日记/空间发布由你按现有白名单发起，更新不会自动发说说。

## 回退保留当前聊天和照片

更新失败自动恢复旧插件和本地恢复镜像。终端打印独立的 `python3 …/release.py --ops … rollback …` 命令，之后也可执行。回退前的插件目录会改名保留，不删除后来的配置文件。

代码回退保留当前聊天数据库和照片，适用于本次固定 MaiBot 1.3.18 的兼容修复。将来升级上游或数据结构时需单独安排数据库迁移。恢复镜像只留服务器，不能推送 GHCR。

## 一份私有备份带走实例

统一镜像切换完成后执行：

```bash
cd /opt/maibot-qq-deploy/maibot-qq
bash deploy.sh portable-backup
```

暂停麦麦和 QQ，备份完整实例、现有插件源码配置、聊天/记忆/表情、参考图、QQ 登录数据、部署脚本和 `.env`，随后重新启动。日志、缓存和旧备份不重复打包。输出文件位于 `/opt/maibot-qq-backups/release-时间.tar.gz`。

**备份含 Key、登录状态和聊天内容**，只用服务器面板或受信任的私有传输保存，不放 GitHub、Release 或公开网盘。nginx 的域名、认证、证书仍按 server-ops 的 nginx 流程配置，不在机器人实例备份里。原有 `backup` 命令保留“备份后保持停止”的旧行为；长期迁移使用 `portable-backup`，同时记录镜像与部署文件。

## 新服务器恢复

1. 安装 Docker、Compose v2 和支持 `tarfile` data filter 的 Python 3（建议 3.12+），取回对应版本的部署脚本。
2. 停止旧服务器两个容器，确认同一 QQ 不会双实例在线。
3. 上传私有备份；新服务器 `/opt/maibot-qq` 必须不存在：

```bash
python3 /部署脚本目录/release.py restore /私有备份路径/release-时间.tar.gz
```

恢复会拉取备份记录的精确镜像，把数据放回原位置，部署文件放进独立的 `/opt/maibot-qq-restored-时间` 目录，不覆盖已有部署目录，也不自动登录 QQ。按终端输出执行该目录下的 `bash deploy.sh start --local-stopped`。

4. 调整域名指向并配置 nginx；检查 QQ 是否需要扫码、群聊/私聊范围及实际收发。正常后再停用旧服务器。
