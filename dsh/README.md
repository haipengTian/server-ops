# DeepSeek Harness（dsh）

在这台服务器上以 Docker 运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的网页界面，对外地址 `https://dsh.thpvip.xyz`。

```
浏览器 → 主机 nginx（HTTPS）→ 127.0.0.1:3080 → 容器 3081（socat）→ 容器内 127.0.0.1:3080（dsh）
```

## 部署

```bash
git clone https://github.com/haipengTian/server-ops.git /opt/server-ops
cd /opt/server-ops/dsh
./install.sh        # 构建镜像并启动，只监听 127.0.0.1
./setup-nginx.sh    # nginx 站点 + 证书（需要域名已解析到本机）
./setup-model.sh    # 生成模型配置文件，按提示填中转地址、模型和 Key
./login-url.sh      # 打印登录网址，在自己的浏览器里打开
```

都用 root 运行。第一次运行会从 `.env.example` 生成 `.env`，需要改域名、端口、数据目录或资源上限就编辑它（里面没有任何密钥）。

登录后在模型选择器里选配置好的模型，再**添加工作区** `/workspace`（对应服务器上的 `/opt/dsh/workspace`）。要处理某个项目，就在这个目录里 `git clone` 一份。

## 模型配置

模型提供商和 Key 都用文件配置，保存后 dsh 在下一次请求时自动读取，不用重启：

| 文件（服务器上） | 写什么 | 模板 |
|---|---|---|
| `/opt/dsh/home/profiles/web/cordis.patch.yml` | 提供商 ID、协议、`baseURL`、模型列表、兼容开关 | [model/cordis.patch.example.yml](model/cordis.patch.example.yml) |
| `/opt/dsh/home/.credentials.yaml` | API Key（`refs` 下，名字对应上面的 `apiKeyEnv`） | [model/credentials.example.yaml](model/credentials.example.yaml) |

`./setup-model.sh` 在文件不存在时从模板生成，修正属主和权限（Key 文件必须是 600，否则 dsh 拒绝加载），并检查 Key 是否都填了；改完可以再跑一次做检查。它不会覆盖已有文件，也不会打印 Key。

Key 不能写进 `cordis.patch.yml`：dsh 的配置里只放引用名（`apiKeyEnv`），值只放在 `.credentials.yaml`。两个文件都只在服务器上，不进仓库。网页「设置 → 模型」改的也是这两个文件，两种方式可以混用。

## 插件

```bash
./plugin.sh add dshmarket       # 安装（装完自动重启 dsh）
./plugin.sh list                # 查看已装插件
./plugin.sh remove dshmarket    # 卸载
```

`plugin.sh` 在容器里运行 `dsh plugin --profile web ...`（底层是 pnpm，镜像里已装好）。插件装在 `/opt/dsh/home/profiles/web`，升级、重建镜像都不受影响。

插件和 dsh 同一个进程、同样权限运行，能读到工作目录和 `.credentials.yaml`。只装自己信任的包；`dshmarket` 是社区插件市场（非 DeepSeek 官方），通过它一键安装的插件同样如此。

## 升级

在 `.env` 里改 `DSH_VERSION`（先看新版本的更新说明，预览版会有不兼容改动），然后 `./update.sh`。容器重启后登录网址会变，重新 `./login-url.sh`。

当前用 npm 上的 `latest`（`0.2.0-rc.2`）。这个版本的网页服务只能监听 `127.0.0.1`（命令行不接受 `0.0.0.0`，也不接受具体 IP），所以容器里用 socat 把 3081 转发到 dsh 的 `127.0.0.1:3080`；dsh 的登录只看启动令牌和签名 cookie，不看请求来源，转发不影响登录。它也没有 `--public-url`，打印的是 `http://127.0.0.1:3080/?token=…`，`./login-url.sh` 会换成 `https://<域名>`。升级后如果启动报 `unknown option`，先对照新版本的 `dsh --profile web --help` 调整 `entrypoint.sh`。

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
| 报 `MISSING_CREDENTIAL` | `apiKeyEnv` 的名字在 `.credentials.yaml` 的 `refs` 下没有值；运行 `./setup-model.sh` 检查 |
| 中转地址和 Key 都对，但每个请求都被拒 | 提供商下加 `compat: {supportsDeveloperRole: false, maxTokensField: max_tokens}`（模板里已带） |
| 启动报 `.credentials.yaml is readable beyond its owner` | 权限不是 600：`./setup-model.sh` 或 `./update.sh` 都会自动修正，然后 `docker compose restart dsh` |
| 改了 `.credentials.yaml` 后容器起不来 | 格式错：`docker compose logs --tail 30 dsh` 看报错行，修好后 `docker compose restart dsh` |
| 第一次打开提示「无法创建默认工作区」 | 正常：容器里没有「文档」目录可用。点「选择工作区」选 `/workspace` 即可，只需一次 |
| `plugin.sh` 报 `timed out waiting for the writer lock` | 上次启动失败留下的写锁（容器里 PID 会复用，dsh 认不出它已失效）。`docker compose restart dsh`，启动时会自动清掉，再重试 |
| 执行命令报 `SANDBOX_UNAVAILABLE` | 宿主机内核没开 Landlock 且容器里 bubblewrap 不可用，见下文「沙箱」 |
| 证书签发失败 | 确认 `getent hosts dsh.thpvip.xyz` 指向本机，重跑 `./setup-nginx.sh` |

## 沙箱

dsh 在 Linux 上先试 bubblewrap，不可用再用 Landlock；两者都不可用就拒绝执行命令，不会不加沙箱地执行。

- 容器里 bubblewrap 多半起不来（它要创建命名空间，Docker 默认的 seccomp 和 `no-new-privileges` 会拦住）。这里**不**为了它放开 `--privileged` 或 `seccomp=unconfined`。
- 这台服务器内核启用了 Landlock（`cat /sys/kernel/security/lsm` 里有 `landlock`），dsh 会退到 Landlock 执行命令。
- 部署后验证一次：在会话里让它运行 `ls /`，能正常返回、没有 `SANDBOX_UNAVAILABLE` 即可。

沙箱外面还有容器这一层：命令最多碰到挂进来的两个目录和容器自己的文件系统。
