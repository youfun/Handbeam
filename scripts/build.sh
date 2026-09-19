#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo " Handbeam 常规部署构建脚本"
echo "========================================"

MIX_ENV="${MIX_ENV:-prod}"
echo "当前环境: $MIX_ENV"

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
npm install --silent
npm run build

# 4. digest 静态资源
echo ""
echo "➡ digest 静态资源..."
mix phx.digest

# 5. 构建 OTP Release
echo ""
echo "➡ 构建 OTP Release..."
MIX_ENV=$MIX_ENV mix release handbeam --overwrite

# 6. 检查输出
echo ""

RELEASE_DIR="_build/${MIX_ENV}/rel/handbeam"
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
echo ""
echo "快速启动:"
echo "  sg"
echo ""
echo "或直接:"
echo "  前台:  $BIN start"
echo "  后台:  $BIN daemon"
echo "  停止:  $BIN stop"
echo "  附加:  $BIN remote"
echo ""
echo "如需自定义，可在启动前 export 覆盖任意变量："
echo "  PORT DATABASE_PATH OPENAI_BASE_URL OPENAI_MODEL"
