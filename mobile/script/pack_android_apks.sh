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
