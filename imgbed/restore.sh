#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
[[ $# == 1 ]] || die '用法：sudo bash imgbed/restore.sh <完整备份目录>；仅用于新机首次恢复'
lock_operation
require_commands realpath tar sha256sum ss
backup=$(realpath -e -- "$1")
[[ -d $backup && ! -e $backup/FAILED ]] || die '备份不存在或已标记失败'
for name in data.tar.gz deployment.env image SHA256SUMS; do
  [[ -f $backup/$name && ! -L $backup/$name ]] || die "备份缺少普通文件：$name"
done
# 仅校验备份约定的三个文件，拒绝清单中夹带其他路径。
mapfile -t sums < "$backup/SHA256SUMS"
[[ ${#sums[@]} == 3 ]] || die '备份校验清单无效'
index=0
for name in data.tar.gz deployment.env image; do
  line=${sums[$index]}
  [[ ${line:0:64} =~ ^[a-f0-9]{64}$ && ${line:64} == "  $name" ]] || die '备份校验清单无效'
  index=$((index + 1))
done
(cd "$backup" && sha256sum -c --status SHA256SUMS) || die '备份校验失败，请重新传输完整备份'
tar -tzf "$backup/data.tar.gz" >/dev/null || die '数据归档不可读取'
image=$(cat "$backup/image")
validate_image "$image"
destination_env=$ENV_FILE
[[ ! -e $destination_env && ! -L $destination_env ]] || die '当前目录已有 .env，拒绝覆盖；此入口仅用于新机首次恢复'
# 原配置只作为数据读取；不执行、不改动备份中的密钥。
ENV_FILE="$backup/deployment.env"
load_env
export IMGBED_IMAGE=$image
[[ ! -e $IMGBED_DATA_DIR/app && ! -L $IMGBED_DATA_DIR/app && ! -e $STATE_DIR && ! -L $STATE_DIR ]] ||
  die '目标已有 app 或 state，拒绝覆盖；请保留现场并检查是否曾部署'
check_docker
[[ -z $(compose ps -a -q imgbed) ]] || die '同名 Compose 项目已有图床容器，拒绝覆盖'
if ss -H -ltn "sport = :$IMGBED_HOST_PORT" | grep -q .; then
  die "本机端口 $IMGBED_HOST_PORT 已被占用"
fi
# 镜像不可拉取时，不提交配置或数据。
compose pull imgbed
mkdir -p "$IMGBED_DATA_DIR"
chmod 700 "$IMGBED_DATA_DIR"
staging=$(mktemp -d "$IMGBED_DATA_DIR/.restore.XXXXXX")
target_started=false
completed=false
finish_restore() {
  local status=$?
  trap - EXIT
  if [[ $completed != true ]]; then
    if [[ $target_started == true ]]; then
      if ! compose stop imgbed; then
        printf '无法确认恢复容器已暂停，请立即检查 Docker 状态。\n' >&2
      fi
      state_write failed-restore "$IMGBED_IMAGE" || true
    fi
    printf '恢复未完成；已恢复的数据与配置保留，暂存目录：%s。请检查现场，不要重新初始化。\n' "$staging" >&2
    status=1
  fi
  exit "$status"
}
trap finish_restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$staging/app"
tar -xzf "$backup/data.tar.gz" -C "$staging/app"
cp "$backup/deployment.env" "$staging/deployment.env"
chmod 600 "$staging/deployment.env"
ENV_FILE="$staging/deployment.env"
set_config IMGBED_IMAGE "$image"
mv -T -- "$staging/app" "$IMGBED_DATA_DIR/app"
mv -T -- "$staging/deployment.env" "$destination_env"
ENV_FILE=$destination_env
mkdir -p "$STATE_DIR" "$IMGBED_DATA_DIR/backups"
chmod 700 "$STATE_DIR" "$IMGBED_DATA_DIR/backups"
target_started=true
wait_app
record_release restore
rmdir "$staging"
completed=true
printf '原配置与完整 app 数据已恢复，服务监听 127.0.0.1:%s。\n' "$IMGBED_HOST_PORT"
printf '请使用原管理密码，核对渠道、旧图片及上传，再切换 DNS 并配置公共 Nginx。\n'
