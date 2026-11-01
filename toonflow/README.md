# 部署 Toonflow 个人镜像

在服务器拉取自己 GHCR 的固定版本，打开画布后配置模型并选择工作区。
默认使用 `127.0.0.1:3014`，数据保存在 `/opt/toonflow/app`。

源码仓库：<https://github.com/haipengTian/Toonflow-app>。
首版计划基于上游 `v2.0.9`，发布镜像 `ghcr.io/haipengtian/toonflow:2.0.9-custom.1`。
须先完成源码仓库 fork、提交、推送标签和 Actions 发布，再执行以下安装命令。
镜像仅构建 Linux amd64；服务器用 `uname -m` 确认架构为 `x86_64`。

## 安装

服务器已有 Docker Engine、Compose 插件，所需命令包括 `flock`、`ss`、`realpath` 和 `tar`。
在 `/opt/server-ops` 更新到包含 `toonflow/` 的版本，然后执行：

```bash
cd /opt/server-ops/toonflow
sudo bash init.sh ghcr.io/haipengtian/toonflow:2.0.9-custom.1
sudo bash install.sh
sudo bash status.sh
```

首次安装会准备镜像运行用户可写的 `app/workspaces/myProject`，并为 SELinux 主机设置
Docker 绑定挂载标签。网页和工作区 API 通过检查后，容器才算就绪。
重复运行 `init.sh` 保留现有 `.env`；后续换版本使用 `update.sh`。
首次 GHCR 发布需将包设为 public，或由用户在服务器本地登录私有 GHCR。

`.env` 可调整本机端口、专用数据目录和资源上限。默认上限为 2 GiB 内存、2 CPU，
这是 API 创作工作台的资源上限；不包含本地大模型或 ComfyUI 算力。
修改后重新执行 `install.sh` 重建容器，单纯 restart 不会更新容器配置。

## 从电脑访问

在自己的电脑执行，将用户名、服务器地址、SSH 端口换为实际值：

```bash
ssh -N -p SSH端口 -L 3014:127.0.0.1:3014 用户名@服务器地址
```

保持 SSH 连接，浏览器打开 `http://127.0.0.1:3014`：

1. 在设置中配置语言模型及图片、视频模型供应商。
2. 选择服务器工作区中的 `myProject`，创建并保存画布。
3. 生成一次图片或视频，刷新页面并重开画布，检查素材和生成结果。

模型密钥由用户直接在页面配置，不写进仓库或镜像。默认数据目录包括配置、插件、技能、
画布、会话和媒体文件，备份需完整保存 `app/`。

Toonflow 当前自部署页面和业务 API 没有独立登录鉴权。
需要公网域名时，应先确定域名和认证入口，再接主机 nginx；
不要直接使用公共 `nginx/add-site.sh` 将它作为无认证应用公开。

## 备份和升级

```bash
cd /opt/server-ops/toonflow
sudo bash backup.sh
sudo bash update.sh ghcr.io/haipengtian/toonflow:2.0.9-custom.2
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

容器健康检查验证首页和真实工作区接口；模型可用性、原项目和生成结果需要页面实际操作确认。
本地部署脚本检查入口为 `bash toonflow/tests/run.sh`，其中 Docker 是隔离替身，
项目备份使用真实文件和 tar；它不代表服务器或模型生成验收。
