# CPA 升级到 8.0.63-custom.1

适用于已通过本目录脚本安装的 CPA；版本包含后端上游 `v8.0.63`、管理前端上游 `v1.27.3`，前端构建版本为 `1.27.3-custom.1`。

确认 [Release](https://github.com/haipengTian/CLIProxyAPI/releases/tag/v8.0.63-custom.1) 已发布且对应的 Personal bundled deployment 检查成功后，在服务器执行：

```bash
cd /opt/server-ops/cliproxyapi
sudo bash update.sh ghcr.io/haipengtian/cliproxyapi:8.0.63-custom.1
sudo bash status.sh
```

脚本先拉取新镜像并固定摘要，再短暂停止 CPA，备份配置、账号凭证、插件和初始密钥，随后启动并验证新版本。备份位置会在终端输出，并记录在 `/opt/cliproxyapi/state/last-backup`。已有配置、账号及密钥继续使用；升级使用 `update.sh`。

新版增加的本地键值库默认在认证目录内（容器路径 `/CLIProxyAPI/auths/kv.db`）；现有认证目录挂载和停机备份已覆盖该文件。原有 `egress` 代理容器不需要重建。

升级完成后刷新管理页面，确认版本，登录后检查账号列表与配置，并用常用客户端分别验证一次普通和流式请求。使用 Responses/WebSocket 时再验证该入口。服务器升级和真实上游调用由操作者完成，源代码与镜像检查记录见 [verification.md](verification.md)。

若新版本启动或验收失败，先保留终端输出和升级备份。脚本在目标版本启动失败后停止目标容器并记录 `/opt/cliproxyapi/state/failed-upgrade`；确认配置与凭证兼容后才能使用 `rollback.sh --config-compatible`，否则按 README 的升级前备份恢复步骤处理。
