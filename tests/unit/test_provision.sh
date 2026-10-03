#!/usr/bin/env bash
# test_provision.sh — provision_with_fallback 降級循環行為測試
# 背景:無特權容器(iptables/bridge 探測否 → 起始 net=none)第一輪 overlay2 掛載失敗,
# 舊版 break 條件誤判「降級後組合已試過」→ vfs 輪從未執行 → 直接 die。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/src/docker-nosystemd.sh"

T="$(t_tmpdir)"

# 清理其他測試留下的函數 override(runner 按字母序執行,污染會跨測試傳遞)。
# 重新 source 主腳本即可覆蓋一切 override(函數定義冪等、頂層無副作用);
# 不能用 unset -f:那會連 source 定義的原始函數一起刪除且無法恢復。
_clear_overrides() {
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/src/docker-nosystemd.sh"
}

# 共用 stub:write_daemon_config 記錄每輪 storage(第 3 參數)到 $T/calls
_setup_provision_stubs() {
  _clear_overrides
  : > "$T/calls"
  write_daemon_config() { printf '%s\n' "$3" >> "$T/calls"; }
  do_stop() { return 0; }
  DSND_CONF_FILE="$T/daemon.json"
  DSND_PID_FILE="$T/dsnd.pid"
  DSND_LOG_FILE="$T/daemon.log"
}

_lines() { wc -l < "$1" | tr -d ' '; }

test_storage_fallback_retries_vfs_when_net_none() {
  _setup_provision_stubs
  DSND_FORCE_NET_MODE="none"
  DSND_FORCE_STORAGE="overlay2"
  # 第 1 輪失敗(寫入 overlay 掛載失敗日誌供 analyze_log_hint 判讀),第 2 輪成功
  do_start() {
    if [[ "$(_lines "$T/calls")" -lt 2 ]]; then
      printf 'level=error msg="failed to mount overlay: operation not permitted" storage-driver=overlay2\n' > "$DSND_LOG_FILE"
      return 1
    fi
    return 0
  }
  local rc=0
  ( provision_with_fallback ) >"$T/prov.out" 2>&1 || rc=$?
  assert_eq "起始 none/overlay2 失敗後,vfs 輪必須實際執行並成功" "0" "$rc"
  assert_eq "應嘗試 2 輪(overlay2 → vfs)" "2" "$(_lines "$T/calls")"
  assert_eq "第 2 輪 storage 應為 vfs" "vfs" "$(sed -n '2p' "$T/calls")"
}

test_fallback_stops_only_after_vfs_attempted() {
  _setup_provision_stubs
  DSND_FORCE_NET_MODE="none"
  DSND_FORCE_STORAGE="overlay2"
  do_start() {
    printf 'level=error msg="failed to mount overlay: operation not permitted"\n' > "$DSND_LOG_FILE"
    return 1
  }
  local rc=0
  ( provision_with_fallback ) >"$T/prov2.out" 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then _t_assert; _t_pass; else _t_assert; _t_fail "全部組合失敗應非零退出"; fi
  assert_eq "放棄前最後一輪 storage 應為 vfs(試過才允許放棄)" "vfs" "$(tail -n 1 "$T/calls")"
  local n
  n="$(_lines "$T/calls")"
  if (( n <= 4 )); then _t_assert; _t_pass; else _t_assert; _t_fail "降級循環應有限(≤4 輪),實際 $n 輪"; fi
}

test_initial_storage_vfs_when_overlay_mount_probe_fails() {
  _setup_provision_stubs
  unset DSND_FORCE_STORAGE || true
  DSND_FORCE_NET_MODE="none"
  probe_overlay_fs() { return 0; }        # 核心支援 overlay
  probe_overlay_mount_ok() { return 1; }  # 但實際掛載被拒(無特權容器)
  do_start() { return 0; }                # 起始即 vfs → 一輪成功
  local rc=0
  ( provision_with_fallback ) >"$T/prov3.out" 2>&1 || rc=$?
  assert_eq "掛載實測失敗時應直接以 vfs 起始並成功" "0" "$rc"
  assert_eq "第 1 輪 storage 應為 vfs" "vfs" "$(sed -n '1p' "$T/calls")"
}

test_initial_storage_overlay2_when_probes_ok() {
  _setup_provision_stubs
  unset DSND_FORCE_STORAGE || true
  DSND_FORCE_NET_MODE="none"
  probe_overlay_fs() { return 0; }
  probe_overlay_mount_ok() { return 0; }
  do_start() { return 0; }
  local rc=0
  ( provision_with_fallback ) >"$T/prov4.out" 2>&1 || rc=$?
  assert_eq "探測皆可用時應維持 overlay2 起始" "0" "$rc"
  assert_eq "第 1 輪 storage 應為 overlay2" "overlay2" "$(sed -n '1p' "$T/calls")"
}

test_probe_overlay_mount_ok_mount_denied() {
  _clear_overrides
  mkdir -p "$T/fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$T/fakebin/mount"
  chmod +x "$T/fakebin/mount"
  PATH="$T/fakebin:$PATH"
  if probe_overlay_mount_ok; then _t_assert; _t_fail "mount 被拒應判定不可用"; else _t_assert; _t_pass; fi
}

test_probe_overlay_mount_ok_mount_succeeds() {
  _clear_overrides
  mkdir -p "$T/fakebin-ok"
  printf '#!/bin/sh\nexit 0\n' > "$T/fakebin-ok/mount"
  printf '#!/bin/sh\nexit 0\n' > "$T/fakebin-ok/umount"
  chmod +x "$T/fakebin-ok/mount" "$T/fakebin-ok/umount"
  PATH="$T/fakebin-ok:$PATH"
  if probe_overlay_mount_ok; then _t_assert; _t_pass; else _t_assert; _t_fail "mount 允許應判定可用"; fi
}

test_doctor_mentions_overlay_mount_probe() {
  _clear_overrides
  probe_overlay_mount_ok() { return 1; }
  DSND_PID_FILE="$T/none.pid"
  local out
  out="$(do_doctor 2>&1)" || true
  assert_contains "doctor 應顯示 overlay 掛載實測結果" "overlay 掛載實測" "$out"
}

# ---------- 任務 5:dockerd 起了但映像層註冊會 EPERM 的提前警告 ----------

test_provision_warns_when_unshare_unavailable() {
  _setup_provision_stubs
  DSND_FORCE_NET_MODE="none"
  DSND_FORCE_STORAGE="vfs"
  probe_unshare_mount_ok() { return 1; }
  do_start() { return 0; }
  local rc=0 out
  out="$(provision_with_fallback 2>&1)" || rc=$?
  assert_eq "vfs/none 一輪成功 provision 應成功" "0" "$rc"
  assert_contains "dockerd 起來但 unshare 不可用時應警告映像層註冊失敗" "register layer" "$out"
}

test_provision_silent_when_unshare_available() {
  _setup_provision_stubs
  DSND_FORCE_NET_MODE="none"
  DSND_FORCE_STORAGE="vfs"
  probe_unshare_mount_ok() { return 0; }
  do_start() { return 0; }
  local rc=0 out
  out="$(provision_with_fallback 2>&1)" || rc=$?
  assert_eq "provision 應成功" "0" "$rc"
  assert_not_contains "unshare 可用時不應出現註冊失敗警告" "register layer" "$out"
}
