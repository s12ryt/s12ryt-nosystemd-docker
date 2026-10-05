#!/usr/bin/env bash
# test_lifecycle.sh — dockerd 生命週期管理單元測試(fake daemon)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../src/docker-nosystemd.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/src/docker-nosystemd.sh"

T="$(t_tmpdir)"

_setup_fake() {
  export DSND_PID_FILE="$T/docker.pid"
  export DSND_LOG_FILE="$T/docker.log"
  export DSND_DOCKERD_BIN="$T/fake-dockerd"
  export DSND_READY_PROBE="true"
  export DSND_DOCKERD_DEFAULT_PIDFILE="$T/docker-default.pid"
  cat > "$DSND_DOCKERD_BIN" <<'EOF'
#!/usr/bin/env bash
echo "fake-dockerd started"
exec sleep 300
EOF
  chmod +x "$DSND_DOCKERD_BIN"
}

test_is_running_no_pidfile() {
  _setup_fake
  rm -f "$DSND_PID_FILE"
  if is_running; then
    _t_fail "無 pidfile 應視為未運行"
  else
    _t_assert; _t_pass
  fi
}

test_is_running_dead_pid() {
  _setup_fake
  echo 99999999 > "$DSND_PID_FILE"   # 幾乎不可能存在的 PID
  if is_running; then
    _t_fail "死 PID 應視為未運行"
  else
    _t_assert; _t_pass
  fi
}

test_do_start_and_running() {
  _setup_fake
  do_start >/dev/null 2>&1
  if is_running; then
    _t_assert; _t_pass
  else
    _t_fail "do_start 後應在運行"
  fi
  assert_file_exists "啟動後 pidfile 應存在" "$DSND_PID_FILE"
}

test_do_start_idempotent() {
  _setup_fake
  do_start >/dev/null 2>&1
  local pid1; pid1="$(cat "$DSND_PID_FILE")"
  do_start >/dev/null 2>&1
  local pid2; pid2="$(cat "$DSND_PID_FILE")"
  assert_eq "重複 start 不重啟進程" "$pid1" "$pid2"
}

test_do_stop() {
  _setup_fake
  do_start >/dev/null 2>&1
  local pid; pid="$(cat "$DSND_PID_FILE")"
  do_stop >/dev/null 2>&1
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    _t_fail "do_stop 後進程應退出"
  else
    _t_assert; _t_pass
  fi
  if [[ -f "$DSND_PID_FILE" ]]; then
    _t_fail "do_stop 後 pidfile 應刪除"
  else
    _t_assert; _t_pass
  fi
}

test_do_stop_idempotent() {
  _setup_fake
  rm -f "$DSND_PID_FILE"
  if do_stop >/dev/null 2>&1; then
    _t_assert; _t_pass
  else
    _t_fail "無 pidfile 時 stop 應靜默成功(冪等)"
  fi
}

test_wait_ready_timeout() {
  _setup_fake
  export DSND_READY_PROBE="false"
  local rc=0
  DSND_READY_TIMEOUT=2 wait_daemon_ready >/dev/null 2>&1 || rc=$?
  assert_eq "就緒探測超時應返回非零" "1" "$rc"
}

# ── dockerd 默認 pidfile(/var/run/docker.pid)殘留處理 ──

test_do_start_adopts_live_dockerd() {
  # 模拟:dockerd 默認 pidfile 指向一個活進程(如 systemd 起的 dockerd 殘留)
  _setup_fake
  sleep 300 & local adopted=$!
  echo "$adopted" > "$DSND_DOCKERD_DEFAULT_PIDFILE"
  rm -f "$DSND_PID_FILE"
  DSND_QUIET=1 do_start >/dev/null 2>&1
  assert_eq "應收養活 dockerd(寫入自身 pidfile)" "$adopted" "$(cat "$DSND_PID_FILE")"
  kill "$adopted" 2>/dev/null || true
}

test_do_start_cleans_dead_default_pidfile() {
  # 模拟:默認 pidfile 指向已死進程 → 應刪除殘留並正常啟動
  _setup_fake
  echo 99999999 > "$DSND_DOCKERD_DEFAULT_PIDFILE"
  rm -f "$DSND_PID_FILE"
  DSND_QUIET=1 do_start >/dev/null 2>&1
  assert_eq "死 pidfile 下 do_start 應成功" "0" "$?"
  if is_running; then
    _t_assert; _t_pass
  else
    _t_fail "清理殘留後應正常啟動"
  fi
  assert_not_contains "殘留死 pidfile 應被刪除" "99999999" "$(cat "$DSND_DOCKERD_DEFAULT_PIDFILE" 2>/dev/null || echo gone)"
  do_stop >/dev/null 2>&1 || true
}

# ── 任務 6:user namespace 包裝模式(繞過映像層註冊 EPERM)──

test_do_start_no_wrap_when_direct_ok() {
  _setup_fake
  mkdir -p "$T/bin"
  cat > "$T/bin/unshare" <<EOF
#!/usr/bin/env bash
echo "unshare \$*" >> "$T/unshare2.args"
exec "\$@"
EOF
  chmod +x "$T/bin/unshare"
  PATH="$T/bin:$PATH"
  is_running() { return 1; }
  userns_wrap_needed() { return 1; }
  wait_daemon_ready() { return 0; }
  rm -f "$DSND_PID_FILE" "$T/unshare2.args"
  DSND_QUIET=1 do_start >/dev/null 2>&1
  assert_eq "直接模式 do_start 應成功" "0" "$?"
  if [[ ! -e "$T/unshare2.args" ]]; then
    _t_assert; _t_pass
  else
    _t_fail "直接模式不應調用 unshare 包裝"
  fi
  do_stop >/dev/null 2>&1 || true
  source "$SCRIPT_DIR/src/docker-nosystemd.sh"
}

test_do_start_wraps_dockerd_in_userns() {
  _setup_fake
  mkdir -p "$T/bin"
  cat > "$T/bin/unshare" <<EOF
#!/usr/bin/env bash
echo "unshare \$*" >> "$T/unshare1.args"
exec "\$@"
EOF
  chmod +x "$T/bin/unshare"
  PATH="$T/bin:$PATH"
  is_running() { return 1; }
  userns_wrap_needed() { return 0; }
  probe_userns_range_map_ok() { return 1; } # 強制走單映射分支
  wait_daemon_ready() { return 0; }
  rm -f "$DSND_PID_FILE" "$T/unshare1.args"
  DSND_QUIET=1 do_start >/dev/null 2>&1
  assert_eq "包裝模式 do_start 應成功" "0" "$?"
  local _i=0
  while [[ ! -s "$T/unshare1.args" && $_i -lt 50 ]]; do sleep 0.1; _i=$((_i + 1)); done
  assert_contains "啟動命令應含 unshare -Ur" "-Ur" "$(cat "$T/unshare1.args" 2>/dev/null || echo MISSING)"
  assert_contains "unshare 應包裹 dockerdbin" "$DSND_DOCKERD_BIN" "$(cat "$T/unshare1.args" 2>/dev/null || echo MISSING)"
  assert_contains "包裝模式應傳 -G root(socket chown 需在 gid 映射內)" "-G root" "$(cat "$T/unshare1.args" 2>/dev/null || echo MISSING)"
  do_stop >/dev/null 2>&1 || true
  source "$SCRIPT_DIR/src/docker-nosystemd.sh"
}

test_userns_wrap_needed_matrix() {
  probe_unshare_mount_ok() { return 1; }
  probe_unshare_userns_ok() { return 0; }
  DSND_USERNS_MODE=auto userns_wrap_needed; local rc=$?
  assert_eq "auto:mount 拒+userns 可 → 需包裝" "0" "$rc"
  DSND_USERNS_MODE=never userns_wrap_needed; rc=$?
  assert_eq "never:恆不包裝" "1" "$rc"
  DSND_USERNS_MODE=force userns_wrap_needed; rc=$?
  assert_eq "force:userns 可 → 包裝" "0" "$rc"
  probe_unshare_mount_ok() { return 0; }
  DSND_USERNS_MODE=auto userns_wrap_needed; rc=$?
  assert_eq "auto:mount 可 → 不包裝" "1" "$rc"
  probe_unshare_mount_ok() { return 1; }
  probe_unshare_userns_ok() { return 1; }
  DSND_USERNS_MODE=auto userns_wrap_needed; rc=$?
  assert_eq "auto:雙拒 → 不包裝(無法包)" "1" "$rc"
  DSND_USERNS_MODE=force userns_wrap_needed; rc=$?
  assert_eq "force:userns 拒 → 不包裝" "1" "$rc"
  source "$SCRIPT_DIR/src/docker-nosystemd.sh"
}

# ── 任務 8:userns 範圍映射模式(0-65535 恆等映射,層內 chown 全放行)──

test_probe_userns_range_map_ok() {
  # unshare 用「函數 override」stub(非獨立腳本進程):子 shell 內同步寫檔,
  # 避免 probe 的 kill $p 在腳本進程完成寫檔前把它殺掉(競態)
  rm -f "$T/rangeprobe.args"
  unshare() { echo "unshare $*" >> "$T/rangeprobe.args"; return 0; }
  # _write 在 probe 的 kill 之前執行:在此同步等待背景子 shell 完成寫檔,
  # 消除「kill 殺死子 shell 使 echo 來不及執行」的競態
  _write_userns_maps() {
    local _i=0
    while [[ ! -s "$T/rangeprobe.args" && $_i -lt 50 ]]; do sleep 0.1; _i=$((_i+1)); done
    return 0
  }
  _read_userns_map_ok() { return 0; }
  probe_userns_range_map_ok; local rc=$?
  assert_eq "映射寫入+驗證成功應返 0" "0" "$rc"
  local _i=0
  while [[ ! -s "$T/rangeprobe.args" && $_i -lt 50 ]]; do sleep 0.1; _i=$((_i+1)); done
  assert_contains "probe 應以 unshare --user 起 ns" "--user" "$(cat "$T/rangeprobe.args" 2>/dev/null || echo MISSING)"
  _write_userns_maps() { return 1; }
  probe_userns_range_map_ok; rc=$?
  assert_eq "映射寫入失敗應返 1" "1" "$rc"
  unset -f unshare
  source "$SCRIPT_DIR/src/docker-nosystemd.sh"
}

test_do_start_userns_range_mode() {
  _setup_fake
  is_running() { return 1; }
  userns_wrap_needed() { return 0; }
  probe_userns_range_map_ok() { return 0; }
  launch_dockerd_userns_range() { echo "launch:$1:$2" >> "$T/rangelaunch.calls"; echo 4242; }
  wait_daemon_ready() { return 0; }
  rm -f "$DSND_PID_FILE" "$T/rangelaunch.calls"
  DSND_QUIET=1 do_start >/dev/null 2>&1
  assert_eq "範圍映射模式 do_start 應成功" "0" "$?"
  assert_contains "應以範圍映射 launcher 啟動" "$DSND_DOCKERD_BIN" "$(cat "$T/rangelaunch.calls" 2>/dev/null || echo MISSING)"
  assert_eq "pidfile 應取 launcher 返回 pid" "4242" "$(cat "$DSND_PID_FILE" 2>/dev/null || echo MISSING)"
  rm -f "$DSND_PID_FILE"
  source "$SCRIPT_DIR/src/docker-nosystemd.sh"
}

test_write_userns_maps_records_reason() {
  local T; T="$(t_tmpdir)"
  local rc=0
  # 場景1:目錄不存在 → uid_map 寫入失敗,應記錄原因
  DSND_PROC_BASE="$T/nonexistent"
  rc=0
  _write_userns_maps 999 || rc=$?
  assert_eq "uid_map 寫入失敗應返回 1" "1" "$rc"
  assert_contains "應記錄 uid_map 失敗原因" "uid_map" "${_DSND_RANGE_FAIL_REASON:-}"
  # 場景2:uid_map 可寫、setgroups/gid_map 為目錄(寫入必敗)→ gid_map 失敗(帶 setgroups 連帶)
  mkdir -p "$T/proc2/123"
  : > "$T/proc2/123/uid_map"
  mkdir "$T/proc2/123/setgroups" "$T/proc2/123/gid_map"
  DSND_PROC_BASE="$T/proc2"
  rc=0
  _write_userns_maps 123 || rc=$?
  assert_eq "gid_map 寫入失敗應返回 1" "1" "$rc"
  assert_contains "應記錄 gid_map 失敗原因" "gid_map" "${_DSND_RANGE_FAIL_REASON:-}"
  assert_contains "應連帶記錄 setgroups 失敗" "setgroups" "${_DSND_RANGE_FAIL_REASON:-}"
  # 場景3:全部可寫 → 成功且原因清空
  rmdir "$T/proc2/123/setgroups" "$T/proc2/123/gid_map"
  : > "$T/proc2/123/setgroups"
  : > "$T/proc2/123/gid_map"
  rc=0
  _write_userns_maps 123 || rc=$?
  assert_eq "全部寫入成功應返回 0" "0" "$rc"
  assert_eq "成功後原因應清空" "" "${_DSND_RANGE_FAIL_REASON:-}"
  DSND_PROC_BASE=""
  source "$SCRIPT_DIR/src/docker-nosystemd.sh"
}
