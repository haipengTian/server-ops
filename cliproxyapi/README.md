# CLIProxyAPI 个人部署

部署 `haipengTian/CLIProxyAPI` 与 `haipengTian/Cli-Proxy-API-Management-Center` 的配套镜像。管理前端包含在容器中，页面与源码提交、校验和随 Release 记录，自动更新关闭。无需额外数据库，插件默认关闭。

首版 [v8.0.20-custom.1](https://github.com/haipengTian/CLIProxyAPI/releases/tag/v8.0.20-custom.1) 已发布，[正式发布检查](https://github.com/haipengTian/CLIProxyAPI/actions/runs/38535163176) 全部成功，linux/amd64 镜像已实际匿名拉取。固定摘要为 `sha256:1291e33624ac9c7f16e8dec44b68424adeb6aad6c707033581988888c8256674`。服务器安装尚未执行，验证证据见 [verification.md](verification.md)。

## 首次安装

服务器已有 `/opt/server-ops` 时先检查该仓库的分支与未提交修改，再更新到已审核发布的部署提交。不要重置服务器的本地配置。

```bash
cd /opt/server-ops/cliproxyapi
bash init.sh ghcr.io/haipengtian/cliproxyapi:8.0.20-custom.1
vi .env
bash install.sh
bash status.sh
```

`.env` 中填写证书邮箱 `CERTBOT_EMAIL`，默认域名是 `cpa.thpvip.xyz`，宿主机端口为 `127.0.0.1:8317`。仅接受字面值 `KEY=value`，不加引号或空格。初次安装将版本标签解析为固定 digest；之后用 `update.sh` 升级。

已由用户确认的服务器环境：x86_64、nginx 1.26.3、Compose 5.6.0、可用内存 4.7 GiB、磁盘空间 44 GiB、8317 空闲。默认预算 768 MiB / 1 CPU。仍须现场确认 DNS 指向源站、80/443 可达、certbot 及续期定时任务可用、Docker 可访问 GHCR，以及模型服务出网正常。

当前域名对应另一台服务器的既有服务（用户已确认），DNS 稍后由用户切换。此流程部署当前 xiguapier 服务器；切换 DNS 后再执行 `setup-nginx.sh`，证书 webroot 验证需到达本机。新服务先通过本机或 SSH 隧道检查，DNS 切换不代表原服务器的 OAuth/config 数据自动迁移。

本机与隧道验收完成、DNS 已切换到新服务器后，再配置 HTTPS：

```bash
bash setup-nginx.sh
```

初始化前检查 Docker 现有网络，确保 `172.30.83.0/24` 不与已有网络或主机路由重叠；如需变更，同时修改 `CLIPROXY_SUBNET` 和 `CLIPROXY_GATEWAY` 后初始化。初始化会将 gateway 写入 `server.trusted-proxies`，后续改网络也必须同步改配置。首次申请证书建议使用直连源站 DNS。当前 nginx 模板要求 >=1.25.1。SELinux Enforcing 时，按脚本提示由用户启用 `httpd_can_network_connect`；四个专用挂载使用 `:Z`。

## 访问与密钥

管理页面：<https://cpa.thpvip.xyz/management.html>；OpenAI 兼容 API 地址：`https://cpa.thpvip.xyz/v1`。

初始管理密钥和客户端 Key 由服务器生成，保存在 `/opt/cliproxyapi/secrets/initial-keys`，仅 root 可读。用户在服务器本地查看，并分别用于管理登录和 API 客户端，勿贴入聊天或提交 Git。应用会把配置中的管理密钥写为 bcrypt；`initial-keys` 是初始记录，后台轮换后不会自动更新。

首次执行 `init.sh` 即生成这两个值，无需另行注册管理员。`MANAGEMENT_KEY` 就是管理页面的登录密码，`CLIENT_API_KEY` 用于调用 `/v1`；两者不能混用。`.env` 填写部署参数，OAuth 与上游模型 Key 在登录后台后接入。需要自定义初始密码时，在首次 `install.sh` 前于服务器本地编辑 `/opt/cliproxyapi/config/config.yaml` 的 `management.secret-key`；同时自行更新初始记录，避免保留过期密码。后续重复初始化不会重置已有密码。

管理界面使用同一 HTTPS 地址登录。通过后台接入 OAuth 或上游 API Key，凭证仅留在服务器。管理授权失败会累计计数，五次触发临时封禁；安装、状态和健康探测不发送匿名管理请求。自动检查验证管理配置安全开关、真实页面 SHA、匿名客户端拒绝与有效客户端认证；管理登录及实际模型调用仍需用户验收。

8317 只能在服务器本机访问。证书配置前临时查看页面可在自己电脑开 SSH 隧道：

```bash
ssh -L 8317:127.0.0.1:8317 root@服务器IP
```

然后访问本机 `http://127.0.0.1:8317/management.html`。公网最终使用 HTTPS 域名。

## 可选的上游出口代理

当 Antigravity 因服务器出口地区拒绝调用时，可用 [egress/README.md](egress/README.md) 中的独立 sing-box 容器，把服务器本地输入的 VLESS Reality 链接转换为 Docker 内网 SOCKS5 代理。它不发布宿主机端口，不修改默认安装和应用配置；先运行 `bash egress/setup.sh`、`bash egress/status.sh` 检查出口，再为目标认证文件配置 `socks5://cliproxyapi-egress:1080` 并验证真实调用。Google 是否接受该出口仍需实际测试。

## 数据与备份

`/opt/cliproxyapi/{config,auths,logs,plugins}` 挂载到容器，归 UID/GID 10001，目录权限 700。配置文件 600，可由后台写入。`WRITABLE_PATH=/CLIProxyAPI` 确保应用及错误日志统一进入 logs；单文件前端留在镜像 static 中，不用宿主机卷覆盖。

```bash
bash backup.sh
```

备份暂停应用写入，打包 config、auths、plugins、secrets，记录部署 `.env`、镜像摘要与 SHA256SUMS，然后恢复此前运行状态。backups/state/secrets 留在 root 限制目录，日志不进入备份。备份包含 OAuth 刷新凭证与密钥。文件校验不代表完成实际恢复演练。

## 升级与兼容回滚

```bash
bash update.sh ghcr.io/haipengtian/cliproxyapi:8.0.20-custom.2
bash rollback.sh --config-compatible
```

升级先拉镜像、停写、备份，再切换 digest。新版本尝试启动后可能写回配置或刷新凭证；验收失败时暂停并保留现场，不自动用旧程序读取新数据。`--config-compatible` 表示操作者已检查版本说明并确认配置与凭证能由旧程序读取；兼容回滚会再次备份当前数据。

不兼容时，用户选择升级前备份，并先保留故障现场。默认目录下的手动恢复如下；只使用本机脚本生成的完整备份，实际目录修改过时同步调整命令。先替换第一行的备份路径。

```bash
backup=/opt/cliproxyapi/backups/替换为选定目录
(cd "$backup" && sha256sum -c SHA256SUMS) || exit 1
old_image=$(cat "$backup/image")
docker pull "$old_image" || exit 1
bash backup.sh || exit 1
docker compose --env-file .env stop cliproxyapi || exit 1
rescue=$(mktemp -d /opt/cliproxyapi/backups/pre-restore.XXXXXXXX) || exit 1
for name in config auths plugins secrets; do
  mv -- "/opt/cliproxyapi/$name" "$rescue/$name" || exit 1
done
tar -xzf "$backup/data.tar.gz" -C /opt/cliproxyapi --same-owner || exit 1
cp -- "$backup/deployment.env" .env || exit 1
chmod 600 .env
printf '%s\n' "$old_image" > /opt/cliproxyapi/state/current-image
bash install.sh
```

任何一步失败都保持应用暂停，原目录保存在 `$rescue`，先排查再启动。恢复后验证管理登录、账号列表、配置、真实模型和流式请求；此流程可能回到备份时的 OAuth 刷新状态，需要重新授权。生产恢复演练尚未完成。

## 验收与常用检查

```bash
bash status.sh
docker compose --env-file .env logs --tail=100 cliproxyapi
nginx -t
```

服务存活与页面可访问不能代替业务验收。用户完成：管理登录、接入账号、修改配置后重建容器验证保存、真实非流式和流式调用；使用 Responses/WebSocket 时另测该协议。证书签发后检查 certbot 定时任务与续期。现有 Sub2API 继续使用 `proxy.thpvip.xyz:8088`。
