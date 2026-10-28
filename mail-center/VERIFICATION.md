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

- 本机 Docker Hub 连接超时，缓存与代理下载基础镜像持续停滞，因此未完成前端 Docker 镜像和整个网关容器链路运行。现已改由 Actions 构建；首发必须先确认流水线成功、GHCR 镜像已发布，再由服务器拉取，验证同域登录、静态资源、API 和重建容器后的访问。
- 备份恢复脚本完成静态审查，完整执行受 Windows 文件权限和缺少 flock 影响，未完成数据库与文件的端到端恢复演练。生产数据投入前，应在隔离 Linux 部署中运行备份并恢复到全新目录，核对管理员、邮件、文件及加密密钥可用。
- 主机 nginx 接入、Certbot 签发与续期、SELinux 下数据目录权限，以及供应商 / 安全组 / 防火墙的公网入站 25 尚未在目标服务器执行。
- 真实 QQ / 网易 / Gmail 与 Telegram 仍由用户自己填写凭据后进行联调。主域名 HTTP 302 不证明真实 Bot API 调用或 IMAP 可用。

在上述服务器验收完成前，保持现有 MX。轻量部署包提供运维脚本与编排，当前不代表服务器已经上线。

## GitHub Actions 与 GHCR 改造

- 后端、前端和 Postfix 分别提供 Actions 测试、镜像构建与容器验证。仅版本 tag 推送且检查成功后发布同一已验证镜像，使用仓库 `GITHUB_TOKEN`；服务器不需要构建工具或应用源码。
- 生产 Compose 去除所有 build 配置，三个应用镜像必须为 GHCR 固定版本、提交号或摘要。安装先拉取，失败不启动；启动带 `--no-build --pull never`。
- Linux 容器执行部署脚本回归通过，覆盖固定镜像限制、拒绝滚动标签、拉取失败不启动与成功后的启动参数；新 shell 脚本 Bash 语法检查和三份 workflow 的 actionlint 检查通过。
- 含 SMTP profile 的生产 Compose 配置校验通过。轻量运维包导出成功，清单检查确认必需部署文件齐全，未包含应用源码、Dockerfile、真实 `.env`、数据或密钥。本轮 CI、拉取部署与导出配置经独立只读审查，未发现待修复问题。
- 当前仅完成本地配置与脚本检查。新增 CI 容器验证脚本尚未在 GitHub 执行，不能视为 Actions 构建、GHCR 发布或服务器部署成功。
- GitHub Connector 最初返回 `Authentication Failed: Bad credentials`；用户更新令牌并重新加载后认证恢复。已按用户选择创建两个私有应用仓库并关联 remote；镜像发布结果仍须由实际 Actions 确认。
