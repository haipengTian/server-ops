#!/usr/bin/env bash
# 模型配置：生成两个配置文件（已存在就不动），修正权限，并检查 Key 是否都填了。
#   提供商和模型：<数据目录>/home/profiles/web/cordis.patch.yml
#   API Key：     <数据目录>/home/.credentials.yaml（权限 600）
# 改完保存即可，dsh 自动重新读取，不用重启；改完可以再运行一次本脚本做检查。
# 本脚本不会打印任何 Key 的内容。
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

require_root
load_env

HOME_DIR="${DSH_DATA_DIR}/home"
PROFILE_DIR="${HOME_DIR}/profiles/web"
PATCH="${PROFILE_DIR}/cordis.patch.yml"
CRED="${HOME_DIR}/.credentials.yaml"
PLACEHOLDER="把这里换成"

[ -d "$HOME_DIR" ] || { echo "没有 ${HOME_DIR}，先运行 ./install.sh" >&2; exit 1; }

# 目录和文件都要属于容器里的 node 用户（uid 1000），dsh 才能读写
mkdir -p "$PROFILE_DIR"
chown 1000:1000 "${HOME_DIR}/profiles" "$PROFILE_DIR"

copy_if_absent() { # 模板 目标
  if [ -e "$2" ]; then
    echo "已存在，保持不动：$2"
  else
    cp "$1" "$2"
    echo "已生成：$2"
  fi
}

copy_if_absent model/cordis.patch.example.yml "$PATCH"
copy_if_absent model/credentials.example.yaml "$CRED"
chown 1000:1000 "$PATCH" "$CRED"
chmod 644 "$PATCH"
chmod 600 "$CRED"   # 其他用户可读时 dsh 会拒绝加载

# 检查：cordis.patch.yml 里每个 apiKeyEnv 在 .credentials.yaml 的 refs 下都有值
echo
problems=0
names="$(sed -nE 's/^[[:space:]]*apiKeyEnv:[[:space:]]*([A-Za-z0-9_]+).*/\1/p' "$PATCH" | sort -u)"
for name in $names; do
  line="$(grep -E "^[[:space:]]+${name}:" "$CRED" || true)"
  if [ -z "$line" ]; then
    echo "⚠️  ${CRED} 的 refs 下缺少 ${name}，加一行：  ${name}: <你的Key>"
    problems=1
  elif printf '%s' "$line" | grep -q "$PLACEHOLDER"; then
    echo "⚠️  ${name} 还是模板里的占位文字，换成真实的 Key"
    problems=1
  fi
done
if grep -qE 'relay\.example\.com|your-model-id' "$PATCH"; then
  echo "⚠️  ${PATCH} 里的 baseURL 或模型 ID 还是示例值"
  problems=1
fi

if [ "$problems" -eq 0 ]; then
  echo "✅ 检查通过。到网页的模型选择器里选你配置的模型即可。"
  echo "   如果请求报错，看日志：docker compose logs --tail 50 dsh"
else
  echo
  echo "编辑这两个文件（保存后自动生效）："
  echo "  vi ${PATCH}"
  echo "  vi ${CRED}"
  echo "改完再运行一次 ./setup-model.sh 检查。"
fi
