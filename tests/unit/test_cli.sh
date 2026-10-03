#!/usr/bin/env bash
# test_cli.sh — 命令列介面 / root 檢查單元測試
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../src/docker-nosystemd.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/src/docker-nosystemd.sh"

T="$(t_tmpdir)"

test_usage_exit_zero() {
  local rc=0
  usage >/dev/null 2>&1 || rc=$?
  assert_eq "usage 應返回 0" "0" "$rc"
}

test_unknown_command_fails() {
  local rc=0
  main nonexistent-cmd >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    _t_assert; _t_pass
  else
    _t_fail "未知命令應返回非零"
  fi
}

test_help_flag() {
  local out rc=0
  out="$(main --help 2>&1)" || rc=$?
  assert_eq "--help 返回 0" "0" "$rc"
  assert_contains "--help 顯示 install" "install" "$out"
  assert_contains "--help 顯示 start" "start" "$out"
}

test_require_root_as_nonroot() {
  # 測試環境(uid=1000)下應拒絕;若本身就是 root 則跳過該行為驗證
  if [[ "$(id -u)" -eq 0 ]]; then
    echo "  (以 root 運行,跳過非 root 拒絕斷言)" >&2
    _t_assert; _t_pass
    return
  fi
  local rc=0
  require_root >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    _t_assert; _t_pass
  else
    _t_fail "非 root 調用 require_root 應返回非零"
  fi
}

test_status_no_daemon_exit_code() {
  export DSND_PID_FILE="$T/nope.pid"
  rm -f "$DSND_PID_FILE"
  local rc=0
  do_status >/dev/null 2>&1 || rc=$?
  # 未運行 → 非 0(便於腳本判斷)
  if [[ "$rc" -ne 0 ]]; then
    _t_assert; _t_pass
  else
    _t_fail "未運行時 status 應返回非零"
  fi
}
