#!/usr/bin/env bash
# Prepare handbeam_probe for mix mob.pack_apk (local or CI).
# Writes gitignored android/local.properties from ANDROID_HOME + cached OTP tarballs.
# Copies config/mob.exs.template → gitignored mob.exs (static_nifs).
set -euo pipefail

PROBE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROBE_ROOT"

android_home="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$android_home" ]]; then
  echo "ANDROID_HOME or ANDROID_SDK_ROOT must be set" >&2
  exit 1
fi
export ANDROID_HOME="$android_home"
export ANDROID_SDK_ROOT="$android_home"

if ! command -v mix >/dev/null; then
  echo "mix not on PATH" >&2
  exit 1
fi

mix local.hex 2.4.1 --force
mix local.rebar --force
mix deps.get
mix mob.write_mob_exs
mix mob.write_local_properties

props="$PROBE_ROOT/android/local.properties"
if [[ ! -f "$PROBE_ROOT/mob.exs" ]]; then
  echo "mob.exs was not written from config/mob.exs.template" >&2
  exit 1
fi

if [[ ! -f "$props" ]]; then
  echo "android/local.properties was not written" >&2
  exit 1
fi

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "MOB_ANDROID_OTP_RELEASE=$(grep '^mob.otp_release=' "$props" | cut -d= -f2-)"
    echo "MOB_ANDROID_OTP_RELEASE_ARM32=$(grep '^mob.otp_release_arm32=' "$props" | cut -d= -f2-)"
    echo "MOB_ANDROID_OTP_RELEASE_X86_64=$(grep '^mob.otp_release_x86_64=' "$props" | cut -d= -f2-)"
    echo "MOB_DIR=$(grep '^mob.mob_dir=' "$props" | cut -d= -f2-)"
  } >> "$GITHUB_ENV"
fi

echo "Android pack setup ready in $PROBE_ROOT"
