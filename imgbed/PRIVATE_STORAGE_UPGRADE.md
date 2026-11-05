# 图床私密存储升级操作单

目标：`https://img.thpvip.xyz`，仅为 Cloudreve 打开 `cloudreve-test/` 专用测试目录；保留原公开上传及图片链接。服务器升级由用户执行。

应用通过个人 GitHub Actions 发布到 GHCR，服务器使用 `update.sh` 拉取镜像升级，不上传源码包部署。本次统一接口目标版本为 `2.7.7-custom.3`；确认对应发布工作流成功后再执行升级。

## 一、升级前保留恢复点

1. 确认图床现状正常，保存几条已有公开图片 URL 作为验收样本。确认 `/opt` 可容纳完整 app 备份；本地 R2 和备份会占服务器磁盘。
2. 更新配套运维仓库，只做正常快进：

   ```bash
   cd /opt/server-ops
   git status --short
   git pull --ff-only origin main
   ```

   若有与本次更新冲突的本地改动，先处理冲突，不强制覆盖。**保留实际 `.env`，不运行 init，不重新生成密钥**。运维仓库只更新脚本和配置模板，应用本体在下一步通过 GHCR 镜像更新。
3. 在编辑 `.env` **之前**执行：

   ```bash
   cd /opt/server-ops/imgbed
   sudo bash status.sh
   sudo bash backup.sh
   ```

   备份短暂停写，成功后恢复服务。记录输出备份路径，并保留异机副本。备份包含完整 SQLite/WAL、本地对象、原配置和旧镜像摘要；不得发到聊天或放公开目录。

## 二、沿用 ImageBed 的 Telegram 存储

1. 保留原 Telegram Bot 和频道，在图床上传设置确认渠道启用。使用图床「网页设置 → 客户端设置」的默认上传类型和名称；未设置时使用 Telegram 和首个启用渠道。Cloudreve 不再重复配置底层渠道。频道应没有公开用户名，并控制成员范围；ImageBed 会拒绝公开目标。
2. Telegram 无需新增环境变量。此前设置的 `IMGBED_PRIVATE_STORAGE_CHANNELS=cfr2:R2_env` 可保留，不会改走本地磁盘。只有 ImageBed 默认选择 R2/S3 时，才需要此环境变量显式允许非公开渠道，例如：

   ```dotenv
   IMGBED_PRIVATE_STORAGE_CHANNELS=cfr2:R2_env
   ```

   值不加引号、空格。空值禁用 R2/S3 私密上传，不影响普通上传和新版 Telegram 私密上传。不要改变已有公开桶权限或域名。
3. **`2.7.7-custom.3` 镜像发布工作流成功后**执行：

   ```bash
   cd /opt/server-ops/imgbed
   sudo bash update.sh ghcr.io/haipengtian/cloudflare-imgbed:2.7.7-custom.3
   sudo bash status.sh
   ```

   `update.sh` 先拉镜像，再停应用、备份、切换并检查。记录本次备份位置。失败后若目标已尝试启动，会保持暂停，先检查失败阶段和日志，不反复运行升级/初始化。

## 三、验收顺序

1. 原管理员可登录，匿名管理/上传仍被拒绝；原公开图片 URL 内容正常。普通上传、读取、删除仍按原渠道工作。
2. 在图床管理页面创建专用 API Token，权限为 `upload`、`manage`、`delete`。只在本机 Cloudreve 的 ImageBed 策略页填入，不发给协作者。
3. Cloudreve 只填 `https://img.thpvip.xyz`、目录 `cloudreve-test` 和 API Token，不选择 Telegram/R2/S3。已创建的测试策略保留，新版忽略旧底层渠道字段。不将其他用户组或已有文件切到新策略；先给测试账号/测试组使用。
4. 后续联调只在 `cloudreve-test/` 上传小样例：确认内容、重试、Range/视频跳转、下载、匿名直链拒绝、改名移动、删除及重启后保留。远端清理只针对本次明确创建的测试文件。
5. 只有真实链路通过后，才讨论正式目录、容量、备份与其他用户迁移。HTML 隔离预览、Office 预览仍是独立待办。
6. Telegram 删除沿用现有语义：移除 ImageBed 记录和读取入口，不撤回频道消息或承诺 Telegram 物理擦除。服务器备份不包含频道中的原始文档。

## 四、回退

- **尚未写入私密文件**且人工确认目标镜像没有额外数据库迁移时，可沿用 `sudo bash rollback.sh --database-compatible`。本次源码没有 DDL 变更；操作者仍须核对实际发布内容。保留新运维脚本，旧镜像会忽略新增环境变量。
- **已经写入私密文件**时，先停止 Cloudreve 写入。旧版不识别完整私密协议，不直接将升级后数据交给旧版继续服务。保留升级后 app 数据离线，按 [README 第7节](README.md#7-不兼容迁移恢复) 使用**第一步的升级前备份**恢复到未使用的新专用目录。首轮本地 R2 文件随快照；外部 S3 不随快照回退，需另行隔离与核对。
- 恢复到备份时点会缺少之后的新记录；维护窗口内停止其他上传，并保留升级后现场以便人工补回。不得删库、清卷、覆盖旧备份。
- 图床回退后，Cloudreve 的 capability 检查会拒绝新私密上传。Cloudreve 可停止候选程序并用原启动脚本恢复原本地存储试用；已有本地样例无需迁移。

## 检查边界

可选配置解析测试覆盖缺省/继承值保持关闭、显式允许值可以读取。Linux CI 同时执行原生命周期套件、nginx测试和Compose校验；个人镜像工作流执行容器构建、私密handler回归、普通上传和重启检查。服务器真实渠道、升级与恢复仍由操作者验收。
