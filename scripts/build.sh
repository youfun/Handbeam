#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/build.sh [release-directory]

Build the production release into release-directory. When omitted, Handbeam
uses the platform's user application-data directory on the internal system disk.
EOF
}

if [[ $# -gt 1 ]] || [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
  usage
  [[ $# -le 1 ]] && exit 0
  exit 2
fi

echo "========================================"
echo " Handbeam 常规部署构建脚本"
echo "========================================"

MIX_ENV="${MIX_ENV:-prod}"
echo "当前环境: $MIX_ENV"

if [[ -n "${1:-}" ]]; then
  RELEASE_DIR="$1"
elif [[ "$(uname -s)" == "Darwin" ]]; then
  RELEASE_DIR="$HOME/Library/Application Support/Handbeam/release"
else
  RELEASE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/handbeam/release"
fi

mkdir -p "$(dirname "$RELEASE_DIR")"
RELEASE_DIR="$(cd "$(dirname "$RELEASE_DIR")" && pwd -P)/$(basename "$RELEASE_DIR")"
echo "Release 目录: $RELEASE_DIR"

# 1. 获取依赖
echo ""
echo "➡ 获取 Elixir 依赖..."
mix deps.get

# 1.5 创建默认目录
echo ""
echo "➡ 确保 ~/.handbeam/ 目录存在..."
mkdir -p "$HOME/.handbeam"

# 2. 编译
echo ""
echo "➡ 编译项目..."
mix compile

# 3. 前端资源
echo ""
echo "➡ 构建前端资源..."
mix assets.setup
mix assets.deploy

# 5. 构建 OTP Release
echo ""
echo "➡ 构建 OTP Release..."
MIX_ENV=$MIX_ENV mix release handbeam --path "$RELEASE_DIR" --overwrite

# 6. 检查输出
echo ""

if [[ -d "$RELEASE_DIR" ]]; then
  BIN="${RELEASE_DIR}/bin/handbeam"
  echo "🎉 构建完成！"
  echo "Release 目录: $RELEASE_DIR"
  echo "二进制:       $BIN"
  echo "大小:         $(du -sh "$RELEASE_DIR" | awk '{print $1}')"
else
  echo "⚠ 未找到 release 输出"
  exit 1
fi

echo ""
echo "默认配置已烘焙进 release (rel/env.sh.eex)，无需设置环境变量："
echo "  地址:      http://localhost:5008"
echo "  数据库:    ~/.handbeam/sigil.db"
echo "  模型配置:  ~/.handbeam/models.json"
echo "  运行日志:  ~/.handbeam/runtime/log/"
echo "  崩溃转储:  ~/.handbeam/runtime/erl_crash.dump"
echo ""
printf '  前台:  %q start\n' "$BIN"
printf '  后台:  %q daemon\n' "$BIN"
printf '  停止:  %q stop\n' "$BIN"
printf '  附加:  %q remote\n' "$BIN"
echo "  日志:  tail -F ~/.handbeam/runtime/log/erlang.log.1"
echo ""
echo "如需自定义，可在启动前 export 覆盖任意变量："
echo "  PORT DATABASE_PATH HANDBEAM_RUNTIME_DIR OPENAI_BASE_URL OPENAI_MODEL"
