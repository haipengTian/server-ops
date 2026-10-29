# 使用 GitHub Actions 镜像部署邮件中心

GitHub Actions 构建并验证镜像，发布到 GHCR；服务器拉取指定版本，复用现有 Docker、主机 nginx 和 Certbot。服务器无需前后端源码、Go、Node.js 或 pnpm。

网页入口仅绑定 `127.0.0.1:3013`，数据库、API 和前端均在内部网络。可选 Postfix 接收公网 TCP 25，精确限定收件域名，转给内部 Go SMTP；它不提供对外发信中继。

2026-10-28 用户提供的服务器检查：CentOS Stream 9 / x86_64，6 核、12 GiB 内存（约 10 GiB 可用）、约 102 GiB 可用磁盘，Compose v5.6.1。80/443 已监听，25/3013/8089/2525 未监听；Telegram 主域名 HTTPS 返回 302。真实邮箱、机器人和公网入站 25 仍需联调。

## 先由 Actions 发布三个镜像

| 代码仓库 | 构建内容 | 发布 tag 示例 | GHCR 镜像示例 |
|---|---|---|---|
| `haipengTian/mail-center` | Go API、同步与推送、本机管理员工具 | `v0.1.0` | `ghcr.io/haipengtian/mail-center:v0.1.0` |
| `haipengTian/mail-center-ui` | Next.js 网页 | `v0.1.0` | `ghcr.io/haipengtian/mail-center-ui:v0.1.0` |
| `haipengTian/server-ops` | Postfix 收信入口 | `mail-center-v0.1.0` | `ghcr.io/haipengtian/mail-center-smtp:v0.1.0` |

镜像名称根据实际 GitHub 仓库或 owner 自动生成并转为小写。2026-10-29 首版三个版本 tag 的 Actions 均已完成 success，表中 `v0.1.0` 镜像已发布；精确摘要和运行链接见 `VERIFICATION.md`。前后端源代码仓库均为私有。后续版本也须确认发布成功后才运行服务器安装。

前后端 `.github/workflows/image.yml` 在 main 提交、PR 和手动运行时执行检查与容器验证；推送 `vX.Y.Z` tag 才发布镜像。Postfix 使用本仓库 `.github/workflows/mail-center-images.yml`，推送 `mail-center-vX.Y.Z` tag 才发布。普通 main/PR/手动检查均不发布镜像。

流水线先测试、构建并启动镜像进行验证，再给**同一已验证镜像**加版本和提交号 tag 并推送；不会在验证后重新构建另一份。当前构建 `linux/amd64`，适用于上述 x86_64 服务器。Actions 使用仓库自带 `GITHUB_TOKEN`，job 声明 `packages: write`，不需要在代码中存放发布 Token 或服务器 SSH 凭据。

前后端分别在自己的仓库创建并推送 `v0.1.0` tag；`server-ops` 创建并推送 `mail-center-v0.1.0` tag。每个成功发布的 Actions Summary 都会给出对应的 `MAIL_CENTER_*_IMAGE=ghcr.io/...@sha256:...`，推荐将这些摘要引用填入服务器 `.env`。固定版本与 `sha-提交号` 也支持，不接受 `latest`、`main` 或未标记版本。

首次创建 GHCR 包后需确认其访问权限：公开镜像可直接拉取；私有镜像由你在服务器执行 `docker login ghcr.io -u haipengTian`，交互输入有 `read:packages` 权限的令牌。凭据仅由你在终端填写，不放入聊天、仓库或示例配置。

## 服务器初始化与启动

先将本次 `server-ops` 变更发布，再在服务器同步部署文件：

```bash
cd /opt/server-ops
git pull --ff-only
cd mail-center
bash init.sh mail.thpvip.xyz inbox.thpvip.xyz mx.thpvip.xyz
```

三参数形式保留，初始化会填写上表的 `v0.1.0` 首发镜像。需要其他已发布版本或摘要时，可以传六个参数：

```bash
bash init.sh mail.thpvip.xyz inbox.thpvip.xyz mx.thpvip.xyz \
  ghcr.io/haipengtian/mail-center:v0.1.0 \
  ghcr.io/haipengtian/mail-center-ui:v0.1.0 \
  ghcr.io/haipengtian/mail-center-smtp:v0.1.0
```

也可在初始化后自行编辑 `.env` 中的三条镜像引用，再执行：

```bash
bash install.sh
bash bootstrap-admin.sh
bash status.sh
```

`init.sh` 只在新目录生成服务器本地数据库密码，已有 `.env` 或数据不会被覆盖。`install.sh` 拉取 PostgreSQL、API、网页和内部 nginx 镜像，全部拉取成功才启动，启动时禁止构建和再次拉取。它不开放 SMTP，也不修改 DNS、主机 nginx、防火墙或其他应用。

管理员由 `bootstrap-admin.sh` 在你的 SSH 终端隐藏读取密码，经标准输入交给服务器本机命令创建；不写入参数或配置，已有管理员不能覆盖。公开网关拒绝 HTTP 初始化接口。

若服务器不使用 Git 同步，可在 Windows 本运维目录执行 `./export-bundle.ps1`，上传生成的 `mail-center-ops-时间.tar.gz` 并解压到尚不存在的 `/opt/server-ops/mail-center`。这个包只含部署脚本、Compose、网关配置和公共 nginx 工具；不含应用源码、Dockerfile、镜像、数据或真实 `.env`，服务器仍通过 GHCR 拉取镜像。

若已经用之前的源码部署版生成 `.env`，保留原密码及 `data/`，补入 `MAIL_CENTER_API_IMAGE`、`MAIL_CENTER_WEB_IMAGE`、`MAIL_CENTER_SMTP_IMAGE` 三条已发布镜像即可。旧 `MAIL_CENTER_VERSION` 不再决定镜像；本地构建目录不再参与生产启动。旧格式备份先用同版本部署脚本恢复，再迁移镜像配置。

## 接入网页 HTTPS

先添加 `mail.thpvip.xyz` 的 A 记录指向服务器公网 IPv4，首次验收建议使用“仅 DNS”，确保公网 80/443 可达。网页域名可在首次 `init.sh` 时替换。

```bash
bash setup-web.sh 你的证书联系邮箱
```

在 `https://mail.thpvip.xyz` 登录。公共 nginx 工具复用已有 nginx，不重新安装主机环境；已有其他入口管理的同名站点配置会被保留并报错。证书签发或配置检查失败会恢复原站点，续期依赖现有 Certbot 定时器。

前端生产镜像使用同域 `/api/`，后端 `ALLOWED_ORIGIN` 为正式 HTTPS 地址，Cookie 启用 Secure。无需开放 8089 或额外 API 域名。Google OAuth 可选：在服务器 `.env` 填客户端参数，并在 Google 配置回调 `https://网页域名/api/v1/accounts/gmail/callback`；重新创建 api 容器后生效。

先添加一个真实 QQ、网易或 Gmail 账号，测试连接并同步。初次同步完成后，再配置 Telegram、发送测试并开启推送，避免首次导入的历史邮件集中通知。

## 接入自建域名收信

网页上线不依赖这一步。先添加 `mx.thpvip.xyz` 的 A 记录，指向服务器公网 IPv4，必须为**仅 DNS**。保持原 `inbox.thpvip.xyz` MX，直到完成服务和端口验证。

```bash
bash enable-smtp.sh 你的证书联系邮箱
bash status.sh
```

脚本先拉取指定的 SMTP 镜像，再为 MX 主机申请证书、复制到本服务私有 TLS 目录，注册独立续期 hook 并启动 Postfix。它不修改其他服务证书目录的权限。Postfix 支持 STARTTLS，队列持久化到 `data/smtp-queue`；公网入口大小上限为 25 MiB。

在项目配置中将 SMTP 收件域名设为 `inbox.thpvip.xyz`。服务器防火墙、云安全组和供应商均须允许入站 **TCP 25**。若启用了 firewalld，在实际生效的 zone 开放 SMTP；脚本不会自动修改防火墙。

在 Windows 电脑验证公网连接：

```powershell
Test-NetConnection mx.thpvip.xyz -Port 25
```

这只证明该电脑到服务器的端口可达。最终还需真实外部邮箱投递；服务器供应商的出站 25 限制不能替代入站检查。服务和网络验证通过后切换 DNS：

| 类型 | 名称 | 内容 | 设置 |
|---|---|---|---|
| A | mx | 服务器公网 IPv4 | 仅 DNS |
| MX | inbox | mx.thpvip.xyz | 优先级 10 |

移除 `inbox` 下原 Cloudflare MX，保留其他域名的 MX。用外部邮箱发到 `test@inbox.thpvip.xyz`，核对浏览器与 Telegram。DNS 仍可由 Cloudflare 托管，不依赖 Workers；本项目只收信，不提供对外发信功能。

## 更新、备份与恢复

### 小窗口紧凑阅读与邮件列表等高：Web v0.1.6

已有 API v0.1.1 的部署，只升级 Web 到 v0.1.6；API 和 SMTP 镜像保持不变，无需再次重解析旧邮件。宽度至少 1024px、窗口高度不超过 800px 时，右侧统计和邮件头部使用紧凑布局，阅读区按剩余高度分配，列表与正文独立滚动；左侧菜单与正文字号不变。保留 v0.1.5 的邮件列表等高、v0.1.4 的已读状态静默更新，以及主动收取、自动更新和紫色信封图标。

“收取邮件”按钮在当前邮箱只收取对应账号，全部邮件页收取所有已启用账号，暂停账号保持暂停。页面在前台每 5 秒更新本地列表，后台仍约每分钟连接外部邮箱收取，不是 IMAP IDLE 实时推送。

在 [Actions](https://github.com/haipengTian/mail-center-ui/actions) 确认 v0.1.6 标签的发布工作流成功后执行（备份期间服务会短暂停止并自动恢复）：

```bash
cd /opt/server-ops/mail-center
bash backup.sh &&
sed -i 's|^MAIL_CENTER_WEB_IMAGE=.*|MAIL_CENTER_WEB_IMAGE=ghcr.io/haipengtian/mail-center-ui:v0.1.6|' .env &&
bash install.sh &&
bash status.sh
```

刷新浏览器确认版本 0.1.6，缩小桌面窗口，检查统计与邮件头部收紧、正文直接可见，列表和正文各自滚动，侧栏不变。长短主题、摘要及不同推送状态的邮件列表项应保持等高，长主题完整内容和附件仍可在阅读区查看。点击未读邮件，检查列表不闪空、阅读位置保留、未读数正常减少；在未读页打开后，该邮件应从列表移除但正文继续显示。网站图标仍缓存时关闭该标签页后重新打开；部分浏览器标签页只显示静态图形，系统减少动态效果时也会静止。进入已连接邮箱，点“收取邮件”，检查收取中、完成时间及新邮件出现。也可从 QQ 等原邮箱收到一封新信后等待后台收取，确认页面无需手动刷新便更新。暂停或仅 SMTP 收件的邮箱显示“刷新列表”；失败会显示原因与邮箱账号页入口。若仍使用 API v0.1.0，先按下一节完成 v0.1.1 升级。

### 从 v0.1.0 升级到 v0.1.1

这次更新 API 和 Web，SMTP 仍使用 v0.1.0。修复缺少 To 头邮件导致同步卡住、中文发件人编码与正文排版，并显示同步失败的阶段和原因类型。两个 v0.1.1 发布工作流成功后，在现有部署目录执行：

```bash
cd /opt/server-ops/mail-center
bash backup.sh &&
sed -i \
  -e 's|^MAIL_CENTER_API_IMAGE=.*|MAIL_CENTER_API_IMAGE=ghcr.io/haipengtian/mail-center:v0.1.1|' \
  -e 's|^MAIL_CENTER_WEB_IMAGE=.*|MAIL_CENTER_WEB_IMAGE=ghcr.io/haipengtian/mail-center-ui:v0.1.1|' .env &&
bash install.sh &&
docker compose exec -T api /app/mail-reparse &&
docker compose exec -T api /app/mail-reparse --apply &&
bash status.sh
```

备份成功后才会更新；只替换两条镜像配置，保留现有密码、域名与数据。`mail-reparse` 先检查原始邮件，再重建已导入邮件的显示字段，不修改已读、附件、ID 或 Telegram 队列。失败数不为 0 时命令会停下，保留对应邮件原状，检查原始文件后再重试。

刷新浏览器，确认侧栏版本 0.1.1。进入邮箱账号页点一次“立即同步”；如仍报错，记录新的完整提示，或查看 `docker compose logs --tail 80 api`。新版同步日志仅记录账号 ID、游标和安全错误分类，旧版通用错误不能用来确认 QQ 限流。

### 其他版本更新

Actions 新版本发布成功后，先备份，再编辑 `.env` 的镜像引用并运行 `install.sh`。如果更新 SMTP 镜像，再执行 `enable-smtp.sh 证书联系邮箱`；该命令会复用有效证书并重新创建 SMTP 服务。

```bash
bash backup.sh
# 自行编辑 .env 的镜像引用，保留原密码和域名。
bash install.sh
bash status.sh
```

备份会短暂停止网关、API 和已启动的 Postfix，导出 PostgreSQL、邮件及附件文件、加密密钥、SMTP 队列、TLS、`.env` 和镜像记录。完成或失败均尝试恢复原来运行的服务。`backups/` 权限 700，归档权限 600；包含敏感数据，应另存到安全位置。备份期间外部邮件发送方通常会重试，仍须确认最终投递结果。

恢复使用同版本部署文件，目标必须是没有 `.env` 和 `data/` 的全新目录。新服务器可以直接恢复；同机需先停止并移除旧同名 Compose 项目的容器，保留原数据和备份，不使用 `-v`。脚本在同名项目仍存在时拒绝恢复，且不安装目标配置。

```bash
bash restore.sh /安全路径/备份.tar.gz
bash install.sh
```

恢复后检查管理员、邮件和文件，再接入网页和 SMTP。保留旧镜像与备份；数据库变化可能限制镜像回退，必要时在新目录从上线前备份恢复。不要删除数据或重建 `account-encryption.key` 作为故障处理。当前完整 Linux 备份恢复演练仍待完成，验证边界见 `VERIFICATION.md`。

```bash
docker compose logs --tail 100 api gateway web
docker compose --profile smtp logs --tail 100 smtp
```

修改 `.env` 后需重新创建对应容器，单纯 restart 不会更新环境变量。日志与备份可能含邮件信息，分享前自行脱敏。
