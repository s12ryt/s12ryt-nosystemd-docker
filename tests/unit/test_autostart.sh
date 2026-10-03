#!/usr/bin/env bash
# test_autostart.sh — rc.local / profile.d 冪等注入單元測試
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../src/docker-nosystemd.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/src/docker-nosystemd.sh"

T="$(t_tmpdir)"

_setup_paths() {
  export DSND_RC_LOCAL="$T/rc.local"
  export DSND_PROFILE_DIR="$T/profile.d"
}

test_inject_creates_rc_local() {
  _setup_paths
  inject_autostart >/dev/null 2>&1 || true
  assert_file_exists "rc.local 應被創建" "$T/rc.local"
  assert_file_exists "profile.d 條目應被創建" "$T/profile.d/00-docker-nosystemd.sh"
}

test_rc_local_has_marker_and_call() {
  _setup_paths
  inject_autostart >/dev/null 2>&1 || true
  local content; content="$(cat "$T/rc.local")"
  assert_contains "rc.local 含 BEGIN 標記" "# BEGIN docker-nosystemd autostart" "$content"
  assert_contains "rc.local 含 END 標記" "# END docker-nosystemd autostart" "$content"
  assert_contains "rc.local 調用 start" "docker-nosystemd start" "$content"
}

test_inject_idempotent() {
  _setup_paths
  inject_autostart >/dev/null 2>&1 || true
  local first; first="$(cat "$T/rc.local")"
  inject_autostart >/dev/null 2>&1 || true
  local second; second="$(cat "$T/rc.local")"
  assert_eq "重複注入內容不變(冪等)" "$first" "$second"
  local count; count="$(grep -c 'BEGIN docker-nosystemd autostart' "$T/rc.local" || true)"
  assert_eq "標記只出現一次" "1" "$count"
}

test_inject_before_exit0() {
  _setup_paths
  printf '#!/bin/sh\necho early\nexit 0\n' > "$T/rc.local"
  inject_autostart >/dev/null 2>&1 || true
  local content; content="$(cat "$T/rc.local")"
  local marker_pos exit_pos
  marker_pos="$(grep -n 'BEGIN docker-nosystemd autostart' "$T/rc.local" | cut -d: -f1)"
  exit_pos="$(grep -n '^exit 0' "$T/rc.local" | cut -d: -f1)"
  assert_contains "已有 exit 0 仍保留" "exit 0" "$content"
  if [[ -n "$marker_pos" && -n "$exit_pos" && "$marker_pos" -lt "$exit_pos" ]]; then
    _t_assert; _t_pass
  else
    _t_fail "注入段應在 exit 0 之前 (marker@$marker_pos exit@$exit_pos)"
  fi
}

test_rc_local_executable() {
  _setup_paths
  inject_autostart >/dev/null 2>&1 || true
  if [[ -x "$T/rc.local" ]]; then
    _t_assert; _t_pass
  else
    _t_fail "rc.local 應有執行權限"
  fi
}

test_profile_d_idempotent() {
  _setup_paths
  inject_autostart >/dev/null 2>&1 || true
  local first; first="$(cat "$T/profile.d/00-docker-nosystemd.sh")"
  inject_autostart >/dev/null 2>&1 || true
  local second; second="$(cat "$T/profile.d/00-docker-nosystemd.sh")"
  assert_eq "profile.d 重複注入不變(冪等)" "$first" "$second"
}
