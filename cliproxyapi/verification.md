# 部署验证记录

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
