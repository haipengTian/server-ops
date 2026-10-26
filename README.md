# server-ops

自部署服务的部署文件，现有服务运行于服务器 `xiguapier`（AlmaLinux 10，Docker + 主机 nginx）。公共 nginx 工具也用于新 CentOS Stream 9 主机。不含任何密钥：密码、令牌都只在服务器本地生成和保存。

## 约定

- 每个服务一个目录，服务器上统一 clone 到 `/opt/server-ops`
- 应用容器只发布到 `127.0.0.1:<端口>`，由主机 nginx 统一做 HTTPS 和反向代理（80/443 只有 nginx 在用）
- 证书用 certbot webroot 签发，验证目录 `/var/www/certbot`，续期由 certbot 自带定时任务负责
- nginx 站点配置放 `/etc/nginx/conf.d/<域名>.conf`；改动后先 `nginx -t` 再 `systemctl reload nginx`

## 公共 HTTPS 入口

新服务器先安装环境，再给应用添加域名；完整参数和 HTTPS 后端用法见 [nginx/](nginx/)。

```bash
sudo bash nginx/install.sh
sudo bash nginx/add-site.sh --domain vpn.thpvip.xyz --upstream http://127.0.0.1:8888 --email 你的邮箱
```

8888 的示例按 HTTP 后端填写，实际协议需先确认。已有服务继续使用各自的 `setup-nginx.sh`。

## 服务

| 服务 | 域名 | 本机端口 | 部署文件 |
|---|---|---|---|
| DeepSeek Harness | dsh.thpvip.xyz | 3080 | [dsh/](dsh/) |
| Sub2API 个人版本 | proxy.thpvip.xyz | 8088 | [sub2api/](sub2api/) |
| CloudFlare ImgBed 个人版本 | img.thpvip.xyz | 7658 | [imgbed/](imgbed/) |
| CLIProxyAPI 与个人管理前端 | cpa.thpvip.xyz | 8317 | [cliproxyapi/](cliproxyapi/) |
| PanSou 盘搜（新服务器） | sou.thpvip.cn | 9000 | [pansou/](pansou/) |
| 博客（anheyu-app 二开） | blog.thpvip.xyz | 8091 | [迁移部署](anheyu/)；[应用仓库](https://github.com/haipengTian/anheyu-app/tree/custom/deploy) |
