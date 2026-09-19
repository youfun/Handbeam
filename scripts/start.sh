#!/usr/bin/env bash
# ╔══════════════════════════════════════╗
# ║  Handbeam — 一键启动脚本              ║
# ║  解压后运行此脚本即可使用          ║
# ╚══════════════════════════════════════╝
set -euo pipefail
cd "$(dirname "$0")"

export PHX_SERVER=true
export PORT="${PORT:-5008}"
export PHX_HOST="${PHX_HOST:-localhost}"
export DATABASE_PATH="${DATABASE_PATH:-$HOME/.handbeam/sigil.db}"
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(openssl rand -base64 48 2>/dev/null || echo 'dev-fallback')}"

mkdir -p "$HOME/.handbeam"

# 获取本机 LAN IP
lan_ip=$(ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?192\.168\.[0-9.]+' | head -1 | awk '{print $2}')
if [[ -z "$lan_ip" ]]; then
  lan_ip=$(ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?10\.[0-9.]+' | head -1 | awk '{print $2}')
fi

echo "🚀 Handbeam 启动中..."
echo "   本机:     http://localhost:$PORT"
if [[ -n "$lan_ip" ]]; then
  echo "   局域网:   http://$lan_ip:$PORT"
fi
echo ""
echo "   VPS 部署时建议: export HANDBEAM_CHECK_ORIGIN=true"
echo "   按 Ctrl+C 停止"
echo ""

exec ./bin/handbeam start
