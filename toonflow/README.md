# 部署 Toonflow 个人镜像

打开 `https://toonflow.thpvip.xyz`，使用自己设置的管理员账号登录工作台。
主机 nginx 提供 HTTPS，容器仍只使用 `127.0.0.1:3014`，数据保存在 `/opt/toonflow/app`。

源码仓库：<https://github.com/haipengTian/Toonflow-app>。
基于上游 `v2.0.9`，当前镜像为 `ghcr.io/haipengtian/toonflow:2.0.9-custom.3`，包含鉴权与 Muse 供应商，支持匿名拉取。
镜像仅构建 Linux amd64；服务器用 `uname -m` 确认架构为 `x86_64`。

## 安装

将 `toonflow.thpvip.xyz` 的 A/AAAA 记录指向服务器；仅保留实际可达的地址。
服务器已有 Docker Engine、Compose 插件，所需命令包括 `flock`、`ss`、`realpath`、`tar`、`curl` 和 `python3`。
主机 nginx 和证书工具沿用仓库 `nginx/` 的安装方式，HTTP/HTTPS 端口需可从公网访问。
在 `/opt/server-ops` 更新到包含 `toonflow/` 的版本，然后执行：

```bash
cd /opt/server-ops/toonflow
sudo bash init.sh ghcr.io/haipengtian/toonflow:2.0.9-custom.3
sudo bash setup-auth.sh admin https://toonflow.thpvip.xyz
sudo bash install.sh
sudo bash setup-nginx.sh tianhaipeng34@gmail.com
sudo bash status.sh
```

首次安装会准备镜像运行用户可写的 `app/workspaces/myProject`，并为 SELinux 主机设置
Docker 绑定挂载标签。登录页、鉴权状态和匿名业务接口拒绝检查通过后，容器才算就绪。
重复运行 `init.sh` 保留现有 `.env`；后续换版本使用 `update.sh`。
首次 GHCR 发布需将包设为 public，或由用户在服务器本地登录私有 GHCR。

`.env` 可调整本机端口、专用数据目录和资源上限。默认上限为 2 GiB 内存、2 CPU，
这是 API 创作工作台的资源上限；不包含本地大模型或 ComfyUI 算力。
修改后重新执行 `install.sh` 重建容器，单纯 restart 不会更新容器配置。

## 从无鉴权版本升级

原有 `.env` 不会被初始化覆盖。先交互设置管理员密码，再更新到鉴权镜像：

```bash
cd /opt/server-ops/toonflow
sudo bash setup-auth.sh admin https://toonflow.thpvip.xyz
sudo bash update.sh ghcr.io/haipengtian/toonflow:2.0.9-custom.3
sudo bash setup-nginx.sh tianhaipeng34@gmail.com
```

## 登录并创作

浏览器打开 `https://toonflow.thpvip.xyz`，使用 `admin` 和终端设置的密码。
密码只在服务器终端输入两次，不会显示，也不写入命令历史；`.env` 权限为 600，只保存随机盐和 scrypt 摘要。
首次进入的 Toonflow 官方账号页与工作台管理员是两回事；使用自有模型可选择「配置第三方模型」或「稍后配置」。

1. 在设置中配置语言模型及图片、视频模型供应商。
2. 选择服务器工作区中的 `myProject`，创建并保存画布。
3. 生成一次图片或视频，刷新页面并重开画布，检查素材和生成结果。

模型密钥由用户直接在页面配置，不写进仓库或镜像。默认数据目录包括配置、插件、技能、
画布、会话和媒体文件，备份需完整保存 `app/`。

首页侧栏「登录管理」可退出当前浏览器；会话最长 24 小时，重启后需要重新登录。
更改密码时重跑 `setup-auth.sh`，然后 `install.sh` 重建同版本容器，让旧会话全部失效。
`setup-nginx.sh` 先确认应用启用鉴权，并检查匿名业务接口返回 401，才调用公共 nginx 配置入口。
公网健康检查不会读取项目或模型密钥。MCP/A2A 仍使用各自凭据，不接受工作台密码作为 Bearer。
这是单管理员私人工作台，登录后可访问所有项目和配置，不提供多人数据隔离。

## 配置 Muse 图片和视频

`custom.3` 内置「Sub2API / Muse」。升级并刷新页面后，打开「设置 → 媒体模型」，
找到「Sub2API / Muse」并点击「编辑模型」，填写 Sub2API 地址和 API Key 后保存。
地址可填 `https://proxy.thpvip.xyz`，也支持末尾带 `/v1`；无需导入 `.ts` 文件。
若该供应商未安装，可用「添加供应商」中的同名选项添加。

画布的图片节点选择「Muse 图片」（`muse-image`），视频节点选择「Muse 视频」（`muse-video`）。
支持最多 4 张参考图，视频默认请求 6 秒，提供 480p、720p、1080p；
Muse 按提示词理解比例、时长和分辨率，实际成品可能不同。
视频自动查询原任务并通过 Sub2API 鉴权下载到工作区，刷新或重启后可复查原任务。

Sub2API 须使用 `0.2.19-custom.2` 或更新版本，Key 所属分组放行两个模型并允许媒体生成。
模型价格在 Sub2API 配置。更新后由用户用自己的 Key 验收一次图片和一次视频生成、播放及扣费。

## 备份和升级

```bash
cd /opt/server-ops/toonflow
sudo bash backup.sh
sudo bash update.sh ghcr.io/haipengtian/toonflow:2.0.9-custom.3
```

升级命令中的版本须先实际发布。脚本先拉新镜像，成功后暂停应用、备份完整 `app/`、
记录旧镜像，再切换版本。备份位于 `/opt/toonflow/backups/<时间.随机后缀>/`，
`COMPLETE` 表示归档和部署配置均已保存。备份包含模型密钥，仅限管理员读取。
独立备份结束后会恢复原来运行的容器。

新版本启动失败时会尝试停止新容器，保留现场数据和升级前备份。
为避免旧代码直接读取已迁移的数据，恢复时使用新的数据目录：

```bash
sudo bash <<'BASH'
set -euo pipefail
cd /opt/server-ops/toonflow
docker compose stop toonflow
# 先用 last-backup 找到本次升级前备份，再把下面的示例路径换成实际值。
cat /opt/toonflow/state/last-backup
backup=/opt/toonflow/backups/实际备份目录
test -f "$backup/COMPLETE"
# 选一个从未使用过的目录；已存在时 mkdir 会失败，请不要覆盖它。
recovery=/opt/toonflow-recovery-20261101
mkdir -m 700 "$recovery"
mkdir "$recovery/app"
tar --numeric-owner -xzf "$backup/data.tar.gz" -C "$recovery/app"
cp .env /opt/toonflow/state/failed-deployment.env
cp "$backup/deployment.env" .env
sed -i "s|^TOONFLOW_DATA_DIR=.*|TOONFLOW_DATA_DIR=$recovery|" .env
bash install.sh
bash status.sh
BASH
```

恢复需要已安装版本的 Toonflow 部署脚本与备份中的 Compose 兼容；若部署脚本也曾升级，
先检出匹配的 server-ops 版本并使用备份中的 `docker-compose.yml`。
原数据目录保留，恢复后需重新打开项目并验证模型调用。

## 查看状态与日志

```bash
cd /opt/server-ops/toonflow
sudo bash status.sh
sudo docker compose logs --tail 100 toonflow
```

容器健康检查验证登录页、鉴权状态和匿名 API 拒绝；模型可用性、原项目和生成结果需要页面实际操作确认。
服务器安装、DNS、证书和真实模型生成由服务器执行后验收。
本地部署脚本检查入口为 `bash toonflow/tests/run.sh`，其中 Docker 是隔离替身，
项目备份使用真实文件和 tar；它不代表服务器或模型生成验收。
