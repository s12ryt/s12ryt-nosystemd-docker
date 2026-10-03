#!/usr/bin/env bash
# test_detect.sh — detect_distro / detect_init 單元測試
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/src/docker-nosystemd.sh"

T="$(t_tmpdir)"

_make_os_release() { # 內容
  printf '%s\n' "$1" > "$T/os-release"
  printf '%s' "$T/os-release"
}

# ── detect_distro ──────────────────────────────
test_distro_debian() {
  local f; f=$(_make_os_release 'ID=debian
VERSION_ID="12"')
  assert_eq "debian 偵測" "debian" "$(DSND_OS_RELEASE="$f" detect_distro)"
}

test_distro_ubuntu() {
  local f; f=$(_make_os_release 'ID=ubuntu
VERSION_ID="22.04"')
  assert_eq "ubuntu 偵測" "ubuntu" "$(DSND_OS_RELEASE="$f" detect_distro)"
}

test_distro_alpine() {
  local f; f=$(_make_os_release 'ID=alpine
VERSION_ID="3.20"')
  assert_eq "alpine 偵測" "alpine" "$(DSND_OS_RELEASE="$f" detect_distro)"
}

test_distro_id_like_debian() {
  local f; f=$(_make_os_release 'ID=linuxmint
ID_LIKE="ubuntu debian"')
  assert_eq "ID_LIKE 含 ubuntu 映射" "ubuntu" "$(DSND_OS_RELEASE="$f" detect_distro)"
}

test_distro_unsupported() {
  local f; f=$(_make_os_release 'ID=centos')
  local out rc=0
  out="$(DSND_OS_RELEASE="$f" detect_distro)" || rc=$?
  assert_eq "centos 不支援應返回非零" "1" "$rc"
  assert_eq "centos 輸出 unsupported" "unsupported" "$out"
}

test_distro_missing_file() {
  local rc=0
  out="$(DSND_OS_RELEASE="$T/nonexistent" detect_distro)" || rc=$?
  assert_eq "os-release 不存在應返回非零" "1" "$rc"
}

# ── detect_init ──────────────────────────────
test_init_systemd_dir() {
  mkdir -p "$T/root1/run/systemd/system"
  assert_eq "run/systemd/system 存在 → systemd" "systemd" \
    "$(DSND_INIT_PROBE_ROOT="$T/root1" detect_init)"
}

test_init_force_no_systemd() {
  mkdir -p "$T/root2/run/systemd/system"
  assert_eq "FORCE_NO_SYSTEMD 覆蓋 → none" "none" \
    "$(DSND_FORCE_NO_SYSTEMD=1 DSND_INIT_PROBE_ROOT="$T/root2" detect_init)"
}

test_init_probe_root_empty() {
  mkdir -p "$T/root3"
  assert_eq "乾淨 root → none" "none" \
    "$(DSND_INIT_PROBE_ROOT="$T/root3" DSND_FORCE_NO_SYSTEMD=1 detect_init)"
}
