#!/usr/bin/env bash
# test_diagnostics.sh — cgroup / overlay 探測與失敗日誌輸出單元測試
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/src/docker-nosystemd.sh"

T="$(t_tmpdir)"

test_probe_cgroup_v2_detected() {
  printf 'sysfs /sys fs\nsysfs /sys/fs/cgroup cgroup2 rw,nosuid,nodev,noexec 0 0\n' > "$T/mounts-v2"
  DSND_PROC_MOUNTS="$T/mounts-v2"
  if probe_cgroup; then _t_assert; _t_pass; else _t_assert; _t_fail "cgroup2 掛載應判定可用"; fi
  assert_eq "cgroup_flavor 應輸出 v2" "v2" "$(cgroup_flavor)"
}

test_probe_cgroup_v1_detected() {
  printf 'tmpfs /sys/fs/cgroup/cpuset cgroup rw,nosuid,nodev,noexec 0 0\n' > "$T/mounts-v1"
  DSND_PROC_MOUNTS="$T/mounts-v1"
  if probe_cgroup; then _t_assert; _t_pass; else _t_assert; _t_fail "cgroup(v1)掛載應判定可用"; fi
  assert_eq "cgroup_flavor 應輸出 v1" "v1" "$(cgroup_flavor)"
}

test_probe_cgroup_missing() {
  printf 'sysfs /sys fs\nproc /proc proc rw 0 0\n' > "$T/mounts-none"
  DSND_PROC_MOUNTS="$T/mounts-none"
  if probe_cgroup; then _t_assert; _t_fail "無 cgroup 掛載應判定不可用"; else _t_assert; _t_pass; fi
  assert_eq "cgroup_flavor 應輸出 none" "none" "$(cgroup_flavor)"
}

test_probe_cgroup_missing_file() {
  DSND_PROC_MOUNTS="$T/no-such-mounts"
  if probe_cgroup; then _t_assert; _t_fail "mounts 檔不存在應判定不可用且不炸"; else _t_assert; _t_pass; fi
  assert_eq "mounts 檔不存在 flavor 為 none" "none" "$(cgroup_flavor)"
}

test_probe_overlay_fs_supported() {
  printf 'nodev\toverlay\n' > "$T/fsfiles-yes"
  DSND_PROC_FILESYSTEMS="$T/fsfiles-yes"
  if probe_overlay_fs; then _t_assert; _t_pass; else _t_assert; _t_fail "核心支援 overlay 應判定可用"; fi
}

test_probe_overlay_fs_missing() {
  printf 'nodev\text4\nnodev\txfs\n' > "$T/fsfiles-no"
  DSND_PROC_FILESYSTEMS="$T/fsfiles-no"
  if probe_overlay_fs; then _t_assert; _t_fail "核心不支援 overlay 應判定不可用"; else _t_assert; _t_pass; fi
}

test_dump_log_tail_shows_recent_lines() {
  printf 'line1\nline2\nline3-error\n' > "$T/daemon.log"
  DSND_LOG_FILE="$T/daemon.log"
  local out
  out="$(dump_log_tail 2 2>&1)"
  assert_contains "應輸出日誌尾部行" "line3-error" "$out"
  assert_not_contains "不應包含最早行" "line1" "$out"
}

test_dump_log_tail_no_file_silent() {
  DSND_LOG_FILE="$T/no-such.log"
  local out rc=0
  out="$(dump_log_tail 2>&1)" || rc=$?
  assert_eq "日誌不存在應返回 0" "0" "$rc"
  assert_eq "日誌不存在應無輸出" "" "$out"
}

# ---------- unshare / proc status(任務 5:映像層註冊 EPERM 診斷)----------

_make_stub_bin() { # <dir> <name> <exit-code>
  mkdir -p "$1"
  printf '#!/bin/sh\nexit %s\n' "$3" > "$1/$2"
  chmod +x "$1/$2"
}

test_probe_unshare_mount_ok_allowed() {
  _make_stub_bin "$T/bin-nsok" unshare 0
  PATH="$T/bin-nsok:$PATH"
  if probe_unshare_mount_ok; then _t_assert; _t_pass; else _t_assert; _t_fail "unshare -m 允許應判定可用"; fi
}

test_probe_unshare_mount_ok_denied() {
  _make_stub_bin "$T/bin-nsdeny" unshare 1
  PATH="$T/bin-nsdeny:$PATH"
  if probe_unshare_mount_ok; then _t_assert; _t_fail "unshare -m 被拒應判定不可用"; else _t_assert; _t_pass; fi
}

test_probe_unshare_userns_ok_allowed() {
  _make_stub_bin "$T/bin-uok" unshare 0
  PATH="$T/bin-uok:$PATH"
  if probe_unshare_userns_ok; then _t_assert; _t_pass; else _t_assert; _t_fail "unshare -U 允許應判定可用"; fi
}

test_probe_unshare_userns_ok_denied() {
  _make_stub_bin "$T/bin-udeny" unshare 1
  PATH="$T/bin-udeny:$PATH"
  if probe_unshare_userns_ok; then _t_assert; _t_fail "unshare -U 被拒應判定不可用"; else _t_assert; _t_pass; fi
}

test_probe_unshare_missing_binary() {
  local saved_path="$PATH"
  mkdir -p "$T/bin-empty"
  PATH="$T/bin-empty"
  if probe_unshare_mount_ok; then _t_assert; _t_fail "無 unshare 命令應判定不可用且不炸"; else _t_assert; _t_pass; fi
  PATH="$saved_path"
}

test_proc_status_field_parses_values() {
  printf 'Name:\tbash\nSeccomp:\t2\nCapEff:\t00000000a80425fb\n' > "$T/self-status"
  DSND_PROC_STATUS="$T/self-status"
  assert_eq "應解析 Seccomp 欄位" "2" "$(proc_status_field Seccomp)"
  assert_eq "應解析 CapEff 欄位" "00000000a80425fb" "$(proc_status_field CapEff)"
}

test_proc_status_field_missing() {
  printf 'Name:\tbash\n' > "$T/self-status-min"
  DSND_PROC_STATUS="$T/self-status-min"
  local v rc=0
  v="$(proc_status_field Seccomp)" || rc=$?
  assert_eq "欄位不存在應返回非零" "1" "$rc"
  assert_eq "欄位不存在應無值" "" "$v"
}

test_doctor_mentions_unshare_seccomp_capeff() {
  _make_stub_bin "$T/bin-doc" unshare 0
  PATH="$T/bin-doc:$PATH"
  printf 'Seccomp:\t2\nCapEff:\t00000000a80425fb\n' > "$T/status-doc"
  DSND_PROC_STATUS="$T/status-doc"
  DSND_PID_FILE="$T/none.pid"
  probe_userns_range_map_ok() { return 0; }
  local out
  out="$(do_doctor 2>&1)" || true
  assert_contains "doctor 應顯示 unshare 掛載ns 探測" "unshare" "$out"
  assert_contains "doctor 應顯示 user namespace 探測" "user namespace" "$out"
  assert_contains "doctor 應顯示 Seccomp 狀態" "Seccomp" "$out"
  assert_contains "doctor 應顯示 CapEff 內容" "CapEff" "$out"
  assert_contains "doctor 應顯示 userns 包裝模式決策" "userns 包裝模式" "$out"
  assert_contains "doctor 應顯示 userns 範圍映射探測" "userns 範圍映射" "$out"
}

test_doctor_shows_range_fail_reason() {
  _make_stub_bin "$T/bin-doc2" unshare 0
  PATH="$T/bin-doc2:$PATH"
  printf 'Seccomp:\t2\nCapEff:\t000001ffffffffff\n' > "$T/status-doc2"
  DSND_PROC_STATUS="$T/status-doc2"
  DSND_PID_FILE="$T/none2.pid"
  probe_userns_range_map_ok() { return 1; }
  _DSND_RANGE_FAIL_REASON="測試原因-xyz"
  local out
  out="$(do_doctor 2>&1)" || true
  assert_contains "doctor 範圍映射不可用應顯示判定" "不可用" "$out"
  assert_contains "doctor 範圍映射不可用應顯示具體原因" "測試原因-xyz" "$out"
}
