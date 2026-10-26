# 在新服务器部署 PanSou

域名 `sou.thpvip.cn`，应用只发布 `127.0.0.1:9000`，公网由现有主机 Nginx 提供 HTTPS。部署使用前后端一体镜像，不需要在服务器安装 Go 或 Node。

首次启动启用 **74 个内置插件、111 个默认 TG 频道**，客户可选全部默认频道和网盘类型。完整清单与源码版本保存在 [defaults.json](defaults.json)：频道取自前端 Dockerfile，插件取自后端 `main.go` 的有效注册导入，包含镜像默认列表漏掉的 `qiwei`、`xdpan`。它们是该固定版本的内置清单；数据源能否返回结果还取决于网络、站点状态，以及插件所需的账号/Cookie。

## 1. 准备 Docker

在服务器已有的 `server-ops` 仓库目录执行。先更新部署文件：

```bash
git pull --ff-only origin main
sudo dnf install -y jq openssl
sudo docker version
sudo docker compose version
```

如果尚未安装 Docker，CentOS Stream 9 使用官方仓库安装；已有 Docker 的主机跳过这段：

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo docker compose version
```

应用默认内存上限 `1g`、CPU 上限 `2`，安装前可按服务器容量调整 `.env`。数据位于 `/opt/pansou/app`，绑定挂载使用 `:Z` 适配 SELinux。无需向公网开放 9000 或容器内部 8888 端口。

## 2. 生成配置并填写管理员

```bash
sudo bash pansou/init.sh
sudo vi pansou/.env
```

只需先填写这两项：

```dotenv
ADMIN_USERS=avatar:替换成你自己的密码
CERTBOT_EMAIL=你的证书通知邮箱
```

`avatar` 是 PanSou 登录名，与 Linux 账号相互独立。密码使用 16–72 位字母、数字或 `._!@%+=-`，不要使用空白、引号、冒号、逗号或 `$`。JWT 密钥已自动生成，不要改为空，也不要把 `.env` 发到聊天或提交到 Git。重复运行初始化会保留原配置和密钥。

## 3. 启动并确认完整来源

```bash
sudo bash pansou/install.sh
```

安装会拉取固定标签 `ghcr.io/haipengtian/pansou-web:sha-420b940`，等待容器健康、确认网页及后台入口可访问、检查匿名请求被拒绝，并读取实际持久化的 `/opt/pansou/app/admin/settings.json`。成功时应显示 **111 个频道、74 个已配置启用插件**。安装失败会停止本次启动的容器，保留配置和数据；已有运行实例、占用端口或旧账号数据会在部署前阻止操作。同项目名的停止容器也会检查归属，只有部署目录、Compose 文件和数据挂载都一致时才允许重试。

`CHANNELS` 和 `ENABLED_PLUGINS` 只在第一次启动时写入后台。之后在 `/admin` 调整插件、频道和网盘类型，重启及重建容器会保留修改；改 `.env` 不会覆盖后台配置。请勿通过删除 `settings.json` 重置来源。

需要先从自己电脑预览时，可建立 SSH 隧道：

```bash
ssh -p 8866 -L 19000:127.0.0.1:9000 avatar@新服务器公网IP
```

保持隧道窗口打开，在自己电脑访问 `http://127.0.0.1:19000/admin`。服务器上的 `127.0.0.1:9000` 只代表服务器本机，公网 IP 加 9000 不能直接访问。

## 4. DNS 生效后启用 HTTPS

为 `sou.thpvip.cn` 添加指向新服务器公网 IP 的 A 记录；只有服务器实际支持 IPv6 时才添加 AAAA。若使用 Cloudflare，首次签发建议先使用「仅 DNS」。公网 TCP 80/443 必须能到达现有 Nginx。

```bash
sudo bash pansou/setup-nginx.sh
curl --noproxy '*' --fail --show-error https://sou.thpvip.cn/api/health
```

此入口复用 [公共 Nginx 工具](../nginx/README.md)，申请证书、配置站点与自动续期重载。无需重新安装已正常运行的主机 Nginx。后台地址为 **https://sou.thpvip.cn/admin**。

用 `.env` 中的管理员账号登录，在后台确认插件开关、默认频道和客户可选范围，再做一次实际搜索。需要登录数据源的插件在对应管理页补充账号/Cookie；普通客户账号在「用户管理」创建。环境管理员属于救急账号，在后台只读。

## 日常检查与备份

```bash
sudo bash pansou/verify.sh
sudo docker compose --project-directory pansou logs --tail=100 pansou
sudo docker compose --project-directory pansou restart pansou
sudo bash pansou/backup.sh
```

普通检查显示当前后台配置，不要求维持全开。仅在首次部署验收时使用 `verify.sh --initial` 核对完整清单。日志含访问与搜索信息，请按需脱敏后再分享。

备份会短暂停止本服务，打包整个应用数据（包括设置、账号和统计）及 `.env`、Compose 文件，再恢复原来运行中的服务。备份保存在 `/opt/pansou/backups/<时间戳>/`，只有出现 `COMPLETE` 文件的目录才是完整备份。备份包含密钥，应另外复制到可靠存储。

恢复时先停服务，将当前数据目录改名保留，再把备份的 `data.tar.gz` 解压到空的 `/opt/pansou/app`，恢复 `deployment.env` 为 `pansou/.env`（权限 600）及对应 Compose 文件，执行 `sudo docker compose --project-directory pansou up -d --wait --wait-timeout 180`，最后运行 `verify.sh`。切换镜像版本前先备份并确认新版本的数据兼容性。

## 验证部署包

```bash
bash pansou/tests/run.sh
```

此测试模拟 Docker 和网络，真实执行配置生成、文件保护与失败处理。GitHub Actions 另在隔离 Docker 环境中拉取发布镜像，验证管理员登录、实际注册和启用的完整插件、完整频道可选范围、后台设置变更、备份及重建后的持久化。
