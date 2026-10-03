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
