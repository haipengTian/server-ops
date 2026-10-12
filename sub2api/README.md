# Sub2API 个人版本部署

域名：`https://proxy.thpvip.xyz`。应用仅监听主机 `127.0.0.1:8088`，主机 nginx 提供 HTTPS。
产品代码与镜像来自 `haipengTian/sub2api`，上游融合和发布见该仓库 `docs/custom/README.md`。
这里维护安装、证书、备份、升级与条件回滚，不需要向协作者提供 SSH 密码、私钥或模型 Key。

## 当前交付状态

本地部署文件已准备。首次个人镜像尚未发布；GitHub 连接已恢复，产品本地基线已同步到
实际核实的官方 main `ab80abc6d1f929a6864c8804fd077b509d21fda2`，维护改动尚未提交。
下文镜像 `0.2.15-custom.1` 是版本格式示例；必须替换成**实际成功发布**的个人版本。
未连接服务器，未现场验证 DNS、硬件、证书和真实模型调用。

## 1. 发布后再登录服务器

在产品仓库完成官方融合、检查和个人 Release，确认目标镜像的架构。
将本仓库部署文件合入并推送个人 `main`；服务器才能从 main 获取这些文件。

在服务器 root 会话执行（或先 `sudo -i`）：

部署文件尚未推送到仓库时，也可将本次提供的 `sub2api-deploy-2026-10-13.tar.gz`
上传到服务器 `/tmp`，按下面方式解压到运维目录：

```bash
mkdir -p /opt/server-ops
umask 022
tar --no-same-owner --no-same-permissions -xzf /tmp/sub2api-deploy-2026-10-13.tar.gz -C /opt/server-ops
```

包内包含部署脚本、操作说明和非敏感配置模板。解压后跳过 clone 步骤，继续环境检查。

```bash
# 新服务器未有运维仓库时：
git clone https://github.com/haipengTian/server-ops.git /opt/server-ops
# 已有仓库时：先检查本地改动，再快进，不重新 clone。
# git -C /opt/server-ops status --short
# git -C /opt/server-ops pull --ff-only
cd /opt/server-ops/sub2api
uname -m
free -h
df -h /opt
docker info >/dev/null
docker compose version
ss -ltn
```

需要 Docker Engine/Compose 插件，以及 `bash`、`flock`、`openssl`、`curl`、`tar`、`sha256sum`、
`realpath`、`awk`、`sed`、`ss`、`nginx`、`certbot`、`systemctl`。现有 AlmaLinux 服务器可检查已安装包；
缺少基础工具时通过现有软件源安装，例如 `dnf install openssl util-linux curl tar coreutils iproute nginx certbot`。
Compose 必须支持 `up --wait --wait-timeout`。nginx 至少 1.25.1（模板使用 `http2 on`）。
nginx 应处于运行状态；全新安装后可先执行 `systemctl enable --now nginx`。

确认 8088 未被其他服务占用。默认三服务内存上限共 2560 MiB，另需操作系统和现有服务容量；
内存紧张时先调整 `.env`，不要照搬上限。PostgreSQL 18/Redis 8 大版本沿用当前产品部署配置，
后续大版本迁移另行处理。底层镜像可在 `.env` 追加实际 sha256 以固定补丁内容。

GHCR 包公开时直接拉取即可。私有包在服务器本地用具有 `read:packages` 权限的凭据登录，
例如交互执行 `docker login ghcr.io -u haipengTian`。不要把 token 写入 Git 或聊天。

## 2. 初始化与启动

```bash
cd /opt/server-ops/sub2api
bash init.sh ghcr.io/haipengtian/sub2api:0.2.15-custom.1
vi .env
# 填写实际 ADMIN_EMAIL；核对内存/CPU和专用数据目录，其余密钥保留自动生成值。
bash install.sh
bash status.sh
```

所有入口使用 `bash 脚本.sh`，无需修改可执行位。配置是 `KEY=value` 字面值；不加引号、变量展开或行尾注释。
初始化只生成本地密钥，已有 `.env` 会保留。不要在容器已有数据时重新生成数据库、JWT 或 TOTP 密钥。
密码仅存服务器 `.env`（0600）；管理员密码可在服务器本地查看 `ADMIN_PASSWORD`，首次登录后修改。
备份会包含账户配置与密钥，必须按敏感数据保护并建立异机副本。

安装先拉取镜像，再将应用镜像解析为 sha256，等待三个服务健康并访问本机 `/health`。
数据分别位于 `/opt/sub2api/app`、`postgres`、`redis`、`state`、`backups`。
使用独立 Compose 项目 `sub2api-custom`；数据库与 Redis 不发布主机端口。
首次启动失败时保留日志和数据，再修复，不存在可回滚的旧部署版本。

## 3. 域名与 HTTPS

将 `proxy.thpvip.xyz` 的 A 记录解析到服务器；仅在服务器确实支持 IPv6 时设置 AAAA。
首次按直接访问主机 nginx 配置，Cloudflare 等代理先使用 DNS only。
确保云防火墙与主机防火墙允许 80/443；无需对公网开放 8088、5432、6379。
若使用 firewalld，可执行：

```bash
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --reload
```

AlmaLinux 的 SELinux 若为 Enforcing，先允许主机 nginx 连接应用：

```bash
getenforce
getsebool httpd_can_network_connect
# 仅在 Enforcing 且此项 off 时需要：
setsebool -P httpd_can_network_connect on
```

三个专用数据挂载使用 `:Z`。它会更改这些目录的 SELinux 标签，不应让其他服务共用这些目录。

```bash
bash setup-nginx.sh
certbot renew --dry-run
systemctl list-timers --all | grep -i certbot
curl --fail https://proxy.thpvip.xyz/health
```

脚本安装独立站点与 WebSocket map，申请 webroot 证书，检查配置后重载 nginx。
失败时恢复本次修改前的这两个 nginx 文件。续期 hook 在签发成功后检查并重载 nginx。
需要确保系统已有 certbot 的定时续期任务；不同发行版 timer 名称不同，不能仅凭安装 hook 认定自动续期已启用。
模板允许流式响应、WebSocket、长请求与 128 MiB 上传，覆盖来访请求中的客户端 IP 头。
将来启用 CDN 代理时需另行设置可信真实 IP 来源，否则应用记录的是代理 IP。

## 4. 完成真实业务验收

`/health` 当前只是基础存活信号。请登录管理端并完成：

- 管理员登录，配置一个上游账号、分组与 API Key。
- 用该 Key 发起目标模型的普通请求和流式请求，核对响应与结束状态。
- 检查请求用量、余额或订阅扣费，验证分组与模型定价。
- 重启应用后确认账户配置和使用记录仍存在。
- 首次备份，并在隔离环境恢复数据库与应用配置。

真实 Key 只在服务器管理页面配置。必要时清理测试账号和 Key。

## 5. 备份与升级

```bash
bash backup.sh
# 镜像版本为格式示例，先替换为实际已发布的新版本：
bash update.sh ghcr.io/haipengtian/sub2api:0.2.15-custom.2
bash status.sh
```

备份/升级使用维护窗口：暂停应用写入，保留 PostgreSQL 运行，生成数据库逻辑备份、
应用目录归档、部署配置和原镜像摘要，生成 SHA256SUMS。
备份目录为 0700，文件为 0600；`pg_restore --list` 检查归档可识别，这不能代替实际恢复演练。
`FAILED` 标记的目录不作为恢复源；失败现场保留供排查。

升级先拉取目标镜像，再暂停应用、备份、切换镜像与验收。
目标镜像尚未尝试启动时出错，恢复原配置并重新启动原容器。
目标镜像启动后可能已经执行迁移；失败时暂停应用并保存 `failed-upgrade`，不自动恢复旧代码。
每次成功操作记录镜像与 history；升级后仍要验收真实网关与计费。
备份脚本会恢复原先运行的应用；若应用原本暂停，会保留暂停状态。

## 6. 回滚与不兼容迁移恢复

已审查 SQL 迁移并确认数据库向后兼容时，才执行：

```bash
bash rollback.sh --database-compatible
```

它保留回滚前备份，切换 `previous-image`。此参数是操作者的确认，不会自动证明迁移兼容。
兼容性未知或不兼容时，恢复配套数据会回到备份时间，丢失其后的新增记录。
保持维护窗口并保留故障现场。在隔离环境演练后，可按下面方式**恢复到新的专用数据目录**，保留旧数据目录：

```bash
cd /opt/server-ops/sub2api
bash <<'RECOVERY'
set -euo pipefail
umask 077
source ./lib.sh
require_root
lock_operation
load_env
check_docker
# 必须改为人工核实的完整有效备份目录和未使用的新目录：
backup=/opt/sub2api/backups/REPLACE_WITH_VALID_BACKUP
recovery=/opt/sub2api-recovery-REPLACE_WITH_DATE
[[ -d $backup && ! -e $backup/FAILED && ! -e $recovery ]]
(cd "$backup" && sha256sum -c SHA256SUMS)
image=$(cat "$backup/image")
validate_image "$image"
compose stop
# 保存当前部署配置，保留旧数据目录；不要删除 postgres/redis。
cp .env "$backup/pre-recovery.env"
cp "$backup/deployment.env" .env
chmod 600 .env
set_config SUB2API_DATA_DIR "$recovery"
set_config SUB2API_IMAGE "$image"
load_env
mkdir -p "$recovery"/{app,postgres,redis,state,backups}
chmod 700 "$recovery" "$recovery/state" "$recovery/backups"
tar -xzf "$backup/app.tar.gz" -C "$recovery/app"
compose pull
compose up -d --wait --wait-timeout "$SUB2API_WAIT_SECONDS" postgres redis
compose exec -T postgres pg_restore --exit-on-error --no-owner \
  -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "$backup/database.dump"
if ! wait_app; then
  compose stop sub2api
  die '恢复后的应用未通过检查，保持暂停，请检查恢复日志'
fi
record_release restore
RECOVERY
```

该人工恢复过程会在出错处停止；失败后不要直接 install/update，先检查当前配置和恢复阶段。
Redis 从空目录启动，不恢复缓存/会话；应用启动前先恢复数据库。
恢复完成后验证 HTTPS、管理员、账号/Key、网关与计费，并建立新的有效备份。
原目录与故障镜像应保留至恢复验收完成。备份文件来源必须可信。

## 7. 排查与验证边界

```bash
bash status.sh
docker compose --env-file .env -f docker-compose.yml -p sub2api-custom logs --tail=100 sub2api
docker compose --env-file .env -f docker-compose.yml -p sub2api-custom logs --tail=100 postgres redis
nginx -t
```

日志可能包含账户或请求信息，分享前脱敏。不要使用会展开并打印全部密钥的 `docker compose config`；
脚本只执行 `config --quiet`。

自动检查入口：`bash sub2api/tests/run.sh`（Linux，含真实归档/校验和模拟 Docker/HTTP/DB）。
GitHub 工作流还执行 Bash 语法、ShellCheck 和合成密钥的 Compose 配置检查。
模拟测试不证明真实 PostgreSQL/Redis 镜像、nginx、证书或产品迁移已经通过服务器验收。
本次实际验证记录见 [verification.md](verification.md)。
