# 部署验证记录

日期：2026-10-14。以下是本地验证与用户提供的服务器信息；本轮没有登录服务器或替换线上服务。

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
| Actions YAML | Actionlint 1.7.12 检查两个新增 workflow 通过，云端 Actions 尚未运行 |
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

`35789123` 为前两个协议测试注册明确支持离散 thinking levels 的模型，结束时注销；黄金文件加载正规化实际 CRLF。保留全部原始业务断言与黄金值，没有修改产品 Go 源码。三个测试分别复核，并经全量 Linux 测试通过。Windows 初次后端测试还存在未改动路径测试等平台失败；Windows vet 的未改动插件 loader 存在 unsafe.Pointer 告警，未纳入本次 Linux 部署修改。

代码审核已复核：readiness 密钥不泄露、拒绝重定向、避免管理登录封禁、正确日志目录、发布同一测试镜像、备份及恢复路径。Go 测试修复另经 Go reviewer 复核并重复目标测试三次，通过。

## 服务器与域名现状

用户提供：x86_64、nginx 1.26.3、Compose 5.6.0、内存可用 4.7 GiB、磁盘空闲 44 GiB、8317 空闲。拟使用一个 768 MiB / 1 CPU 容器与 nginx HTTPS。

本机直连查询 `cpa.thpvip.xyz` 的 A 记录为 `216.158.79.63`；HTTPS `/healthz` 返回 `{"status":"ok"}`，GET `/management.html` 返回 200，响应头 `Via: 1.1 Caddy`。这表明域名已有服务，不能当作首次空白站点直接覆盖；须由用户确认该服务属于谁、是否在本次服务器、是否需要替换，以及现有 OAuth/config 数据是否迁移。本轮尚未作更改。

## 发布和生产验收待办

1. 确认现有 cpa 服务与此次部署的关系。
2. 审核并推送前端固定提交，合入后端及 server-ops 部署分支。
3. 云端检查 completed/success 后创建个人 custom 标签；发布实际测试的 amd64 镜像及配套 Release，确认 GHCR 可匿名拉取。
4. 用户在服务器执行初始化、安装及 HTTPS 流程，保留已有服务和数据；需要迁移时先给出迁移步骤。
5. 用户本地查看初始密钥、管理登录、接入账号，验证配置持久化与真实模型/流式调用。Responses/WebSocket 按使用情况另外验证。
6. 确认证书续期定时任务，执行生产备份恢复演练。

本地测试不等于镜像已发布、线上部署完成或业务验收通过。
