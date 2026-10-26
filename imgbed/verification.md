# 验证记录

## 2026-10-26 新机迁移恢复入口

`restore.sh` 先观察到缺少恢复入口的预期测试失败，完成后 `bash imgbed/tests/run.sh` 的30个隔离场景通过，ShellCheck 通过。新增场景使用真实归档、文件、校验和与权限操作；Docker/HTTP 为模拟边界。

恢复检查覆盖：保留原密钥与配置、SQLite/WAL 和本地对象，使用原镜像；拒绝校验失败、文件缺失和 FAILED 备份；拒绝已有配置、数据、容器和端口；镜像拉取失败不提交数据；启动失败暂停容器并保留恢复现场。输出未包含测试凭据。

旧机现场已确认 `/opt/imgbed/app` 为4.2 MB，容器使用首版 OCI 摘要。尚待用户执行真实备份传输、新机恢复、原管理账号登录、旧图片和渠道读取、上传、DNS/HTTPS 切换验收。

同日迁移反馈修复：旧机自定义 BASIC_PASS 被64位十六进制校验误拒绝。先用自定义凭据复现同一报错，再移除密码及密钥的生成格式限制，保留必填与字面值校验；35个隔离场景通过。新增覆盖自定义密码和原加密密钥的完整备份恢复、空值仍在停止服务前拒绝，以及恢复输出不包含测试凭据。旧机本次报错发生于 load_env，尚未执行停止容器；真实备份仍需更新脚本后重试。

以下为此前版本的验证记录。

验证日期：2026-10-13。产品基线：`0d219dd45f514265ba9cb17788059fd7a1b1240d`，版本 `2.7.7`。

| 检查 | 实际结果及边界 |
| --- | --- |
| 测试先行 | 部署入口、上游同步入口、持久化认证保护分别先观察到预期失败，再实现并通过 |
| 部署生命周期与失败处理 | WSL/Linux 17个隔离场景通过；Docker/HTTP用模拟边界，归档、校验、权限为真实操作 |
| 上游同步 | 4个本地Git场景通过，实际fetch/merge验证保留二开、获取失败、脏工作区、冲突现场 |
| 有效认证配置 | Node22测试通过，覆盖环境变量初始密码、持久化空管理员密码、空上传密码、已修改密码及数据库不可用 |
| 真实 SQLite/HTTP 就绪检查 | 使用隔离临时目录中的实际服务；正常配置通过，持久化用户名存在/密码为空时，即使匿名管理接口401仍正确拒绝就绪 |
| 文件生命周期 | Node22原生Docker适配入口运行通过：匿名拒绝、错误密码拒绝、管理员登录、本地上传、逐字节比对、进程重启后读取、删除后404 |
| 上传渠道 | 测试明确使用 `uploadChannel=cfr2&autoRetry=false`，不依赖错误渠道自动回退；未连接真实外部Bucket/Telegram |
| 依赖 | Windows Node22.23.3/npm10.9.9，按锁文件安装server/common workspace成功；未改package.json/锁文件。存在上游prebuild-install弃用提示 |
| Bash/ShellCheck | 新运维脚本、维护脚本语法及ShellCheck0.9.0通过；新工作流的shell步骤另行检查 |
| YAML/Compose | 工作流和Compose语法检查通过；Docker Compose用合成凭据执行config --quiet通过 |
| 独立审查 | 修复有效空密码门禁、安装失败未暂停、CI测试缺host依赖三项问题后复审通过，无未解决项 |

真实文件测试使用 Node 运行 `deploy/server/index.js` 的 Docker 适配路径，独立临时数据与合成凭据，
并非实际 Docker 容器验证。该运行使用Windows；WSL执行的是脚本隔离测试。
服务启动时显示重复 tags 列迁移被既有代码捕获的日志，未改变上游迁移行为。
本机 Docker Desktop daemon未运行；后续实际容器验收改在 GitHub Actions 执行。

## 云端容器与部署检查

- 运维 [PR #1](https://github.com/haipengTian/server-ops/pull/1) 已合入，
  [部署工作流](https://github.com/haipengTian/server-ops/actions/runs/38357536718) 成功，17个部署隔离场景通过。
- 图床 [PR #1](https://github.com/haipengTian/CloudFlare-ImgBed/pull/1) 与
  [PR #2](https://github.com/haipengTian/CloudFlare-ImgBed/pull/2) 已合入远端 main。
- [手动 Docker 验收](https://github.com/haipengTian/CloudFlare-ImgBed/actions/runs/38363801044) 成功，
  源提交 `ac48b6233679a62ec217eb73b19c89857a841547`；实际 amd64 镜像内有效认证回归和就绪检查通过，
  上传、原图字节比对、重启持久化、鉴权与删除通过。手动运行不发布镜像。
- 首次云端运行在重启检查失败；修复后重新查询宿主端口。成功运行实测从32768变为32769，
  证实旧端口不能用于重启后的检查。修复另经 Bash、ShellCheck、YAML 和独立审查通过。

- 首版 [tag 发布工作流](https://github.com/haipengTian/CloudFlare-ImgBed/actions/runs/38364801354) 成功，
  再次运行 amd64 容器回归，发布 amd64/arm64 镜像。GHCR 显示 Public，匿名 registry 请求返回200。
  `docker buildx imagetools inspect` 核实两种架构及 OCI index 摘要
  `sha256:6a5f47668a72147c8f47ffbd9496cdf82a3877367e329c11291e5be71a201735`。
  arm64 未运行容器，目标服务器需另行验收。

尚未执行：服务器安装、DNS/nginx/证书、真实R2/七牛/Telegram、较大文件与分块、
隔离备份恢复演练及生产验收。域名已确认，服务器操作由用户自行执行。
两仓库维护分支已推送并合入远端 main；发布记录在独立分支维护，用户已有 `.idea/` 未修改。
tag `v2.7.7-custom.1` 指向实际验收提交；发布后文档单独维护，不改变该 tag。

## nginx 重载等待回归

后续部署反馈：证书 SAN 包含 `img.thpvip.xyz`、nginx 语法和重载检查通过，
但重载后立即执行 HTTPS 检查出现域名不匹配并触发配置恢复。已针对这个时序窗口增加有限重试，
持续错误仍恢复配置，保留 TLS 及匿名管理/上传的401门禁。服务器原因与结果须更新脚本后复验。

`bash imgbed/tests/nginx.sh`：修改前延迟证书场景失败，修改后5个场景通过。
覆盖临时旧证书、持续错误、既有/新增配置恢复、开放上传拒绝、重载失败；
执行真实入口和文件操作，nginx、HTTP和服务重载为模拟边界，不代表服务器 TLS 已验收。
原有17个部署隔离场景、Bash语法和 ShellCheck 通过。
