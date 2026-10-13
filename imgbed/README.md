# CloudFlare ImgBed 个人版本部署

域名：`https://img.thpvip.xyz`。应用使用个人仓库 `haipengTian/CloudFlare-ImgBed` 构建的固定版本镜像，
本机仅开放 `127.0.0.1:7658`，由主机 nginx 提供 HTTPS。服务器操作由用户自行通过 SSH 执行，
密码、存储 AK/SK、Telegram Token 不需要交给协作者，也不要写入仓库或聊天。

## 当前状态

2026-10-13：本次部署基础基于实际获取的个人/官方共同基线
`0d219dd45f514265ba9cb17788059fd7a1b1240d`，产品版本 `2.7.7`。
本地维护与部署文件已准备；尚未发布个人镜像，也未连接服务器。
下面 `2.7.7-custom.1` 是计划中的首版命名，须先确认 GitHub 发布检查成功和镜像真实存在。
产品侧的发布及上游融合入口：`CloudFlare-ImgBed/docs/custom/README.md`。

## 1. 发布镜像并检查服务器

先将图床维护分支审查、合入个人 main 并推送，在 GitHub Actions 的 Personal Docker image 中
手动填入 `v2.7.7-custom.1` 做构建和文件测试。手动运行不发布；验证成功后在同一提交创建并推送该 tag，
等待 GHCR 发布成功。镜像支持 linux/amd64、linux/arm64；工作流只运行 amd64 容器验收，arm64 需额外验收。
首次 GHCR 包可能是私有的，公开包无需登录；私有包在服务器交互执行 `docker login ghcr.io -u haipengTian`。

本运维分支合入并推送后，在服务器 root 会话执行：

```bash
# 运维仓库不存在时：
git clone https://github.com/haipengTian/server-ops.git /opt/server-ops
# 已存在时先检查改动，再快进；不要覆盖服务器本地配置：
# git -C /opt/server-ops status --short
# git -C /opt/server-ops pull --ff-only
cd /opt/server-ops/imgbed
uname -m
free -h
df -h /opt
docker info >/dev/null
docker compose version
ss -ltn
```

需要 Bash、flock、openssl、awk、sed、realpath、tar、sha256sum、ss、curl、Docker/Compose 插件。
HTTPS 配置另外需要 nginx、certbot、getent、systemctl。Compose 须支持 `up --wait --wait-timeout`；
nginx 模板使用 `http2 on`，需要 nginx >= 1.25.1。默认应用内存上限 512 MiB、1 CPU，按同机容量调整。
确认 7658 未被其他服务占用。60GB 是整个服务器磁盘容量，操作系统、镜像、其他服务和备份也占空间。

## 2. 初始化与安装

```bash
cd /opt/server-ops/imgbed
# 先替换为实际已经成功发布的个人版本：
bash init.sh ghcr.io/haipengtian/cloudflare-imgbed:2.7.7-custom.1
vi .env
# 填写 CERTBOT_EMAIL；核对域名、资源上限、专用数据目录。
bash install.sh
bash status.sh
```

`.env` 使用 `KEY=value` 字面值，不加引号、空格或变量展开。init 自动生成 BASIC_PASS、AUTH_CODE、
AI_CONFIG_SECRET，文件权限为 0600；已有文件会保留。BASIC_USER 默认 admin。
用户在服务器本地查看 BASIC_PASS 登录管理端；AUTH_CODE 是用户页面/上传访问密码。
这些环境变量是初始配置，数据库里保存的设置优先；不要通过重新 init 重置已有认证和 AI 加密密钥。
管理页面改密码后，数据库保存的新密码会覆盖环境变量。不得清除管理员或上传认证，部署检查要求两者拒绝匿名请求。

应用数据为 `/opt/imgbed/app`，其中 `database.sqlite` 保存配置、索引和会话，`r2/` 保存本地对象，
另有分块暂存等文件；全部一起持久化。`state/` 保存镜像与操作记录，`backups/` 保存备份。
SELinux 挂载使用 `:Z`，目录应专属于图床。

安装先拉取镜像并解析固定 sha256，再等待容器健康。就绪检查加载实际持久化配置，要求管理员与上传密码非空，
并验证首页200、匿名管理/上传401、实际管理员用户名配错误密码401。
这些检查不证明外部存储已经配置成功。目标安装启动后检查失败会暂停容器并记录 failed-install，
保留本地日志/数据进行排查；首次安装没有旧版本可回滚。

## 3. 域名与 HTTPS

将 `img.thpvip.xyz` 的 A 记录指向服务器；仅在服务器确实支持 IPv6 时添加 AAAA。
首次使用 DNS only 验证主机 nginx。确保主机与云防火墙允许 80/443，不对公网开放 7658。
nginx 需处于运行状态；先检查 `nginx -v`、`systemctl status nginx`。

AlmaLinux 使用 firewalld 时可配置：

```bash
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --reload
getenforce
getsebool httpd_can_network_connect
# 仅在 SELinux Enforcing 且此项 off 时执行：
setsebool -P httpd_can_network_connect on
bash setup-nginx.sh
certbot renew --dry-run
systemctl list-timers --all | grep -i certbot
curl --fail https://img.thpvip.xyz/
```

setup-nginx 在发布站点前验证本地认证，使用 webroot 申请证书，检查 nginx 后重载。
失败会恢复本次修改前的站点与 map 文件；已有证书及续期 hook 保留。续期 hook 不等于自动续期 timer，
需核实系统已有 certbot 定时任务。模板允许 128 MiB 请求，适配 WebDAV；更大文件需确认前端分块行为。
当前 IP 头按直接访问 nginx 配置；启用 Cloudflare CDN 后另行配置可信代理来源。

## 4. 配置存储

这些渠道由项目已有功能提供，密钥在服务器管理页面配置，设置保存在 SQLite 中。
Docker 默认的 **Cloudflare R2 / R2_env 实际映射到服务器本地磁盘**，不是你的 Cloudflare 云存储桶。
Docker 接入真正的 R2 要添加 S3 渠道。

| 存储 | 配置位置及关键字段 | 建议 |
| --- | --- | --- |
| Cloudflare R2 | 上传设置 → S3；Endpoint `https://<账户ID>.r2.cloudflarestorage.com`，Region `auto`，Bucket、R2 S3 Access Key ID/Secret | 可作为主要存储，独立配置对象公共域名或通过图床 `/file/` 读取 |
| 七牛云 Kodo | 上传设置 → S3；使用对应区域的 S3 Endpoint、Region、**S3 空间名**、AK/SK | 使用 S3 接口；路径式可启用，按实际区域填写，不能把七牛上传域名当作 S3 Endpoint |
| Telegram | 上传设置 → Telegram；Bot Token、Chat ID，Bot 需能访问目标群组/频道 | 可选渠道；可用性与文件限制由 Telegram 和项目处理方式共同决定 |
| 本地磁盘 | 默认 Cloudflare R2 / R2_env 渠道，文件位于 `/opt/imgbed/app/r2` | 仅建议少量测试或受限使用；给该渠道设置容量限制 |

例如七牛华东-浙江：Endpoint `https://s3.cn-east-1.qiniucs.com`，Region `cn-east-1`。
其他区域见[七牛官方服务域名](https://developer.qiniu.com/kodo/4088/s3-access-domainname)。
七牛 S3 空间名可能与原空间名不同，需在控制台空间概览查看。官方支持 AWS Signature V4；
本项目已有自定义 Endpoint/Region/路径式支持，实际兼容性仍需你的 Bucket 上传、读取、删除验收。

对于 60GB 服务器，推荐先接 R2 或七牛作为主要存储，然后在上传设置里选择 S3 为默认渠道，
停用本地 R2_env 或限制容量，并核对自动重试不会意外回退本地。多渠道是上传目标选择，**不会自动复制备份**；
更换默认渠道也不会自动迁移既有文件，旧文件仍按原记录的渠道读取。
通过图床 `/file/` 读取外部存储时，数据会经过服务器，仍可能消耗服务器自身流量。
如果配置对象 CDN/公共域名并使用返回的直链，需另行核实公开访问、防盗链与权限需求。

截至 2026-10-13，[R2 标准存储官方价格](https://developers.cloudflare.com/r2/pricing/)：
每月免费 10GB-month、100万次 Class A、1000万次 Class B 请求；超额存储 `$0.015/GB-month`，
Class A `$4.50/百万次`，Class B `$0.36/百万次`，R2 公网出站流量免费。
若月均100GB、请求在免费额度内，存储费约 `$1.35/月`。
免费额度不适用于 Infrequent Access；开通计费、支付方式、其他 Cloudflare 服务和服务商自身收费以账户界面为准。

## 5. 实际验收

- 管理员能登录；匿名用户不能管理或上传，错误密码被拒绝。
- 每个启用渠道分别上传小图片，打开原图直链，对比内容；再测试删除。
- 确认对象确实写入预期 Bucket/Telegram/本地渠道，外部对象没有意外落到服务器磁盘。
- 测试目标大小的文件和分块上传，检查磁盘临时占用与内存。
- 重启容器后确认认证、渠道配置、索引与已有文件可用。
- 建立首次备份，并在隔离环境恢复配置、索引和本地文件；外部对象另行建立备份/版本保护。

## 6. 备份、升级与回滚

```bash
bash backup.sh
# 用实际成功发布的新版本替换：
bash update.sh ghcr.io/haipengtian/cloudflare-imgbed:2.7.7-custom.2
bash status.sh
# 只有人工审查 SQLite 迁移并确认向后兼容后：
bash rollback.sh --database-compatible
```

操作使用锁，避免安装、备份、升级同时执行。备份暂停应用写入，将整个 app 目录归档，
包括 SQLite/WAL、本地对象、分块暂存；同时保存配置、镜像摘要和 SHA256SUMS。
备份目录0700、文件0600，包含存储凭据与会话，需保护并建立异机副本。
FAILED 标记的备份不得作为恢复源。备份成功后恢复原运行状态；原本暂停的应用保持暂停。
外部 R2/S3/Telegram 的文件内容不在本地备份中；本地 SQLite 是恢复渠道信息与文件映射的重要组成部分。
本地文件大量增长时备份会增加磁盘占用与维护时间，定期人工核实有效副本后再清理旧备份。

升级先拉取目标镜像再停应用、备份、切换并验证。目标启动前失败会恢复原配置与原服务；
目标已经尝试启动时可能迁移了 SQLite，失败会保持暂停并保存 failed-upgrade，禁止自动切回旧代码。
--database-compatible 是操作者确认，不会自动证明迁移兼容。兼容性未知时应恢复与旧镜像配套的数据。

## 7. 不兼容迁移恢复

在隔离环境演练后，维护窗口内恢复到**未使用的新专用目录**，保留旧数据和故障现场。
这会回到备份时点，丢失其后新增的本地记录；外部对象不会自动回到相同时点。
只使用自己生成且可信的备份。先替换下列两个路径：

```bash
cd /opt/server-ops/imgbed
bash <<'RECOVERY'
set -euo pipefail
umask 077
source ./lib.sh
require_root
lock_operation
load_env
check_docker
backup=/opt/imgbed/backups/REPLACE_WITH_VALID_BACKUP
recovery=/opt/imgbed-recovery-REPLACE_WITH_DATE
[[ -d $backup && ! -e $backup/FAILED && ! -e $recovery ]]
(cd "$backup" && sha256sum -c SHA256SUMS)
image=$(cat "$backup/image")
validate_image "$image"
compose stop imgbed
cp .env "$backup/pre-recovery.env"
cp "$backup/deployment.env" .env
chmod 600 .env
set_config IMGBED_DATA_DIR "$recovery"
set_config IMGBED_IMAGE "$image"
load_env
mkdir -p "$recovery"/{app,state,backups}
chmod 700 "$recovery" "$recovery/state" "$recovery/backups"
tar -xzf "$backup/data.tar.gz" -C "$recovery/app"
compose pull
if ! wait_app; then
  compose stop imgbed
  die '恢复检查失败，保持暂停；检查配置、认证与应用日志'
fi
record_release restore
RECOVERY
```

失败时保持维护状态，检查当前配置和执行阶段，不要直接 install/update。恢复验收完成前保留原目录。
不同时间点的外部对象与索引需要核对，避免自动清理远端文件造成二次损失。

## 8. 排查与检查边界

```bash
bash status.sh
docker compose --env-file .env -f docker-compose.yml -p imgbed-custom logs --tail=100 imgbed
nginx -t
df -h /opt
du -sh /opt/imgbed/app /opt/imgbed/backups
```

不要运行会输出全部环境变量的 `docker compose config`；使用 `config --quiet`。
日志可能含文件路径、账号和请求信息，分享前脱敏。环境变量密码修改不生效时先核对管理端已有持久化设置。
自动检查：`bash imgbed/tests/run.sh`。本次实际验证及尚待验证事项见 [verification.md](verification.md)。
