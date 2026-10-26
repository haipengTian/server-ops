#!/usr/bin/env bash
# 初次安装；不会重写已有后台设置，也不会替换正在运行的实例。
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
require_root
lock_operation
load_env
check_seed_env
check_docker
require_commands ss
running=$(compose ps --status running -q pansou)
[[ -z $running ]] || die '已有运行中的 PanSou；安装已取消。日常操作见 README'
existing=$(compose ps -a -q pansou)
if [[ -n $existing ]]; then
  [[ $existing != *[[:space:]]* ]] || die '发现多个已有实例，安装已取消'
  ownership=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}|{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Source}}{{end}}{{end}}' "$existing")
  [[ $ownership == "$OPS_DIR|$OPS_DIR/docker-compose.yml|$PANSOU_DATA_DIR/app" ]] ||
    die '同名项目中存在其他部署或数据目录的停止容器，安装已取消'
fi
listeners=$(ss -H -ltn "sport = :$PANSOU_HOST_PORT")
[[ -z $listeners ]] || die "本机端口 $PANSOU_HOST_PORT 已被占用"
[[ ! -e $PANSOU_DATA_DIR/app/admin/users.json ]] || die '发现已有账号数据；这是全新安装入口，已取消。日常重启见 README'
if [[ -e $PANSOU_DATA_DIR/app/admin/settings.json ]]; then check_settings --initial; fi
[[ ! -L $PANSOU_DATA_DIR/app ]] || die '应用数据目录不能是符号链接'
mkdir -p "$PANSOU_DATA_DIR/app"
chmod 700 "$PANSOU_DATA_DIR" "$PANSOU_DATA_DIR/app"
# 下载失败不动原容器；从启动开始失败则停止本次服务，保留全部数据供排查。
compose pull pansou
finish() {
  local status=$?
  if (( status != 0 )); then
    compose stop pansou || printf '停止失败，请检查 Docker 与 PanSou 容器状态。\n' >&2
    printf '安装未完成，数据已保留。检查 docker compose 日志后重试。\n' >&2
  fi
  exit "$status"
}
trap finish EXIT
compose up -d --wait --wait-timeout "$PANSOU_WAIT_SECONDS" pansou
verify_http
check_settings --initial
printf 'PanSou 已就绪：http://127.0.0.1:%s 。DNS 生效后运行 setup-nginx.sh。\n' "$PANSOU_HOST_PORT"
