# DeepSeek Harness（dsh）

在这台服务器上以 Docker 运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的网页界面，对外地址 `https://dsh.thpvip.xyz`。

```
浏览器 → 主机 nginx（HTTPS）→ 127.0.0.1:3080 → dsh 容器
```

## 部署（3 条命令）

```bash
git clone https://github.com/haipengTian/server-ops.git /opt/server-ops
cd /opt/server-ops/dsh
./install.sh        # 构建镜像并启动，只监听 127.0.0.1
./setup-nginx.sh    # nginx 站点 + 证书（需要域名已解析到本机）
./login-url.sh      # 打印登录网址，在自己的浏览器里打开
```

都用 root 运行。第一次运行会从 `.env.example` 生成 `.env`，需要改域名、端口、数据目录或资源上限就编辑它（里面没有任何密钥）。

登录后：

1. **设置 → 模型**：添加模型提供商并填 API Key。Key 只写不读，存在 `/opt/dsh/home/.credentials.yaml`，不要写进 `.env` 或仓库。
2. **选择工作区**：添加 `/workspace`（对应服务器上的 `/opt/dsh/workspace`）。要处理某个项目，就在这个目录里 `git clone` 一份。

## 升级

在 `.env` 里改 `DSH_VERSION`（先看新版本的更新说明，预览版会有不兼容改动），然后 `./update.sh`。容器重启后登录网址会变，重新 `./login-url.sh`。

## 安全边界

dsh 是未经安全审计的开发者预览版，能执行模型生成的命令。这里的限制：

- 容器以非 root（uid 1000）运行，`no-new-privileges`，内存/CPU/进程数有上限（`.env` 可调）
- 只挂载 `/opt/dsh/home` 和 `/opt/dsh/workspace`；**不要**再挂 `docker.sock`、`/opt`、`/root` 等目录
- 只发布到 `127.0.0.1`，容器网络里访问不到宿主机本地端口上的其他服务
- 登录靠 dsh 的启动令牌和会话 cookie；`./login-url.sh` 打印的网址等同于密码
- 命令在 dsh 自己的沙箱里执行（Linux 上依次尝试 bubblewrap、Landlock；都不可用时 dsh 会拒绝执行命令）

## 排查

| 现象 | 处理 |
|---|---|
| `install.sh` 等待超时 | 看它打印的日志；`docker compose logs -f dsh` |
| 浏览器里接口全是 403 | `.env` 的 `DSH_DOMAIN` 和访问的域名不一致，改好后 `docker compose up -d` |
| 页面能开但会话不动 | nginx 的 WebSocket 升级没生效：`nginx -T \| grep connection_upgrade` |
| 执行命令报 `SANDBOX_UNAVAILABLE` | 宿主机内核没开 Landlock 且容器里 bubblewrap 不可用，见下文「沙箱」 |
| 证书签发失败 | 确认 `getent hosts dsh.thpvip.xyz` 指向本机，重跑 `./setup-nginx.sh` |

## 沙箱

（待补充：根据服务器的内核检查结果确定）
