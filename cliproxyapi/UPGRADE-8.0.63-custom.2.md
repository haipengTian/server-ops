# CPA 升级到 8.0.63-custom.2

本版修复 `8.0.63-custom.1` 升级验收对已有客户端 Key 的额外限制，保留后端接受的短 Key、自定义前缀及空白正规化行为。后端仍为上游 `v8.0.63`，配套管理前端仍为 `1.27.3-custom.1`。管理地址保持原域名的 `/management.html`。

确认 [Release](https://github.com/haipengTian/CLIProxyAPI/releases/tag/v8.0.63-custom.2) 和对应的 Personal bundled deployment 检查成功后，在服务器以 root 执行。先更新运维脚本，使配置预检在停止现有服务之前完成；任一步失败就停止，保留输出。

```bash
cd /opt/server-ops &&
git pull --ff-only origin main &&
cd cliproxyapi &&
bash update.sh ghcr.io/haipengtian/cliproxyapi:8.0.63-custom.2 &&
bash status.sh
```

如果 Git 更新失败，保留服务器本地修改并排查，确认更新成功后再运行升级。脚本使用目标镜像预检现有配置和内置前端；预检失败时现有服务保持运行。通过后短暂停止 CPA，备份配置、账号凭证、插件和初始密钥，再启动新版本并验证页面及真实客户端鉴权。备份位置会在终端输出，并记录在 `/opt/cliproxyapi/state/last-backup`。

已从 `.1` 验收失败现场启动容器并恢复页面的服务器，可直接按上述流程升级。已有账号、配置和 Key 继续使用；成功后脚本登记实际 `current-image` 并清除 `failed-upgrade`，无需手工修改状态文件。新安装仍生成随机 Key。

升级完成后刷新原管理页面，登录检查账号与配置，再用常用客户端验证普通和流式请求；使用 Responses/WebSocket 时另测该入口。`egress` 代理容器不需要重建。

若目标版本启动或运行验收失败，脚本停止目标容器并记录 `failed-upgrade`。保留终端输出与备份，依据 README 的兼容回滚或升级前备份恢复流程处理。新版本可能已写回配置或刷新凭证，回滚前需确认数据兼容性。源代码与正式镜像证据见 [verification.md](verification.md)。
