#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck source=lib.sh
source "$(dirname -- "$0")/lib.sh"
usage() {
  cat <<'EOF'
用法：sudo bash nginx/install.sh [--firewall-zone 区域]
安装 nginx、Certbot、SELinux 配置、证书验证目录和自动续期。
默认不修改防火墙；指定区域时只向已运行的 firewalld 添加 HTTP/HTTPS 服务。
支持 CentOS Stream 9，以及 AlmaLinux / Rocky Linux 9、10。
EOF
}
FIREWALL_ZONE=''
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --firewall-zone) (($# >= 2)) || die '--firewall-zone 缺少值'; FIREWALL_ZONE=$2; shift 2 ;;
    *) die "未知参数：$1" ;;
  esac
done
[[ -z $FIREWALL_ZONE || $FIREWALL_ZONE =~ ^[a-zA-Z0-9_-]+$ ]] || die '防火墙区域名称无效'
require_root
[[ -f /etc/os-release ]] || die '找不到 /etc/os-release'
# 发行版维护的系统文件，不是应用传入的配置。
# shellcheck source=/dev/null
source /etc/os-release
case "${ID:-}:${VERSION_ID%%.*}" in
  centos:9|almalinux:9|almalinux:10|rocky:9|rocky:10) ;;
  *) die '安装入口只支持 CentOS Stream 9 和 AlmaLinux / Rocky Linux 9、10' ;;
esac
require_commands dnf systemctl ss flock
lock_operation
require_owned "$RELOAD_HOOK"
listeners=$(ss -ltnp)
conflicts=$(awk '$4 ~ /:(80|443)$/ && $0 !~ /"nginx"/ {print}' <<< "$listeners")
[[ -z $conflicts ]] || die "80/443 已被其他进程占用，请保留现有服务并先安排入口：$conflicts"
if [[ -n $FIREWALL_ZONE ]]; then
  require_commands firewall-cmd
  systemctl is-active --quiet firewalld || die 'firewalld 未运行；不会自动启用，请去掉 --firewall-zone'
  firewall-cmd --get-active-zones | awk '/^[^[:space:]]/{print $1}' | grep -Fxq "$FIREWALL_ZONE" ||
    die '指定区域不是活动区域，请核对公网网卡所在区域'
fi

dnf install -y dnf-plugins-core
dnf config-manager --set-enabled crb
dnf install -y epel-release
# webroot 模式不需要 nginx 插件，也不升级到其他 nginx 软件源。
dnf install -y nginx certbot curl policycoreutils
require_commands nginx certbot curl getenforce setsebool
timer=''
for candidate in certbot-renew.timer certbot.timer; do
  if systemctl cat "$candidate" >/dev/null 2>&1; then timer=$candidate; break; fi
done
[[ -n $timer ]] || die '未找到发行版的 Certbot 续期 timer，请检查 certbot 软件包；尚未启动 nginx'
if [[ $(getenforce) != Disabled ]]; then
  setsebool -P httpd_can_network_connect on
fi
install -d -m 755 "$WEBROOT"
if command -v restorecon >/dev/null; then restorecon -RF "$WEBROOT"; fi
install -d -m 755 "$(dirname -- "$RELOAD_HOOK")"
install -m 755 "$OPS_DIR/reload-after-renew.sh" "$RELOAD_HOOK"
nginx -t
systemctl enable --now nginx
systemctl enable --now "$timer"
if [[ -n $FIREWALL_ZONE ]]; then
  for service in http https; do
    if ! firewall-cmd --zone="$FIREWALL_ZONE" --query-service="$service" >/dev/null; then
      firewall-cmd --zone="$FIREWALL_ZONE" --add-service="$service"
    fi
    if ! firewall-cmd --zone="$FIREWALL_ZONE" --permanent --query-service="$service" >/dev/null; then
      firewall-cmd --zone="$FIREWALL_ZONE" --permanent --add-service="$service"
    fi
  done
fi
printf 'nginx 和 Certbot 已安装，自动续期：%s\n' "$timer"
printf '云安全组需允许 TCP 80/443。现有 SSH、代理入站及应用配置保持原样。\n'
if [[ -z $FIREWALL_ZONE ]]; then
  printf '未修改主机防火墙；如需添加 80/443，请核对活动区域后用 --firewall-zone 重跑。\n'
fi
printf '下一步：sudo bash nginx/add-site.sh --domain 域名 --upstream http://127.0.0.1:端口 --email 邮箱\n'
