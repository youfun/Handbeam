#!/usr/bin/env bash
# Build a self-contained Web UI OTP release and archive it.
# Usage: scripts/pack_webui.sh linux-x86_64|macos-arm64
set -euo pipefail

target="${1:?target name, e.g. linux-x86_64}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

mix local.hex --force
mix local.rebar --force
mix deps.get
npm ci
export MIX_ENV=prod
mix compile
mix assets.deploy
mix release --overwrite

release_dir="_build/prod/rel/handbeam"
cp scripts/start.sh "$release_dir/start.sh"
chmod +x "$release_dir/start.sh" "$release_dir/bin/handbeam"

archive="handbeam-web-${target}.tar.gz"
rm -f "$archive" "${archive}.sha256"
tar -C "$release_dir" -czf "$archive" .

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$archive" > "${archive}.sha256"
else
  shasum -a 256 "$archive" > "${archive}.sha256"
fi
