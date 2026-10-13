# 本地验证记录

验证日期：2026-10-13。产品源码：`ab80abc6d1f929a6864c8804fd077b509d21fda2`。

| 项目 | 实际结果 |
| --- | --- |
| 部署生命周期与失败恢复 | Linux 隔离测试 21 个场景通过；模拟 Docker/HTTP/DB，真实文件归档、校验与权限 |
| 上游融合工具 | 4 个本地 Git 场景通过，执行实际 fetch/merge，并验证冲突和获取失败 |
| Bash 语法 | 两仓库新增脚本均通过 |
| 新增 GitHub workflow | YAML 语法和基本结构检查通过；未运行线上 Actions |
| ShellCheck | 0.9.0，所有新增脚本通过；共享 source 路径使用 SCRIPTDIR |
| Compose | 使用合成密钥运行 config --quiet，通过；不拉镜像、不启动服务 |
| 独立代码审查 | 部署/维护脚本和操作文档复审通过，无阻断项 |
| 个人/官方基线 | 实际 fetch 均成功并核实相同 SHA，本地 main 快进 35 个提交 |
| 后端单元测试 | Go 1.27.2：internal/domain、internal/handler/dto 通过；未运行全部后端测试 |
| 前端依赖 | pnpm 9.15.9 冻结安装成功，未修改 package.json 或锁文件 |
| 前端类型与生产构建 | vue-tsc -b、Vite build 通过；有既有分包与浏览器数据陈旧警告 |
| 前端全量测试 | Vitest 2.1.9，371 个测试文件、2844 个用例全部通过（2 workers） |
| Linux amd64 后端嵌入构建 | Go 1.27.2，CGO_ENABLED=0，GOOS=linux，GOARCH=amd64，embed 构建通过，包含实际前端产物 |

未执行镜像构建/发布、GitHub 线上工作流、实际 PostgreSQL/Redis 运行、服务器 nginx/证书、
真实网关与计费验收、数据库恢复演练。新增维护改动尚未提交和推送。
Docker daemon 在当前本地会话不可用，Compose 仅做离线配置验证；产品二进制构建不替代镜像运行验收。

## nginx 重载等待回归

服务器部署反馈：证书签发成功且代理环境变量为空，但 nginx 重载后的首次本机 HTTPS 检查命中旧证书，
触发站点配置恢复。该行为与同仓库 ImgBed 部署的已复现 reload worker 切换窗口一致。
针对这个窗口增加有限重试并显式绕过代理；持续证书错误仍恢复配置，未关闭 TLS 校验。

`bash sub2api/tests/nginx.sh`：修改前延迟证书场景失败，修改后 3 个场景通过。
覆盖临时旧证书、持续错误与既有文件恢复、重载失败；执行真实入口和文件操作，
nginx、HTTPS 和服务重载为模拟边界，服务器需更新脚本后重新完成 TLS 验收。
原有 21 个部署隔离场景、Bash 语法继续通过。
