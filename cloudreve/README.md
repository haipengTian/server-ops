# Cloudreve × ImageBed 服务器部署

把个人文件库部署到 **https://cloud.thpvip.xyz**。本次选择首次安装、全新数据，不迁移 Windows 上的账号、策略或测试文件。

- 镜像：`ghcr.io/haipengtian/cloudreve:4.19.1-custom.1`，发布工作流成功后使用。
- 源码：[个人 fork](https://github.com/haipengTian/cloudreve/tree/codex/imagebed-integration)，沿用 Community 4.19.1 原界面。
- 单容器 SQLite，完整数据持久化到 `/opt/cloudreve/data`，停机备份在 `/opt/cloudreve/backups`。
- 只发布 `127.0.0.1:5212`，主机 nginx 提供 HTTPS。现有 ImageBed custom.3 无须升级。

## 1. 安装镜像，暂不开放域名

先确认 [镜像发布工作流](https://github.com/haipengTian/cloudreve/actions/workflows/imagebed-image.yml) 对 `4.19.1-custom.1` 的运行成功。服务器已安装 Docker、Compose 和现有 server-ops：

```bash
cd /opt/server-ops
git pull --ff-only origin main
cd cloudreve
sudo bash install.sh
sudo bash status.sh
```

脚本首次生成 `.env`，拒绝覆盖已有容器或非空数据目录。镜像拉取后会固定为实际 GHCR 摘要。若服务器有 Git 冲突，先处理，不强制重置。

首次安装阶段不要创建 nginx 站点、开放 5212 防火墙或把容器绑定到 `0.0.0.0`：第一个注册用户拥有管理员权限，应先由你创建。

## 2. 通过 SSH 隧道创建管理员

在**自己的 Windows PowerShell** 中输入服务器 SSH 地址（例如 `root@服务器IP`），保持窗口打开：

```powershell
$server = Read-Host '服务器SSH地址'
ssh -N -L 15212:127.0.0.1:5212 $server
```

浏览器打开 <http://localhost:15212>，注册首个管理员并登录。密码自己填写，不发送给协作者。先在管理后台关闭开放注册，按实际需要调整。

## 3. 开放 cloud.thpvip.xyz

将 `cloud.thpvip.xyz` 的 A/AAAA 记录指向这台服务器，确认公网 80/443 能到达已有 nginx。域名确认证书后需要续期通知邮箱；在**服务器**执行：

```bash
cd /opt/server-ops/cloudreve
read -r -p '证书通知邮箱: ' email
sudo bash setup-nginx.sh "$email"
```

脚本复用现有 `nginx/add-site.sh`，只配置本域名，先验证配置再重载，不重启其他容器。若主机尚未安装公共 nginx 工具，先按 [nginx 说明](../nginx/) 安装。

打开 <https://cloud.thpvip.xyz> 用刚创建的账号登录，把 Cloudreve 站点 URL 设置为此 HTTPS 地址。若开启 Cloudflare 代理，单文件限制还需遵守代理套餐限制；本次 nginx 请求体上限 128 MiB，ImageBed 策略上限 100 MiB。

## 4. 配置 ImageBed，验证第一份文件

在 Cloudreve 新建 ImageBed 存储策略：

- 服务地址：`https://img.thpvip.xyz`。
- 专用目录：先用 `cloudreve-test/server`，与本机样例的物理路径分开，仍在已有测试目录内。
- API Token：你在图床中生成并在后台填写，权限 `upload`、`manage`、`delete`；不写入 `.env`、源码或聊天。
- 单文件上限：100 MiB 或更小。Cloudreve 不配置 Telegram/R2/S3，沿用 ImageBed 当前默认渠道。

先给独立测试组绑定新策略，不改变原 Admin/User 组的默认本地策略。社区版每组只绑定一条存储策略。新上传以 `UUID.html` 等形式存储；已有无后缀对象不变。不自动导入图床原有对象。

先上传自己生成的小 HTML 和图片，核对图床物理名带后缀、Cloudreve 原名、源码/图片回读和下载内容；再验证视频 Range、整理、删除和容器重启保留。只清理自己明确创建的测试文件。

HTML 当前可查看源码，隔离交互渲染未实现；Office 在线预览仍待单独配置。镜像的容器烟测使用临时本地存储，并不代替服务器到真实 Telegram 的业务验收。

## 后续更新与停机备份

只使用已成功发布的固定版本，不使用 `latest`：

```bash
cd /opt/server-ops/cloudreve
sudo bash backup.sh
# 后续有新版本时，将下面参数换成已发布的新版本
sudo bash update.sh ghcr.io/haipengtian/cloudreve:4.19.1-custom.1
sudo bash status.sh
```

`update.sh` 会先拉目标镜像，再停服务，备份完整 `data/`、部署配置和旧镜像引用，然后切换并等待健康检查。拉取失败不停止旧服务；备份失败不切换镜像，并尝试启动原容器。目标版本启动失败时保持暂停，避免未知迁移后自动启动旧程序。

备份含数据库、WAL、本地上传、会话密钥及图床 Token，保持私有并另存异机副本。**Telegram 文档不包含在此备份中**；图床元数据也需沿用 ImageBed 自己的备份方案。不要执行 `docker compose down -v` 或清空数据目录。

## 更新失败时恢复

检查 `status.sh` 的日志并保存现场。使用刚才输出的具体备份目录：

```bash
cd /opt/server-ops/cloudreve
sudo bash restore.sh /opt/cloudreve/backups/替换成实际备份目录
sudo bash status.sh
```

恢复会在新的 `data.restore-时间` 目录解压备份，使用备份时记录的旧镜像启动；不覆盖原数据目录。恢复点之后的新记录不在恢复内，原现场保留供核对。恢复只回退 Cloudreve 本地记录，不回退 Telegram 或 ImageBed 上的远端变更。
