#!/usr/bin/env bash
# 各脚本共用的函数；由其他脚本 source，不单独运行

load_env() {
  if [ ! -f .env ]; then
    cp .env.example .env
    echo "已从 .env.example 生成 .env（需要改域名、端口等就编辑它）"
  fi
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
  : "${DSH_VERSION:?.env 缺少 DSH_VERSION}" "${DSH_DOMAIN:?.env 缺少 DSH_DOMAIN}"
  DSH_HOST_PORT="${DSH_HOST_PORT:-3080}"
  DSH_DATA_DIR="${DSH_DATA_DIR:-/opt/dsh}"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || { echo "请用 root 运行" >&2; exit 1; }
}

# 等到 dsh 在本机端口上有 HTTP 响应（未登录时返回 401 也算就绪）
wait_ready() {
  printf '等待 dsh 启动'
  for _ in $(seq 1 60); do
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${DSH_HOST_PORT}/" || true)"
    if [ "$code" != "000" ]; then
      echo
      echo "✅ dsh 已在 127.0.0.1:${DSH_HOST_PORT} 响应（HTTP ${code}）"
      return 0
    fi
    printf '.'
    sleep 2
  done
  echo
  echo "❌ 2 分钟内没有响应，最近日志：" >&2
  docker compose logs --tail 40 dsh >&2
  return 1
}
