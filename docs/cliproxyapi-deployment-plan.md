# CLIProxyAPI 个人版本部署方案

日期：2026-10-14。域名由用户确认：`cpa.thpvip.xyz`。

## 目标与交付边界

在现有服务器部署个人 fork 的 CLIProxyAPI 与管理前端，沿用 Docker + 主机 nginx + certbot。
部署脚本与个人发布流程已在本地实现，验证记录见 `cliproxyapi/verification.md`；正式 GHCR 镜像尚未发布，服务器安装尚未执行。
用户已提供服务器环境：x86_64、nginx 1.26.3、Compose 5.6.0、可用内存 4.7 GiB、磁盘空闲 44 GiB、8317 空闲。本机 DNS 查询得到 `cpa.thpvip.xyz` → `216.158.79.63`，仍须核对源站地址、80/443 和上游出网。
当前该域名的健康与管理页面已响应，经过 Caddy；须先确认现有服务的来源与替换/迁移范围。

## 已核实的代码基线

| 仓库 | 当前本地提交 | 职责 |
| --- | --- | --- |
| `haipengTian/CLIProxyAPI` | `0d18d3b365be000eeaee7de4615f9da596b2059d` | 后端基线；部署改动另在 codex 分支 |
| `haipengTian/Cli-Proxy-API-Management-Center` | `431ae6ce4d73fde9fa97d80cd20df0400dff891c` | 前端源码、单文件构建及测试兼容修复 |
| `haipengTian/server-ops` | `500a58c` | 部署、HTTPS、备份、升级和回滚 |

后端是 Go 1.26 的 v8 模块；当前 main 位于本地 `v8.0.20` 标签之后，不能把当前提交当作该标签的原始内容。
前端使用 Bun 1.3.14，构建为 `dist/index.html`；发布产物名为 `management.html`，只使用 v8 管理接口。
默认文件存储模式无需外部 PostgreSQL/Redis；首版不启用 Home 集群或动态插件。

## 部署结构

```text
浏览器 / API 客户端
        ↓ HTTPS :443
主机 nginx：cpa.thpvip.xyz
        ↓ http://127.0.0.1:8317
Docker：CLIProxyAPI :8317 + 配套 management.html
        ↓ OAuth 或 API Key
上游模型服务
```

- 管理页面：`https://cpa.thpvip.xyz/management.html`。
- OpenAI 兼容地址：`https://cpa.thpvip.xyz/v1`；其他客户端按其协议配置对应路径。
- 宿主机仅发布 `127.0.0.1:8317:8317`，容器内监听 `0.0.0.0:8317`。
- 与现有 Sub2API 的 `proxy.thpvip.xyz` 和 8088 端口分开。
- DNS 首次验证建议直连源站；后续启用 CDN 时再核对流式响应、WebSocket 和可信代理。

## 前后端配套发布

推荐把前端放进同一个后端镜像，而不是启动时下载最新前端。

1. 后端仓库保存发布清单，记录后端源码提交、前端完整提交 SHA、前端构建版本与 HTML 校验和。
2. CI 检出个人前端的指定 SHA，使用锁文件安装依赖，运行 `bun run verify`。
3. 将单文件产物改名为 `management.html`，与后端一同构建到个人镜像中。
4. 镜像显式设置 `MANAGEMENT_STATIC_PATH=/CLIProxyAPI/static`，该目录包含管理页面，不用宿主机数据目录覆盖它。
5. 服务器配置 `management.disable-auto-update-panel: true`，保留 `disable-control-panel: false`。
6. 后端个人工作流先验证，再发布 `ghcr.io/haipengtian/cliproxyapi:<固定个人版本>`；安装时解析并固定镜像摘要。
7. Release 记录两个源码 SHA、HTML 校验和、镜像摘要与实际验证过的架构；保留两项目许可证。

继承的后端 `release.yaml` 和 `docker-image.yml` 已在本地加入官方仓库条件；新增个人 GHCR 工作流验证后发布同一测试镜像。发布前仍需推送前端 pin、审核合入后端与运维改动，并确认检查成功。
个人 GHCR 发布采用 GitHub Actions 的 `GITHUB_TOKEN` 与 `packages: write`，无需用户提交长期 Token。
首版发布后确认镜像公开可匿名拉取；私有镜像的登录凭据只由用户在服务器本地配置。

注意：关闭前端自动更新并不禁止“页面缺失时首次下载”。发布验收必须在阻断外网的条件下确认镜像内的页面存在、可访问且校验和正确。
源码已经支持固定页面路径，此方案预计不需要修改后端业务代码。

## 持久化与初始配置

服务器部署入口为 `/opt/server-ops/cliproxyapi`；专用数据根目录为 `/opt/cliproxyapi`。

| 宿主机目录 | 容器内目录 | 保存内容 |
| --- | --- | --- |
| `/opt/cliproxyapi/config` | `/CLIProxyAPI/config` | 可写的 `config.yaml` |
| `/opt/cliproxyapi/auths` | `/CLIProxyAPI/auths` | OAuth 凭证、刷新状态 |
| `/opt/cliproxyapi/logs` | `/CLIProxyAPI/logs` | 限量轮转日志 |
| `/opt/cliproxyapi/plugins` | `/CLIProxyAPI/plugins` | 预留插件目录，首版关闭插件 |
| `/opt/cliproxyapi/state` | 不挂载 | 当前/上一版本、操作记录 |
| `/opt/cliproxyapi/backups` | 不挂载 | 配置与凭证备份 |
| `/opt/cliproxyapi/secrets` | 不挂载 | 首次生成的登录及客户端密钥原值 |

通过 `--config /CLIProxyAPI/config/config.yaml` 指定配置文件；`oauth.auth-dir` 指向 `/CLIProxyAPI/auths`。
配置目录必须可写：后端会保存后台配置修改，并在加载时把明文管理密钥转换为 bcrypt 后写回文件。
首版采用专用挂载目录，并按实际运行用户设置属主与权限；在 SELinux 主机使用专用目录的 `:Z` 挂载。

初始化时在服务器生成不同的管理密钥和客户端 API Key，文件权限为 0600、敏感目录为 0700。
初始化重复执行必须保留现有密钥、配置和账号，不能通过覆盖模板重置服务。
浏览器管理必须启用 `management.allow-remote: true`；Docker 转发请求也可能被后端识别为远程来源。
不使用模板中的 `your-api-key-*`，否则代理 API 会进入模板密钥保护模式。
请求正文日志默认关闭；应用文件日志启用且限制总大小，容器 stdout 也设置轮转上限。
初始资源预算建议 768 MiB / 1 CPU，部署前按同机剩余容量调整，并通过实际负载观察修订。

## nginx、OAuth 与网络

nginx 保留流式响应和 WebSocket：关闭代理缓冲、设置升级头与适当的长请求等待时间。
覆盖客户端提交的 IP 头；后端只信任实际的专用 Docker 代理来源，不设置任意来源可信。
证书使用现有 certbot webroot；修改站点后先验证语法再重载，并等待新 worker 的 HTTPS 检查通过。

现有模板使用 `http2 on`，要求 nginx >= 1.25.1。历史记录曾出现 nginx 1.20.1，当前状态未核实。
新服务模板应兼容实际服务器版本；不能为了新增站点直接升级共享 nginx 或覆盖其他服务配置。
SELinux Enforcing 时核实 `httpd_can_network_connect`；外部入口只需允许 80/443，不开放 8317。

服务器必须能访问选定上游的登录、刷新令牌和推理服务；能拉镜像不代表这些访问已通过。
OAuth 的回调方式按提供商验收，优先使用管理前端已有的手动回调提交能力。
确需 localhost 回调的流程，用 SSH 隧道临时映射对应端口；不照搬官方 Compose 的全部回调端口公开发布。
浏览器本地回调 URL 与服务器回调不是同一个网络位置，不能只验证登录页面能打开就判定 OAuth 可用。

## 需要落地的文件与阶段

| 阶段 | 主要交付 | 完成条件 |
| --- | --- | --- |
| 1. 发布基础 | 后端专用 Dockerfile、前端版本清单、个人 GHCR 工作流、官方工作流隔离条件 | 前端验证、Go 检查、镜像构建与阻断出网的页面回归通过 |
| 2. 运维入口 | `server-ops/cliproxyapi/` 下的 Compose、配置模板、init/install/status、nginx 模板与 setup 脚本 | 配置校验、幂等初始化、鉴权、端口冲突与 nginx 恢复场景通过 |
| 3. 维护能力 | backup/update/rollback、部署 README、独立 CI 检查 | 备份校验、升级失败保留现场、回滚兼容检查通过 |
| 4. 首版发布 | 固定版本 Release、公开 GHCR 镜像及摘要、架构记录 | Actions 明确 completed/success，实际确认可拉取 |
| 5. 服务器验收 | 用户在服务器执行安装、HTTPS、账号接入和调用 | 前端登录、配置持久化、真实模型与流式调用通过 |

实现时为初始化、升级失败、权限和鉴权等行为先补测试，确认失败后再实现；每个阶段完成后汇报验证证据。
阶段 1 和 2 的本地测试不能代替实际服务器验收；需要真实凭证的操作由用户在服务器或浏览器完成。

## 安装、升级与回滚流程

首次安装的执行顺序：核实服务器 → 发布并确认镜像 → 获取 server-ops 部署文件 → 初始化配置与密钥 → 启动固定镜像 → 本机验收 → 申请证书与 nginx 反代 → 配置上游 → 真实调用。
部署入口已采用现有项目相同的 `init.sh`、`install.sh`、`status.sh`、`setup-nginx.sh` 风格；运行前须确认镜像与脚本已发布。

升级先拉取目标镜像，再暂停服务，保存配置、OAuth 凭证和插件目录的一致性备份，记录原镜像摘要，然后启动新版本并验收。
目标镜像启动前失败可恢复原运行状态；新版本启动后可能修改配置或凭证，失败时暂停新版本并保留现场。
回滚前先核对配置/凭证兼容性；若不兼容，选择并验证升级前备份，再恢复文件与原镜像，不能只改镜像标签。
备份包含访问凭证，始终留在服务器受限目录；备份摘要检查不等于完成恢复演练。

## 验收层级

1. 容器运行：`/healthz` 返回 200，仅证明 HTTP 服务存活。
2. 管理页面：`/management.html` 返回 200，产物校验和与发布清单一致。
3. 权限：自动检查管理安全配置和客户端匿名拒绝；真实镜像验证正确管理密钥能读写配置。避免重复无效管理请求触发临时封禁，实际用户登录另行验收。
4. 持久化：后台修改配置、上传凭证后重建容器，配置与凭证保留。
5. 业务：实际选定模型的非流式与流式调用成功；使用 Codex Responses/WebSocket 时另外验收相应协议。
6. 运维：重启、升级和恢复演练通过，证书续期机制存在且验证成功。

正式执行前由用户在服务器核实：`uname -m`、`free -h`、`df -h /opt`、`nginx -v`、`docker compose version`、`ss -ltn`，以及域名 DNS 与上游出网。
未提供或验证的服务器信息不视为部署前置条件已满足。

## 依据

- 后端 `internal/managementasset/updater.go`：页面路径、更新开关及缺失页面下载。
- 后端 `internal/api/server_routes.go`、`server_management_v8.go`：管理页面、健康检查、代理与管理接口。
- 后端 `internal/config/config_load.go`、`config_yaml.go`：管理密钥哈希与配置写回。
- 前端 `vite.config.ts`、`.github/workflows/release.yml`、`src/services/api/oauth.ts`：单文件构建、发布及手动回调。
- server-ops 根 README 与现有 imgbed/sub2api 生命周期脚本：服务器部署约定。
- Docker Compose 官方参考：回环端口绑定、镜像摘要与 SELinux 专用挂载标签。
