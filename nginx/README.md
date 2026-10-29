# 用域名接入本机应用

在 `/opt/server-ops` 执行：先初始化主机环境，再为每个应用添加域名。

```bash
sudo bash nginx/install.sh
sudo bash nginx/add-site.sh \
  --domain vpn.thpvip.xyz \
  --upstream http://127.0.0.1:8888 \
  --email 你的邮箱
```

上面的 8888 示例使用 HTTP。如果面板本身已开启 HTTPS，按下面的“HTTPS 后端”填写。接入成功后访问 `https://vpn.thpvip.xyz/原来的登录路径/`，路径末尾的斜杠也保留。

## 先配置解析和入口

- 为域名添加指向本机公网 IPv4 的 A 记录；只有 IPv6 确实可达时才添加 AAAA。
- 使用 Cloudflare 时，首次接入先选择“仅 DNS”。此配置以客户端直连 nginx 为前提；后续开启 CDN 时另行配置可信代理及真实 IP。
- 云安全组和主机防火墙需放行 TCP 80、443。HTTP-01 签发和续期都需要公网 80 可达。
- 80、443 由本机 nginx 使用，不能与 Xray 等其他进程占用的监听地址冲突。

确认后端协议，在服务器执行：

```bash
curl --noproxy '*' -I --max-time 5 http://127.0.0.1:8888/
curl --noproxy '*' -kI --max-time 5 https://127.0.0.1:8888/
```

`-k` 只用于这里的 HTTPS 协议诊断。收到 200、跳转、401 或 404 均说明收到了 HTTP 响应；根路径 404 不等于面板故障。脚本会使用 GET 检查后端，连接失败、协议错误和 5xx 会在写入站点和签发前停止。

## 初始化主机

`install.sh` 面向 CentOS Stream 9，以及 AlmaLinux / Rocky Linux 9、10，使用发行版仓库及 EPEL 安装 nginx、Certbot，不要求新版 nginx 的 `http2 on` 语法。

它准备 `/var/www/certbot`，在 SELinux 启用时允许 nginx 连接应用端口，安装证书续期后的 nginx 重载 hook，并启用发行版提供的 Certbot timer。可以重复执行。

默认不操作 firewalld。如果已启用 firewalld，先查看公网网卡所在的活动区域：

```bash
sudo firewall-cmd --get-active-zones
```

例如实际区域是 `public`，使用：

```bash
sudo bash nginx/install.sh --firewall-zone public
```

此选项只向指定活动区域添加 HTTP/HTTPS 的运行时和永久规则，不重载或启用 firewalld，不改 SSH 8866、Xray 30039 或其他规则。云安全组需在云厂商处单独设置。

## 给另一个应用添加域名

新域名同样解析到这台服务器，后端使用自己的本机端口：

```bash
sudo bash nginx/add-site.sh \
  --domain app.example.com \
  --upstream http://127.0.0.1:8080 \
  --email 你的邮箱
```

后端地址只接受 HTTP/HTTPS、回环地址 `127.0.0.1` 或 `[::1]` 及端口，不接受凭据、路径或公网后端；80、443 留给 nginx。请求路径和查询参数原样传给应用，不需要把面板随机路径写进命令。配置支持 WebSocket、流式响应和 128 MB 请求体。

每个站点保存在 `/etc/nginx/conf.d/<域名>.conf`，独立证书保存在 `/etc/letsencrypt/live/<域名>/`。脚本只更新带有 `Managed by server-ops/nginx` 标记的本站配置；若目标已经由其他部署入口管理，则停止并保留原文件。

所有站点共用 `/etc/nginx/conf.d/00-server-ops-websocket-map.conf` 中的短变量，适配 nginx 默认的 `variables_hash_bucket_size 64`。更新脚本后，直接重跑接入命令即可安装该文件，无需修改全局哈希参数或重新执行主机安装。

如果 nginx 报告当前域名与另一份配置冲突，即使 `nginx -t` 返回成功，脚本也会停止发布并恢复本站配置，避免把仍由旧后端响应的站点误报为接入成功。

首次签发时临时站点只开放 ACME 验证路径，不提供明文面板。Certbot 使用 webroot 模式并配置邮箱、接受 Let's Encrypt 服务条款；有效证书通过 `--keep-until-expiring` 复用。重复执行相同命令可以更新本站配置。

## 给远程桌面加一层网页登录密码

对 noVNC 等管理入口，先在服务器创建密码文件，再发布域名。下面适用于发行版默认的 nginx 工作进程组 `nginx`；若改过工作进程用户，请使用对应组。密码在终端交互输入，不放进命令参数。

```bash
sudo dnf install -y httpd-tools
# 首次创建用 -c；已有文件时不带 -c，避免删除其他账号。
if sudo test -e /etc/nginx/qqdesk.htpasswd; then
  sudo htpasswd -B /etc/nginx/qqdesk.htpasswd qqadmin
else
  sudo htpasswd -cB /etc/nginx/qqdesk.htpasswd qqadmin
fi
sudo chown root:nginx /etc/nginx/qqdesk.htpasswd
sudo chmod 640 /etc/nginx/qqdesk.htpasswd
if command -v restorecon >/dev/null; then sudo restorecon -v /etc/nginx/qqdesk.htpasswd; fi
read -rp "证书通知邮箱：" CERT_EMAIL
sudo bash nginx/add-site.sh \
  --domain qqdesk.thpvip.xyz \
  --upstream http://127.0.0.1:16081 \
  --basic-auth-file /etc/nginx/qqdesk.htpasswd \
  --email "$CERT_EMAIL"
```

访问 `https://qqdesk.thpvip.xyz/vnc.html?autoconnect=1&resize=scale`，先输入网页账号 `qqadmin` 和刚设置的密码，再输入原 VNC 密码。桌面后端保持 `127.0.0.1:16081`，不开放公网桌面端口。

此选项保护整个 HTTPS 应用路径，包括 WebSocket，HTTP 的 ACME 验证仍可访问。nginx 不把这层认证的 Authorization 头传入后端。密码文件必须长期保留且 nginx 工作进程可读；脚本检查匿名 HTTPS 返回 401，正确密码与实际桌面连接需在浏览器验证。更新受保护站点时仍需带上 `--basic-auth-file`；省略该选项会按普通无认证站点配置。原有不带此选项的应用保持原来的认证方式。

## HTTPS 后端

HTTPS 后端默认严格验证证书。若证书签给一个域名、服务只在本机端口监听，用该域名验证证书并发送 SNI：

```bash
sudo bash nginx/add-site.sh \
  --domain vpn.thpvip.xyz \
  --upstream https://127.0.0.1:8888 \
  --upstream-server-name panel.example.com \
  --email 你的邮箱
```

私有 CA 证书可以追加 `--upstream-ca /绝对路径/ca.pem`。CA 文件需要长期保留，nginx 重载时仍需读取。

如果现有回环面板使用自签名证书，且暂时不调整面板证书，可以明确允许跳过**本机后端**的证书验证：

```bash
sudo bash nginx/add-site.sh \
  --domain vpn.thpvip.xyz \
  --upstream https://127.0.0.1:8888 \
  --upstream-insecure \
  --email 你的邮箱
```

这个选项只适用于回环 HTTPS 后端；公网 `vpn.thpvip.xyz` 的证书与就绪检查始终严格验证。脚本不会在 HTTP 失败后自动改成 HTTPS，也不会自动跳过证书校验。

## 验证访问和续期

接入成功后，在电脑浏览器验证证书和原登录路径，实际登录面板并检查应用功能。脚本的本机检查验证证书、域名及 HTTP 响应；公网 DNS、安全组和业务登录需通过外部访问确认。

```bash
sudo certbot certificates
sudo certbot renew --cert-name vpn.thpvip.xyz --dry-run
systemctl list-timers --all | grep certbot
```

Certbot 成功续期后执行 `/etc/letsencrypt/renewal-hooks/deploy/server-ops-nginx-reload`，先 `nginx -t` 再重载，使新 worker 使用新证书。安装时找不到发行版续期 timer 会明确失败。

遇到配置、签发、重载或 HTTPS 就绪失败，脚本恢复原站点与共用 map 并重载；首次接入失败则删除本次创建的配置。已签发的证书保留，方便修复原因后重试。若恢复本身失败，会报告保留备份的事务目录，需立即检查 nginx。包安装、SELinux 和明确添加的防火墙规则不随站点事务回滚。

原有 `sub2api/`、`imgbed/` 等应用的 `setup-nginx.sh` 继续使用各自配置。本次接入不会修改 3x-ui 的监听、密码、代理入站或订阅设置；2096 订阅服务需另行接入。域名登录验证通过后，再将管理面板收紧到回环监听。

## 开发验证

```bash
find nginx -name '*.sh' -print0 | xargs -0 -n1 bash -n
shellcheck -P SCRIPTDIR -x nginx/*.sh nginx/tests/*.sh
bash nginx/tests/run.sh "$(command -v nginx)"
bash nginx/tests/integration.sh
```

隔离测试运行真实部署入口，模拟包管理、服务、HTTP 和 CA 签发边界；传入 nginx 路径后，还将真实入口渲染的配置交给 nginx，以默认 64 字节变量哈希桶检查。真实 nginx 集成测试使用临时端口和临时证书，验证多域名、HTTP/HTTPS 后端、路径转发、IP 头和 ACME 路径。它们不执行真实 dnf 安装或访问 Let's Encrypt，也不代替目标服务器部署验收。
