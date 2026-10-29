# 部署包验证记录

日期：2026-10-28。用户服务器：CentOS Stream 9 / x86_64，6 核、12 GiB 内存，现有 Docker / 主机 nginx。该服务器只提供了检查截图，本次没有远程安装或修改 DNS、证书、防火墙。

## 已完成

- 管理员本机初始化测试先失败后实现；Go 全测试及 `go vet ./...` 通过。覆盖密码哈希、输入限制、错误不回显及已有管理员不可覆盖。
- 前端 23 项测试、TypeScript、同域 API 的 standalone 生产构建通过。界面样式未修改。
- API 和 Postfix 生产 Dockerfile 实际构建成功。生产 Compose 配置校验通过，脚本 Bash 语法及配置不执行命令替换、已有配置不覆盖的回归检查通过。
- 独立 `mail-center-deploy-qa` Compose 项目运行 PostgreSQL、API 和 Postfix。一次性测试管理员通过 stdin 初始化成功。API 重启后管理员和邮件保持。
- 本机 SMTP 客户端经 STARTTLS 向 Postfix 投递一封虚构邮件，Postfix 转给内部 API，PostgreSQL 查询确认入库 1 封。尝试外部域名返回 554；收件域名子域名最初被 Postfix 默认设置允许，修正后返回 554。
- Postfix 使用测试专用自签证书验证 STARTTLS；生产脚本从 Certbot 复制正式证书。Windows 绑定目录导致 Postfix 队列写入失败，切换为 Linux 命名卷后完成收信测试；生产目标 Linux 使用 bind 数据目录。
- Go 和部署文件各经独立审查。修复网关缓存旧容器 IP（改为 Docker DNS 动态解析）、同名项目冲突时过早写恢复配置的问题。实际启动还修复了 Alpine Postfix 缺失文档目录与 aliases 数据库默认配置；PostgreSQL 就绪检查改为 TCP，避免初始化临时 Unix socket 被误判为已就绪。

## 尚未完成及影响

- 本机 Docker Hub 连接问题阻止了最初的前端镜像验证；已通过下述 Actions 完成前端生产镜像与页面/静态资源检查。整个网关容器链路、目标服务器同域登录与容器重建后访问仍待验证。
- 备份恢复脚本完成静态审查，完整执行受 Windows 文件权限和缺少 flock 影响，未完成数据库与文件的端到端恢复演练。生产数据投入前，应在隔离 Linux 部署中运行备份并恢复到全新目录，核对管理员、邮件、文件及加密密钥可用。
- 主机 nginx 接入、Certbot 签发与续期、SELinux 下数据目录权限，以及供应商 / 安全组 / 防火墙的公网入站 25 尚未在目标服务器执行。
- 真实 QQ / 网易 / Gmail 与 Telegram 仍由用户自己填写凭据后进行联调。主域名 HTTP 302 不证明真实 Bot API 调用或 IMAP 可用。

在上述服务器验收完成前，保持现有 MX。轻量部署包提供运维脚本与编排，当前不代表服务器已经上线。

## GitHub Actions 与 GHCR 改造

- 后端、前端和 Postfix 分别提供 Actions 测试、镜像构建与容器验证。仅版本 tag 推送且检查成功后发布同一已验证镜像，使用仓库 `GITHUB_TOKEN`；服务器不需要构建工具或应用源码。
- 生产 Compose 去除所有 build 配置，三个应用镜像必须为 GHCR 固定版本、提交号或摘要。安装先拉取，失败不启动；启动带 `--no-build --pull never`。
- Linux 容器执行部署脚本回归通过，覆盖固定镜像限制、拒绝滚动标签、拉取失败不启动与成功后的启动参数；新 shell 脚本 Bash 语法检查和三份 workflow 的 actionlint 检查通过。
- 含 SMTP profile 的生产 Compose 配置校验通过。轻量运维包导出成功，清单检查确认必需部署文件齐全，未包含应用源码、Dockerfile、真实 `.env`、数据或密钥。本轮 CI、拉取部署与导出配置经独立只读审查，未发现待修复问题。
- 三份容器验证脚本已在 GitHub 执行，首版镜像已发布，详见下节。用户服务器尚未部署，真实公网验收仍待执行。
- GitHub Connector 最初返回 `Authentication Failed: Bad credentials`；用户更新令牌并重新加载后认证恢复。已按用户选择创建两个私有应用仓库并关联 remote；镜像发布结果仍须由实际 Actions 确认。

## 首版发布成功（2026-10-29，Asia/Shanghai）

前后端源代码已推送至 `haipengTian/mail-center`、`haipengTian/mail-center-ui` 两个私有仓库。下列三个版本 tag 的 Actions 均为 completed / success，发布了经过各自容器验证的镜像：

| 服务 | 版本 tag | Actions | 部署镜像摘要 |
|---|---|---|---|
| API | `v0.1.0`，提交 `c49e3a7` | [发布运行](https://github.com/haipengTian/mail-center/actions/runs/40722783580) | `ghcr.io/haipengtian/mail-center@sha256:915de28317632bd54f64f4a664ecfc576f168f01a7c21cfc48b323557caf639e` |
| Web | `v0.1.0`，提交 `3ee865a` | [发布运行](https://github.com/haipengTian/mail-center-ui/actions/runs/40723124164) | `ghcr.io/haipengtian/mail-center-ui@sha256:f30f313f7b6bdd4f911e64c5647aabe1ae08088bee130e0b82e30d7078c95d6b` |
| SMTP | `mail-center-v0.1.0`，提交 `5af5c7e` | [发布运行](https://github.com/haipengTian/server-ops/actions/runs/40722230896) | `ghcr.io/haipengtian/mail-center-smtp@sha256:3f6640292780e6c0ed1264f4e194cc10fb7186a0e79136dc5f84b6dded5f0de7` |

- API 测试、PostgreSQL 集成测试、go vet、镜像构建，以及未登录拒绝访问、管理员初始化、登录、SMTP 入库、重启后原会话与邮件保留均通过。首次 smoke 因 Docker 重启重新分配随机宿主端口而失败，修正脚本重新读取端口后通过；未改业务逻辑。
- Web 测试、TypeScript、生产镜像构建、登录页、Telegram 设置页和打包 JavaScript 资源检查通过。首次 setup-node 自动缓存先于 Corepack 调用 pnpm 失败，关闭自动缓存后通过；未改页面样式。
- SMTP 部署回归、Compose 配置、镜像构建、STARTTLS、实际转发投递及拒绝外部/子域名收件通过。
- 镜像摘要取自发布工作流的 Summary，未重复计算文件哈希。GitHub 包详情页本次返回 HTTP 500，未完成其界面的访问权限复核；未更改包权限。服务器实际拉取权限由用户在 SSH 终端登录 GHCR 后验证。

## v0.1.1 同步与阅读修复（2026-10-29）

用户已在目标服务器安装 v0.1.0；截图确认网页、API 和数据库健康，已登录并导入 QQ 邮件。以上“尚未部署”为早期记录。下列两个新版本发布工作流已 completed / success：

| 服务 | 版本与提交 | Actions | 镜像摘要 |
|---|---|---|---|
| API | v0.1.1 / 82d4bb2 | [发布运行](https://github.com/haipengTian/mail-center/actions/runs/40731204834) | `ghcr.io/haipengtian/mail-center@sha256:fa7e148bbec6e9994056e97425ce879a27cdd0055476f8405b33019da0902c40` |
| Web | v0.1.1 / f303db2 | [发布运行](https://github.com/haipengTian/mail-center-ui/actions/runs/40731640680) | `ghcr.io/haipengtian/mail-center-ui@sha256:2da6844d5a77b32d4e4fa1ff970d5b33d58939d107555d0587c03dad333cd21f` |

- API 工作流通过全测试、PostgreSQL 集成、go vet、镜像构建、收信/登录/重启检查，并在容器里实际运行 mail-reparse 检查及 --apply。单元测试复现并修复缺 To 头导致入库失败、中文地址重编码和安全 HTML 样式/链接丢失。重解析测试确认不改已读、附件、ID 或推送队列。
- Web 工作流通过 24 项测试、TypeScript、生产镜像构建和页面/静态资源容器检查。本机隔离浏览器实际验证 1440×1000 桌面与 390×844 手机、正文切换与已读操作，沿用 credit-ui 全局样式。
- SMTP 保持 v0.1.0。升级及旧邮件修复命令见 README，尚需用户在服务器执行；本轮未登录服务器。本次 QQ 失败的实际原因需升级后复测确认，不从旧版通用错误推定限流。

## Web v0.1.2：主动收取与列表自动更新（2026-10-29）

- Web 提交 `30ee9c7` / tag `v0.1.2` 的 [发布工作流](https://github.com/haipengTian/mail-center-ui/actions/runs/40735695872) 已 completed / success：30 项测试、TypeScript、生产镜像构建及页面/静态资源检查通过。
- 已发布 `ghcr.io/haipengtian/mail-center-ui:v0.1.2`，Summary 的精确引用为 `ghcr.io/haipengtian/mail-center-ui@sha256:d3a1e8854ca7f558e02602c49e25c8f3abb6623ce86b428a6812dc90880f341a`。API 保持 v0.1.1，SMTP 保持 v0.1.0；无需运行 mail-reparse。
- 隔离内存 API 与虚构账号的实际浏览器验收覆盖当前邮箱收取、外部触发同步后列表自动出现新信、全局部分失败、暂停与 SMTP-only 行为，以及筛选/阅读状态保留。1440×1000 桌面和 390×844 手机布局正常，手机无横向溢出，浏览器无 error/warn；沿用 credit-ui 样式。记录与截图位于前端 VERIFICATION.md 和 playwright-artifacts/mail-sync-*.png。
- README 已补充仅更新 Web 的备份/拉取命令。本轮未连接服务器；升级后真实 QQ 邮件的收取及自动显示由用户验收。

## Web v0.1.3：网站图标（2026-10-29）

- Web 提交 `8d00ecd` / tag `v0.1.3` 的 [发布工作流](https://github.com/haipengTian/mail-center-ui/actions/runs/40738884973) 已 completed / success。32 项测试、TypeScript、生产镜像构建、页面/静态资源检查，以及 SVG / ICO / Apple 图标链接和资源访问均通过。
- 已发布 `ghcr.io/haipengtian/mail-center-ui:v0.1.3`，精确引用为 `ghcr.io/haipengtian/mail-center-ui@sha256:a0f4cf140fc42535b516ce79511996646297045f0f967160c62853ea15d82c6b`。API v0.1.1、SMTP v0.1.0 不变。
- 紫色信封图标复用于标签页、登录页和侧栏；SVG 包含收信动画及减少动态效果规则，另提供 16/32/48 像素 ICO 与 180 像素 Apple 图标。已目视检查静态图形及 16 像素渲染；本地预览服务及浏览器文件预览分别受环境策略和 URL 策略限制，网页内动画尚未完成实际浏览器验收，升级后由用户确认。部分浏览器标签页静止属于兼容行为。
- README 的 Web 升级命令已更新为 v0.1.3，包含 v0.1.2 收取与自动更新功能；未连接或更改服务器。

## Web v0.1.4：未读邮件点击闪动（2026-10-29）

- Web 提交 `0a36175` / tag `v0.1.4` 的 [发布工作流](https://github.com/haipengTian/mail-center-ui/actions/runs/40743235146) 已 completed / success。固定 Node 22.22.0 下的 35 项测试、TypeScript、生产镜像构建和页面/静态资源/图标访问检查通过。
- 已发布 `ghcr.io/haipengtian/mail-center-ui:v0.1.4`，精确引用为 `ghcr.io/haipengtian/mail-center-ui@sha256:acc09ad781c6dc1d125285df782b2c5253d7ee029570ea3dd906adddce29bb0b`。API v0.1.1、SMTP v0.1.0 不变，不需要再次重解析。
- 根因是自动标为已读后复用了带骨架屏的首次/筛选加载，卸载列表造成闪动。已拆为静默刷新，保留现有行和阅读正文。3 项 JSDOM + React DOM 组件测试先复现失败，再验证慢请求期间行节点与滚动位置保留、未读页移除已读项但保留正文和路由、标为未读不重挂列表。
- 独立审查发现最初新增的 jsdom 30 与固定 Node 不兼容，已精确固定为 jsdom 26.1.0 / @types/jsdom 21.1.7，并由上述发布 CI 验证。README 升级命令已更新为 v0.1.4；实际服务器浏览器点击由用户升级后确认，本轮未连接服务器。

## Web v0.1.5：邮件列表等高（2026-10-29）

- Web 提交 `3fa2738` 与 tag `v0.1.5` 已推送，触发 [发布工作流](https://github.com/haipengTian/mail-center-ui/actions)。本机 36 项测试、TypeScript 和生产构建通过，独立代码审查无阻塞项。
- 隔离浏览器在 1440、1024、803、390 像素宽度下验证长短主题、长短/空摘要、已读/未读、附件及各推送状态，6 封邮件均为 149px，无列表项或页面横向溢出；打开正文及选中正常。完整证据见前端 VERIFICATION.md，桌面与手机截图已目视检查。
- 当前自动化浏览器的配置目录被其他会话占用，未能读取私有仓库 Actions 终态；不能据此确认镜像已经发布。README 的升级命令以 v0.1.5 标签工作流成功为前提，目标引用为 `ghcr.io/haipengtian/mail-center-ui:v0.1.5`。
- API v0.1.1、SMTP v0.1.0 不变，无需重解析。未连接服务器；镜像发布成功后由用户执行升级并核对版本 0.1.5 和真实邮件列表。

## Web v0.1.6：低高度桌面窗口紧凑阅读（2026-10-29）

- Web 提交 `eca1748` 与 tag `v0.1.6` 已推送，触发 [发布工作流](https://github.com/haipengTian/mail-center-ui/actions)。修复候选的 36 项测试、TypeScript、生产构建及 6 种窗口尺寸浏览器验收已通过，证据与截图见前端 VERIFICATION.md、playwright-artifacts/mail-compact-*.png。
- 1280×552 的正文从窗口下方的 566px 提前到 390px，工作区底部 540px；侧栏宽度 240px、列表行高 149px 和正文字号不变。保留手机打开/返回，长主题、附件和收取错误均可访问。独立审查发现的错误状态压缩工作区问题已修复并用错误夹具验证。
- 当前自动化浏览器的配置目录仍被其他会话占用，未能读取私有仓库 Actions 终态，镜像发布成功尚未确认。README 已更新为 v0.1.6，并要求先确认标签工作流成功，再执行升级。
- 目标镜像为 `ghcr.io/haipengtian/mail-center-ui:v0.1.6`；API v0.1.1、SMTP v0.1.0 不变，无需重解析邮件。本轮未连接服务器，部署后由用户确认页面版本及真实小窗口效果。
