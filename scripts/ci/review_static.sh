#!/usr/bin/env bash
# Review one update against its parent. Existing findings stay local; CI fails
# only on issues introduced by this commit.
set -euo pipefail

if [[ $# -ge 1 && -n "${1:-}" ]]; then
  base_sha="$(git merge-base "$1" HEAD)"
else
  base_sha="$(git rev-parse HEAD^)"
fi

changed_elixir="$(
  git diff --name-only --diff-filter=ACMR "$base_sha" HEAD -- '*.ex' '*.exs' \
    | grep -E '^(lib|test/support)/' || true
)"

echo "Review base: $base_sha"

mix credo diff --from-git-ref "$base_sha"

if [[ -z "$changed_elixir" ]]; then
  echo "Credence: no changed Elixir sources."
  exit 0
fi

printf '%s\n' "$changed_elixir" > /tmp/handbeam-credence-files.txt
HANDBEAM_CREDENCE_FILES=/tmp/handbeam-credence-files.txt mix run --no-start test/support/credence_check.exs
