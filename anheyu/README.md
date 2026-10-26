# AnHeYu 博客迁移

将旧机博客完整迁到新机，继续使用 `https://blog.thpvip.xyz`、原管理员账号及原图片/文章路径。部署使用旧机实际运行的三个镜像摘要，先迁移再另行决定升级。应用只监听 `127.0.0.1:8091`，由主机公共 Nginx 接入；PostgreSQL 和 Redis 不发布公网端口。

已确认的旧机部署：`/opt/anheyu`，Compose 项目 `anheyu`，服务 `anheyu`、`postgres`、`redis`；PostgreSQL 17、Redis 7；本地 data 约7.6 MB，数据库约11 MB。具体镜像以备份时实际容器为准。

## 先准备新机和传输目录

在新机 `server-ops` 仓库根目录执行：

```bash
git pull --ff-only origin main
sudo docker info >/dev/null
sudo ss -ltn 'sport = :8091'
sudo install -d -m 700 -o avatar -g "$(id -gn avatar)" /home/avatar/blog-migration
```

确认8091无监听，`/opt/anheyu` 未被使用；恢复还会检查同名容器和数据卷，拒绝覆盖已有部署。需要 Docker Compose 插件、Bash、flock、tar、sha256sum、Python 3、curl、ss。Docker/公共 Nginx 沿用新机已有安装。

用 `docker pull` 预拉旧机三个容器对应的镜像可缩短维护窗口。应用当前固定 tag 是 `ghcr.io/haipengtian/anheyu-app:custom-8be703576a15fe7fa8a7d9d63735751555a33083`；最终恢复仍使用备份中的摘要。

## 在旧机备份并冻结写入

在旧机 `server-ops` 仓库根目录执行：

```bash
git pull --ff-only origin main
sudo bash anheyu/backup.sh /opt/anheyu
```

此命令会停止旧博客应用，维护期间旧博客暂时不可访问；PostgreSQL、Redis 保持运行。成功后应用保持停止，避免转移时出现新文章/评论/上传；失败则尝试恢复应用原运行状态。开始前准备好传输方式及新机空间，旧机其他应用继续运行。

输出目录位于 `/opt/anheyu/migration-backups/<时间>.<随机值>/`，也可用下列命令查看：

```bash
sudo cat /opt/anheyu/migration-backups/last-backup
```

迁移包包括：

| 文件 | 内容 |
| --- | --- |
| `database.dump` | PostgreSQL 完整数据库逻辑备份，包括文章、账号、设置及文件索引 |
| `redis.rdb` | Redis 快照，包含原键值与过期时间 |
| `files.tar.gz` | 完整 `data`、`themes`、`static`、`backup` 四个挂载目录 |
| `deployment.env` | 原部署 `.env`，保留数据库密码、Redis 密码与原令牌 |
| `docker-compose.images.yml` | 实际运行的三个镜像摘要 |
| `source-compose.yml` | 旧机原始 Compose 配置，留作查证和恢复参考 |
| `counts.tsv` | 原账号、文章、短文记录数 |
| `SHA256SUMS` | 上述七个文件的传输完整性校验清单 |

通过现有 SSH/SFTP 客户端，把这八个文件直接上传到新机 `/home/avatar/blog-migration/`，不要再套一层目录。只恢复自己生成且可信的迁移包。包内含数据库和密钥，保存在私有目录，不上传到网站或聊天。出现 `FAILED` 的备份不可使用。

## 在新机恢复

在新机 `server-ops` 仓库根目录执行：

```bash
sudo bash anheyu/restore.sh /home/avatar/blog-migration
sudo bash anheyu/status.sh
```

默认恢复到 `/opt/anheyu`。如需其他专用目录，可传第二个参数，父目录应已存在。目标目录已存在、项目已有容器、同名 PostgreSQL/Redis 数据卷已存在或端口被占用时，脚本拒绝覆盖。

恢复先验证迁移包、拉取原镜像，再恢复文件、Redis 快照和 PostgreSQL；数据库导入采用单事务并在错误时退出。对比账号、文章、短文数量一致后才启动应用，并检查首页 HTTP 和公开短文 API 的业务状态。失败会停止本次目标容器、记录 `MIGRATION_FAILED` 并保留文件和数据卷；检查现场后再处理，不要删库、清空卷或重跑初始化。

新机使用与旧机相同的密码和账号，不需要重新注册管理员、重置密码或重新导入品牌配置。文件存储在外部图床/S3时，保留原存储服务及地址；迁移包保存数据库映射和本地文件，不复制外部对象。

## 验证后再切换域名

可先在自己的电脑建立 SSH 隧道：

```bash
ssh -p 8866 -N -L 18091:127.0.0.1:8091 avatar@新服务器公网IP
```

打开 `http://127.0.0.1:18091`，用原账号登录，核对文章、短文、主题、附件和上传。站点原配置仍是正式域名，部分链接可能跳回正式域名；最终还需切换后验证原链接。

确认后把 `blog.thpvip.xyz` 的 DNS 指向新机，再从新机仓库根目录执行：

```bash
sudo bash nginx/add-site.sh \
  --domain blog.thpvip.xyz \
  --upstream http://127.0.0.1:8091 \
  --email tianhaipeng34@gmail.com
```

用原来的公网文章链接验证正文、图片和附件；原账号登录，测试一条短文及一次文件上传。验收完成前保留旧机部署、数据卷和完整迁移包。

如 DNS 尚未切换、新机尚未承接新写入，需要取消迁移时，在旧机执行：

```bash
cd /opt/anheyu
sudo docker compose -f docker-compose.prod.yml start anheyu
```

若新机已有新增文章、评论或上传，先处理两端数据差异再回切，避免丢失新数据。

## 后续维护

恢复目录的镜像摘要保存在 `docker-compose.images.yml`。手工执行 Compose 时同时指定两个文件，保留原镜像：

```bash
cd /opt/anheyu
sudo docker compose -f docker-compose.prod.yml -f docker-compose.images.yml ps -a
sudo docker compose -f docker-compose.prod.yml -f docker-compose.images.yml logs --tail=100 anheyu
```

不要输出完整 `docker compose config` 或 `.env`；日志分享前脱敏。`status.sh` 展示容器和恢复记录数，不输出凭据。再次运行 `backup.sh` 是迁移快照，会保持应用暂停；日常定时备份另行安排。

本地检查：`bash anheyu/tests/run.sh`；CI 另执行独占 Docker 环境中的 `anheyu/tests/container.sh`，演练真实 PostgreSQL/Redis/博客备份恢复。实际服务器的原账号登录、外部存储和 DNS/HTTPS 仍需上述生产验收。
