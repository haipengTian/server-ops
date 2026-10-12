# server-ops

服务器 `xiguapier`（AlmaLinux 10，Docker + 主机 nginx）上自部署服务的部署文件。不含任何密钥：密码、令牌都只在服务器本地生成和保存。

## 约定

- 每个服务一个目录，服务器上统一 clone 到 `/opt/server-ops`
- 应用容器只发布到 `127.0.0.1:<端口>`，由主机 nginx 统一做 HTTPS 和反向代理（80/443 只有 nginx 在用）
- 证书用 certbot webroot 签发，验证目录 `/var/www/certbot`，续期由 certbot 自带定时任务负责
- nginx 站点配置放 `/etc/nginx/conf.d/<域名>.conf`；改动后先 `nginx -t` 再 `systemctl reload nginx`

## 服务

| 服务 | 域名 | 本机端口 | 部署文件 |
|---|---|---|---|
| DeepSeek Harness | dsh.thpvip.xyz | 3080 | [dsh/](dsh/) |
| Sub2API 个人版本 | proxy.thpvip.xyz | 8088 | [sub2api/](sub2api/) |
| 博客（anheyu-app 二开） | blog.thpvip.xyz | 8091 | [haipengTian/anheyu-app `deploy/`](https://github.com/haipengTian/anheyu-app/tree/custom/deploy) |
