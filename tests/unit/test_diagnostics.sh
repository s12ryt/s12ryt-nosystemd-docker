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
