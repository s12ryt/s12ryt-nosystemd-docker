#!/usr/bin/env bash
# run-tests.sh — unit test runner
# Usage: bash tests/run-tests.sh [tests/unit/test_xxx.sh ...]
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

if [[ $# -gt 0 ]]; then
  FILES=("$@")
else
  mapfile -t FILES < <(find "$SCRIPT_DIR/unit" -name 'test_*.sh' | sort)
fi

echo "==== docker-nosystemd unit tests ===="
overall=0
tmpout="$(mktemp)"
for f in "${FILES[@]}"; do
  base="$(basename "$f")"
  # Run each test file in an isolated bash: collect its own counters.
  # per-file timeout: 掛起的測試標記 TIMEOUT 而非掛死整個 runner
  # (WSL 非 root 下 unshare 子進程 kill/wait 偶發競態,歷史上掛過)
  timeout -k 5 "${DSND_TEST_TIMEOUT:-90}" bash -c '
    set -u
    source "'"$SCRIPT_DIR"'/lib.sh"
    source "'"$f"'"
    for fn in $(declare -F | awk "{print \$3}" | grep "^test_" | sort); do
      _DSND_CURRENT="$fn"
      "$fn" || true
    done
    printf "SUMMARY %d %d %d\n" "$_DSND_TESTS_RUN" "$_DSND_TESTS_PASSED" "$_DSND_TESTS_FAILED"
  ' > "$tmpout" 2>&1
  trc=$?
  summary="$(tail -1 "$tmpout")"
  run_count="$(awk '{print $2}' <<< "$summary")"
  if [[ "$summary" == SUMMARY\ * && "${run_count:-0}" -gt 0 ]]; then
    read -r _ run passed failed <<< "$summary"
    if [[ "$failed" -eq 0 ]]; then
      printf 'PASS %-28s %3d assertions\n' "$base" "$passed"
    else
      printf 'FAIL %-28s %3d passed / %3d FAILED\n' "$base" "$((run - failed))" "$failed"
      sed '$d' "$tmpout" | sed 's/^/    /'
      overall=1
    fi
  else
    if [[ "$trc" == 124 ]]; then
      printf 'TIMEOUT %-26s (per-file %ss, 掛起被終止;請檢查該文件是否觸發真實 unshare/probe)\n' "$base" "${DSND_TEST_TIMEOUT:-90}"
    else
      printf 'CRASH %-27s (no assertions collected)\n' "$base"
    fi
    head -20 "$tmpout" | sed 's/^/    /'
    overall=1
  fi
done
rm -f "$tmpout"
echo "==================================="
exit $overall
