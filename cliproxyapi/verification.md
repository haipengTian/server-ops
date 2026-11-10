# 部署验证记录

## 2026-11-10 升级验收修复：8.0.63-custom.2

服务器升级 `.1` 时容器健康，但部署 readiness 因客户端 Key 策略取消上线并停止目标容器。根因是部署脚本额外要求 Key 至少 24 字符且不能使用模板前缀，超出了后端原有鉴权契约；截图中的错误不能区分具体触发了哪条规则。用户执行 `docker start cliproxyapi-custom-cliproxyapi-1` 后确认管理页面已恢复。

`.2` readiness 保留后端接受的已有短 Key、自定义前缀、内部 ASCII 空格，正规化首尾空白并忽略空白条目；继续验证匿名 API 拒绝、有效客户端 Key 认证及页面完整性。新安装继续生成随机 Key，服务器现有密钥无需更换。运维升级增加目标镜像停机前预检，配置或内置前端检查失败时现有服务继续运行。

已完成的修复验证：

- 18 项 Python 测试通过，覆盖旧式 Key、内部空格、错误 Key 拒绝及重定向拒绝；HTTP fixture 实际核对授权值。
- [后端 PR #3](https://github.com/haipengTian/CLIProxyAPI/pull/3) 已合并；[PR CI](https://github.com/haipengTian/CLIProxyAPI/actions/runs/42774377224) 完成 Linux Go 全量测试、编译、配套前端验证、实际镜像构建与离线 smoke。真实镜像使用 `legacy-client-key` 验证鉴权、日志和容器重建后的持久化。
- [运维 PR #11](https://github.com/haipengTian/server-ops/pull/11) 已合并；[CI](https://github.com/haipengTian/server-ops/actions/runs/42774539830) 验证 21 个生命周期场景、ShellCheck、nginx 恢复、Compose，并对实际已发布 `.1` 镜像执行停机前预检，确认非 root Python 入口及 stdin 配置读取可用。
- 独立 Python 与发布集成审查完成，内部空格兼容问题已在修复及测试中覆盖。

[正式发布](https://github.com/haipengTian/CLIProxyAPI/actions/runs/42775087424)的 verify 与 publish 全部成功，[v8.0.63-custom.2](https://github.com/haipengTian/CLIProxyAPI/releases/tag/v8.0.63-custom.2) 已发布，发布的是通过 smoke 的同一镜像。

| 正式产物 | 值 |
| --- | --- |
| 镜像 | `ghcr.io/haipengtian/cliproxyapi:8.0.63-custom.2` |
| 镜像摘要 | `sha256:2c97a3001bb40868cf8bc3153c6634af2a4fe774bbd978e633a7a81572d36b56` |
| 后端提交 | `d07415606e4a31048955d3f2b605ad3b280f6451` |
| 配套前端提交 | `e79a62d989a62ff35bcffec2a12a89febdd95761` |
| 配套前端版本 | `1.27.3-custom.1` |
| 架构与用户 | linux/amd64，10001:10001 |

使用独立空 Docker 配置（`auths: {}`）和 crane 0.22.1 完整匿名下载镜像，解析摘要与 Release 一致。从下载的镜像读取运行用户、架构和内嵌 `release.json`，后端提交、前端提交、版本及页面校验和字段与 Release 记录一致。本地 Docker daemon 未启动，实际运行验收由上述 Linux CI 完成。

服务器升级 `.2` 和真实模型调用由用户按照[修复版升级说明](UPGRADE-8.0.63-custom.2.md)执行；管理页面地址保持不变。

## 2026-11-10 上游同步：8.0.63-custom.1

本次同步后端上游 `v8.0.63`（`6db7d4b839d86c5b24e17bbe73bcd4db18ef1b1a`）及管理前端上游 `v1.27.3`（`953fb24`）。前端配套提交为 `e79a62d989a62ff35bcffec2a12a89febdd95761`，构建版本 `1.27.3-custom.1`；个人镜像版本为 `8.0.63-custom.1`。

后端八个合并冲突采用上游现行实现：配置重载串行执行并记录实际载入内容，认证文件快照按来源内容防止旧观察覆盖新保存，WebSocket 在发送终止事件前关闭本地中断窗口。原有回归用例继续保留，认证观察用例改用上游的文件快照契约。更新 Go 至 `1.26.10`、Bun 至 `1.4.3`，删除上游测试中未使用的 `sync.Once` 值复制。个人镜像打包、非 root 用户、挂载目录与升级脚本保持现行入口。

已完成：

- 前端 `bun install --frozen-lockfile`、1,897 项测试、ESLint、TypeScript 和单文件构建通过；[前端 CI](https://github.com/haipengTian/Cli-Proxy-API-Management-Center/actions/runs/42768739666) 成功，[PR #2](https://github.com/haipengTian/Cli-Proxy-API-Management-Center/pull/2) 已合入。浏览器检查登录页渲染、空密钥校验，控制台没有错误。
- 后端重点包 `internal/watcher`、`internal/watcher/synthesizer`、`sdk/cliproxy/auth`、`sdk/cliproxy`、`sdk/api/handlers/openai` 通过，服务器程序编译通过；部署校验 11 项通过。
- [后端配套 CI](https://github.com/haipengTian/CLIProxyAPI/actions/runs/42768805458) 全部成功：Linux 全量 Go 测试、编译、配套前端构建、实际 amd64 镜像构建及离线 smoke，通过鉴权、日志目录、配置写入和重建后的密钥持久化。[后端 PR #2](https://github.com/haipengTian/CLIProxyAPI/pull/2) 已合入，正式版本后端提交为 `f9dce13238ca60f49f4dbcbc2ffb604742f8bfec`。
- 独立 Go 与发布集成审查通过。新版默认键值库 `/CLIProxyAPI/auths/kv.db` 已由现有挂载和停机备份覆盖。

Windows 全量测试有七项环境相关失败，涉及符号链接权限、打开文件或工作目录的清理；未跳过 Linux 全量发布门禁。Windows `go vet` 另报告上游插件加载器的 `unsafe.Pointer` 用法，目标 Linux 镜像由配套 CI 验证。

[正式发布](https://github.com/haipengTian/CLIProxyAPI/actions/runs/42769946007)的 verify 与 publish 全部成功，[v8.0.63-custom.1](https://github.com/haipengTian/CLIProxyAPI/releases/tag/v8.0.63-custom.1) 已发布。服务器升级由用户按照[本次升级说明](UPGRADE-8.0.63-custom.1.md)操作，真实账号调用结果待服务器升级后确认。

| 正式产物 | 值 |
| --- | --- |
| 镜像 | `ghcr.io/haipengtian/cliproxyapi:8.0.63-custom.1` |
| 镜像摘要 | `sha256:9ec6b08ff838c92ddfbcec7f13d10707a1af17866f202e1bcb92ae0e60bb3d7b` |
| 配套前端版本 | `1.27.3-custom.1` |
| 架构与用户 | linux/amd64，10001:10001 |

使用独立空 Docker 配置（`auths: {}`）和 crane 0.22.1 实际匿名下载完整镜像到本地 tar，解析到的镜像摘要与 Release 一致；本地 Docker daemon 未启动，实际运行验收由上述 Linux CI 完成。

## 首版部署历史

日期：2026-10-14。以下是本地、云端验证与用户提供的服务器信息；本轮没有登录服务器或替换线上服务。

## 本地结果

| 检查 | 结果与边界 |
| --- | --- |
| 前端 Linux `bun run verify` | 1586 pass / 0 fail，ESLint、TypeScript 与生产单文件构建通过；Bun 1.3.14 / Node 24.19.0 |
| 后端 Linux `go test ./...` | 通过；Go 1.26.4 Debian 容器，未变更的已通过 package 使用 Go 缓存 |
| 后端编译 | Linux `go build -buildvcs=false -o ... ./cmd/server` 和真实 Dockerfile CGO 构建通过 |
| Readiness | 11 项通过：弱密钥/错误配置/损坏页面拒绝，连续检查不触发管理登录，带密钥请求拒绝重定向 |
| 生命周期脚本 | 20 个隔离场景通过；Docker/HTTP 边界模拟，备份 tar、SHA 和权限是真实文件操作 |
| nginx 恢复 | 5 个隔离场景通过：延迟证书、持续证书错误、重载失败、匿名 API 放行；nginx/certbot/网络为模拟 |
| 脚本与 Compose | Bash 语法、ShellCheck 0.9.0、Compose config 通过；使用合成镜像值 |
| Actions | Actionlint 1.7.12 通过；最终后端提交 `4a5d3320` 的 [PR 验收](https://github.com/haipengTian/CLIProxyAPI/actions/runs/38534452844) 与 [push 验收](https://github.com/haipengTian/CLIProxyAPI/actions/runs/38534448094) 均 completed/success，包含真实镜像 smoke |
| 真实镜像 | linux/amd64，UID/GID 10001，网络关闭，使用镜像生产 CMD，通过以下三个 smoke 阶段 |

真实镜像 smoke 输出：

```text
PASS: non-root bundled image serves frontend and authenticated API without network access
PASS: request error logs use the mounted directory and are readable through management
PASS: management writes and bcrypt key survive container recreation
```

检查使用临时 Docker volume 和合成密钥，完成后清理。连续执行六次 readiness 后管理 PATCH 成功；页面实际 HTTP 内容 SHA 与镜像清单匹配。缺失模型请求产生的错误日志位于 logs，后台可读取，config/logs 不存在。配置编辑、bcrypt 密钥与属主在容器重建后保持。没有使用真实 OAuth、上游模型或服务器密钥。

## 测试修复与审核

前端最初 Linux 验证有四项失败：源码契约读取 CRLF，及 React 输出转义后的提示文本。`431ae6c` 仅修正四个测试断言的输入表示；页面业务源码与依赖保持不变。Windows 初次全量测试另有货币显示的地区差异，发布标准为 Linux 验证结果。

后端基线 `0d18d3b3` 最初 Linux 全量测试失败于三个顶层测试（其中黄金测试两个子场景）：

- `TestAIStudioTranslateRequestNormalizesThinkingLevel`
- `TestAntigravityExecutorExecuteStreamTranslatesInteractionsRequest`
- `TestToolSearchDisabledMatchesDevGolden`

`35789123` 为前两个协议测试注册明确支持离散 thinking levels 的模型，结束时注销；黄金文件加载正规化实际 CRLF。保留全部原始业务断言与黄金值；该提交没有修改产品 Go 源码。三个测试分别复核，并经全量 Linux 测试通过。Windows 初次后端测试还存在未改动路径测试等平台失败；Windows vet 的未改动插件 loader 存在 unsafe.Pointer 告警，未纳入本次 Linux 部署修改。

云端测试随后暴露 WebSocket 上传与取消通知的测试同步问题，以及配置/账号热更新的真实竞争。`b0230239` 为测试增加明确的完成通知；`b536c75c` 与 `144b8db5` 串行化配置重载，并让重载 hash 对应观察到的文件内容，防止旧加载误标记新保存已生效。账号观察在 manager 锁内依据结构发布时间过滤旧文件快照，运行时记录留在 manager 中，保存及返回的 Auth 数据格式保持不变；请求计数不影响外部文件更新。

修复后 Linux `go test ./...` 与编译通过，配置/账号目标测试重复 100 次通过，watcher race 检查重复 20 次通过，SDK/auth race 检查重复 5 次通过。源码与测试经 Go reviewer 复核。本次运行与镜像验收范围为 Linux/amd64；相同粗时钟刻度内的来源排序限制仍存在，虚拟时钟单元测试不代表该跨平台限制已经解决。

`4a5d3320` 修复完成帧已发送、流尚未结束时，本地 HTTP 取消仍处于开启状态的窗口；完成帧发送前关闭本地取消，下一次 `response.created` 恢复它。保留原中断协议和后续请求断言，中断/后续请求集成测试重复 500 次通过，race 检查重复 10 次通过。

代码审核已复核：readiness 密钥不泄露、拒绝重定向、避免管理登录封禁、正确日志目录、发布同一测试镜像、备份及恢复路径。Go 测试修复另经 Go reviewer 复核并重复目标测试三次，通过。

## 服务器与域名现状

用户提供：x86_64、nginx 1.26.3、Compose 5.6.0、内存可用 4.7 GiB、磁盘空闲 44 GiB、8317 空闲。拟使用一个 768 MiB / 1 CPU 容器与 nginx HTTPS。

本机直连查询 `cpa.thpvip.xyz` 的 A 记录为 `216.158.79.63`；HTTPS `/healthz` 返回 `{"status":"ok"}`，GET `/management.html` 返回 200，响应头 `Via: 1.1 Caddy`。用户已确认这是另一台服务器，DNS 后续由用户变更。本轮准备当前 xiguapier 服务器的新部署，先本机/隧道验收，再切换 DNS 并申请证书；不修改原服务器。原账号与配置不会因 DNS 切换自动迁移。

以上是部署前的域名记录。用户随后确认新服务器安装成功、DNS 已切换；本机实际访问 `142.248.83.14` 的 nginx HTTPS，证书校验成功、GET 管理页面 200 且 SHA 与正式产物一致、健康接口 200、匿名 `/v1/models` 401。管理登录后用户提供的日志显示 Antigravity 请求进入上游，但 Google 返回地区条件错误；用户确认服务器出口问题。

## 可选出口代理验证

新增独立 sing-box v1.14.3 代理容器，镜像固定为 `sha256:80c639ba467885b28511fb7c980565c2d30a8752f778e7bc8abdbc91fbfd95ec`，只连接现有 backend 网络，不发布宿主机端口。节点由用户在服务器隐藏输入，测试未使用实际节点或凭证。

转换器成功场景、13 个错误输入和 Compose 项目隔离回归均通过；错误不输出链接或 UUID。真实 Compose 检查先复现 `-p` 覆盖 `COMPOSE_PROJECT_NAME` 导致外部网络名错误，再使用独立网络变量修复。实际镜像断网 `sing-box check` 接受合成配置；非 root、只读代理容器能通过内网别名与应用镜像容器完成 SOCKS5 握手，PortBindings 为空。实际复现普通 `up` 保留已有进程，再核验 `--force-recreate` 更换容器并恢复 SOCKS5 服务。测试容器和网络已清理。

Linux Bash/ShellCheck、既有生命周期 20 项与 nginx 5 项通过。以上证明配置格式、内网隔离与 SOCKS5 监听，未验证真实 Reality 节点的 TLS 握手、远程出口、Google 资格或真实模型调用；这些须由用户在服务器执行 `egress/status.sh` 和同账号模型测试。

## 正式发布结果

[v8.0.20-custom.1](https://github.com/haipengTian/CLIProxyAPI/releases/tag/v8.0.20-custom.1) 已发布。[发布运行 38535163176](https://github.com/haipengTian/CLIProxyAPI/actions/runs/38535163176) 的完整重跑 completed/success，verify 和 publish 均成功；发布的是通过 smoke 的同一镜像。

首次运行失败于未改动的 `TestCodexWebsockets_KeepalivePingDuringUpload_NonstreamSessionless`：fixture 收到 pong 后立即发送 completed 并关闭连接，没有等待请求 payload 上传完成，而产品上传 hook 位于实际 WriteMessage 之前。源码复核确认它允许提前关闭竞争；保留原标签、原 SHA，完整重跑所有检查成功，未跳过测试或修改产品来规避失败。该 fixture 的偶发问题本轮未修复。

| 正式产物 | 核验值 |
| --- | --- |
| 镜像 | `ghcr.io/haipengtian/cliproxyapi:8.0.20-custom.1` |
| 镜像摘要 | `sha256:1291e33624ac9c7f16e8dec44b68424adeb6aad6c707033581988888c8256674` |
| 后端提交 | `a1b5b91258484a7e3bf194ebb31b06dc4a8c61f8` |
| 前端提交 | `431ae6ce4d73fde9fa97d80cd20df0400dff891c` |
| 页面 SHA256 | `85636ebc75daba58aa33d0312f7ccd64b17a444903d4bedd89ccf6406eeb12c4` |
| 架构与用户 | linux/amd64，10001:10001 |

使用独立空 Docker 配置（`auths: {}`，没有凭据或 credential helper）执行 manifest inspect 和实际 pull，均成功，pull 返回摘要与 Release 一致。下载 Release 的 `release.json` 和 `management.html`，校验页面 SHA；镜像断网读取内嵌清单与页面 SHA，两个源码提交和页面 SHA 均一致。这是本机发布产物核验，不代表服务器网络和业务验收。

## 发布和生产验收待办

1. 现有 cpa 服务属于另一台服务器，已确认；DNS 后续由用户切换。
2. 已完成：前端 pin 已推送并合入 [前端 PR #1](https://github.com/haipengTian/Cli-Proxy-API-Management-Center/pull/1)；后端与运维已分别合入 [后端 PR #1](https://github.com/haipengTian/CLIProxyAPI/pull/1)、[运维 PR #4](https://github.com/haipengTian/server-ops/pull/4)。
3. 已完成：`v8.0.20-custom.1` 指向后端合入提交，正式发布 completed/success；实际镜像、Release、页面校验和及 GHCR 匿名拉取已核验。
4. 用户在服务器执行初始化、安装及 HTTPS 流程，保留已有服务和数据；需要迁移时先给出迁移步骤。
5. 用户本地查看初始密钥、管理登录、接入账号，验证配置持久化与真实模型/流式调用。Responses/WebSocket 按使用情况另外验证。
6. 确认证书续期定时任务，执行生产备份恢复演练。

镜像已发布并实际拉取；服务器安装、HTTPS 与真实业务验收尚待用户执行。
