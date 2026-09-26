#!/usr/bin/env bash
# Pack one debug APK per Android ABI. Same entry point for a laptop and CI.
#
# Usage:
#   script/pack_android_apks.sh
#   script/pack_android_apks.sh --abi arm64-v8a
#   script/pack_android_apks.sh --skip-setup --skip-test
#
# One APK holds one OTP zip. arm64-v8a is phones; x86_64 is Chromos/emulators.
# Do not install the x86_64 APK on a phone.
set -euo pipefail

PROBE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROBE_ROOT"

abis=(arm64-v8a x86_64)
skip_setup=0
skip_test=0
artifacts_dir="$PROBE_ROOT/artifacts"

usage() {
  sed -n '2,12p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --abi)
      [[ $# -ge 2 ]] || { echo "--abi needs a value" >&2; exit 1; }
      abis=("$2")
      shift 2
      ;;
    --skip-setup)
      skip_setup=1
      shift
      ;;
    --skip-test)
      skip_test=1
      shift
      ;;
    --artifacts)
      [[ $# -ge 2 ]] || { echo "--artifacts needs a directory" >&2; exit 1; }
      artifacts_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

for abi in "${abis[@]}"; do
  case "$abi" in
    arm64-v8a|x86_64|armeabi-v7a) ;;
    *)
      echo "unsupported ABI: $abi" >&2
      exit 1
      ;;
  esac
done

if [[ "$skip_setup" -eq 0 ]]; then
  bash "$PROBE_ROOT/script/ci_setup_android.sh"
fi

# Ubuntu's libgit2-dev ships git2.h but not git2/sys/errors.h. ex_git calls
# git_error_set from that header. The symbol is still in libgit2.so.
ensure_libgit2_sys_header() {
  local root="${LIBGIT2_DIR:-}"
  if [[ -z "$root" ]]; then
    root="$(brew --prefix libgit2 2>/dev/null || true)"
  fi
  if [[ -z "$root" ]]; then
    root="/usr"
  fi
  if [[ -f "$root/include/git2/sys/errors.h" || -f /usr/local/include/git2/sys/errors.h ]]; then
    return 0
  fi

  local compat
  compat="$(mktemp -d)"
  mkdir -p "$compat/git2/sys"
  cat > "$compat/git2/sys/errors.h" << 'EOF'
#ifndef INCLUDE_git_sys_errors_h__
#define INCLUDE_git_sys_errors_h__
#include "git2/common.h"
GIT_EXTERN(int) git_error_set(int error_class, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));
GIT_EXTERN(int) git_error_set_str(int error_class, const char *string);
#endif
EOF
  local extra="-I${compat}"
  if [[ -n "${CFLAGS:-}" ]]; then
    export CFLAGS="${CFLAGS} ${extra}"
  else
    export CFLAGS="-O3 -std=c11 -Wall -Wextra -Wmissing-prototypes -Wno-missing-field-initializers -fPIC ${extra}"
  fi
}

ensure_libgit2_sys_header

if [[ "$skip_test" -eq 0 ]]; then
  mix test
fi

mkdir -p "$artifacts_dir"

for abi in "${abis[@]}"; do
  out="$artifacts_dir/Handbeam-${abi}.apk"
  echo "Packing $abi → $out"
  mix mob.pack_apk --abi "$abi" --no-install --output "$out"
  test -s "$out"
done

echo "APKs:"
ls -lh "$artifacts_dir"/Handbeam-*.apk
