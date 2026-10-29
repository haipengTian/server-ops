# 把当前糯糯迁到服务器

先在服务器拉好镜像，再在 Windows 停机导出、上传、导入启动。迁移完成后电脑可以关机，服务器上的 Docker 会自动重启这两个容器。

部署链路：QQ → SnowLuma v2.2.1 → 官方 SnowLuma Adapter 1.1.11 → MaiBot 1.3.18。镜像带上本机的 Planner stop、联网回复资料衔接补丁和糯糯生活照插件。配置、账号、聊天库、表情库、固定肖像放在 `/opt/maibot-qq`，不进入镜像或 GitHub。

目标为 Linux amd64、Docker Compose v2；建议至少给该服务留 4 GB 内存和 6 GB 磁盘。三个管理端口只发布到 `127.0.0.1`，OneBot 13001 仅供容器间连接。

## 1. 服务器准备镜像，暂不停止本机

使用已有 `/opt/server-ops`，执行本分支的部署文件。镜像名用 [MaiBot QQ Docker](https://github.com/haipengTian/server-ops/actions/workflows/maibot-qq.yml) **成功运行**摘要里的 `Deployment image`。

```bash
cd /opt/server-ops
git fetch origin codex/maibot-docker
# 不切换现有服务分支：只导出本服务文件到独立目录。
mkdir -p /opt/maibot-qq-deploy
git archive origin/codex/maibot-docker maibot-qq | tar -x -C /opt/maibot-qq-deploy
cd /opt/maibot-qq-deploy/maibot-qq
bash deploy.sh prepare ghcr.io/haipengtian/maibot-qq:sha-这里换成成功构建的12位提交号
```

如果 GHCR 首次发布的包为私有，请在 GitHub 的 `maibot-qq` 包设置里将可见性设为 public，或由你在服务器完成 `docker login ghcr.io`，再执行 prepare。不要把登录令牌发到聊天。准备成功只表示镜像可用，尚未启动 QQ。

## 2. Windows 停机并导出最终数据

等服务器准备成功后，在本服务目录的 PowerShell 执行：

```powershell
pwsh -File .\export.ps1 -Cutover
```

该命令先停止本机 SnowLuma，再停止与当前实例路径匹配的麦麦进程树，最后导出。导出保留配置中的密钥、现有名单、表情包、聊天与学习数据、QQ 登录数据以及确认过的原始肖像；SQLite 使用在线备份接口处理 WAL。原目录仍留在本机以便回退。

终端会显示私有压缩包的路径。把它通过你的 SSH/SFTP 工具传到服务器，例如 `/root/maibot-final.tar.gz`。这是包含密钥和登录状态的私有数据包，不能上传到 GitHub、Release 或公开网盘。不要在服务器启动后重新启动本机机器人。

不带 `-Cutover` 只做预备快照，本机继续工作；服务器导入会拒绝这类快照。

## 3. 服务器导入、启动

```bash
cd /opt/maibot-qq-deploy/maibot-qq
bash deploy.sh import /root/maibot-final.tar.gz
bash deploy.sh start --local-stopped
bash deploy.sh status
```

导入目标必须不存在，避免覆盖旧实例。导入只改麦麦 HTTP 监听为容器内 `0.0.0.0:8001`、适配器地址为 `snowluma:13001`；其他配置、当前 QQ 放行范围、人设和模型选择均沿用迁移时的实际值。

### 通过域名访问（当前服务器）

`maimai.thpvip.xyz` 和 `qqdesk.thpvip.xyz` 的 A 记录指向服务器，首次签证书先选“仅 DNS”。复用主机现有 nginx，不必重新安装或修改其他服务：

```bash
cd /opt/server-ops
git fetch origin codex/maibot-docker
git archive origin/codex/maibot-docker nginx | tar -x -C /opt/maibot-qq-deploy
read -rp "证书通知邮箱：" CERT_EMAIL
bash /opt/maibot-qq-deploy/nginx/add-site.sh \
  --domain maimai.thpvip.xyz --upstream http://127.0.0.1:18011 --email "$CERT_EMAIL"
```

QQ 桌面接入前，按 [公共 nginx 的远程桌面认证步骤](../nginx/README.md#给远程桌面加一层网页登录密码)创建网页登录账号，再用 `--basic-auth-file /etc/nginx/qqdesk.htpasswd` 接入 `http://127.0.0.1:16081`。在上述独立部署目录中使用 `/opt/maibot-qq-deploy/nginx/add-site.sh`。

打开 [麦麦后台](https://maimai.thpvip.xyz/) 或 [QQ 登录桌面](https://qqdesk.thpvip.xyz/vnc.html?autoconnect=1&resize=scale)。麦麦沿用原管理密码；QQ 桌面先输入网页账号密码，再输入原 VNC 密码并由你扫码登录。无需放开 18011、15099、16081 公网端口。

### 不配置域名时使用 SSH 隧道

Windows 另开一个终端建立隧道（`服务器地址`与用户名由你填写；本机原管理端口需已释放）：

```powershell
ssh -N -L 18011:127.0.0.1:18011 -L 15099:127.0.0.1:15099 -L 16081:127.0.0.1:16081 root@服务器地址
```

打开 [麦麦管理页](http://127.0.0.1:18011/)、[SnowLuma](http://127.0.0.1:15099/)、[QQ 登录桌面](http://127.0.0.1:16081/)。登录沿用迁移前的本地设置。QQ 更换服务器可能要求重新扫码，由你完成；容器 healthy 不等于 QQ 已登录。

核对 QQ 账号 `3217664079`、当前群聊/私聊名单和生活照工作室固定参考。随后用 QQ 发一条私聊、群里 @糯糯，再分别试表情、联网问题和“发张你在咖啡店看书的生活照”。确认实际收发后完成切换。

## 停止、备份和回退

```bash
cd /opt/maibot-qq-deploy/maibot-qq
bash deploy.sh stop
# 备份同时停止两个容器，完成后保持停止；备份不在仓库中。
bash deploy.sh backup
```

第一次切换失败时，先在服务器运行 `stop`，确认两个容器已停止，再在 Windows 按原实例 README 的启动方法启动 SnowLuma 和麦麦。本机原文件不被导出过程修改。服务器启动后产生的新聊天不会自动同步回本机；需要保留这些数据时，先停服备份服务器实例，再决定恢复哪份数据。

更新镜像前运行 `backup`，记录旧 `.env` 和备份路径。恢复时保持服务停止，把当前 `/opt/maibot-qq` 改名保留，再在 `/opt` 解压所选备份并恢复对应 `.env`，最后执行 `start --local-stopped`。不要只切换旧镜像而忽略数据库版本。

## 代码与构建

上游固定在 MaiBot `2a9af62cec37035d29237acbe2cf3adceb700b27`、适配器 `17ad5384e0d231ec190705c9c2baa234013aaa07`。`image/local-fixes.patch` 保存本机已验证的局部修复；`image/uv.lock` 固定运行依赖（SDK 2.19.0、Dashboard 1.9.12）；`image/plugins/nuonuo-photo` 只包含源码，没有运行配置和照片。上游 GPL-3.0 许可随源码进入镜像。

GitHub Actions 运行迁移回归、Compose 检查、实际镜像构建及初始化烟测，通过后发布按提交号固定的 GHCR 镜像。PR 只验证不发布。本服务部署目录不包含 `.env`、迁移包、聊天数据或图片。
