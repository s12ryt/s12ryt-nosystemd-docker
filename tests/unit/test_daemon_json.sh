#!/usr/bin/env bash
# test_daemon_json.sh — build_daemon_json 降級矩陣單元測試
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../src/docker-nosystemd.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/src/docker-nosystemd.sh"

test_json_full_mode() {
  local out; out="$(build_daemon_json 1 1 overlay2)"
  assert_contains "全功能模式含 storage-driver" '"storage-driver": "overlay2"' "$out"
  assert_not_contains "全功能模式不含 iptables:false" '"iptables": false' "$out"
  assert_not_contains "全功能模式不含 bridge:none" '"bridge": "none"' "$out"
}

test_json_no_iptables() {
  local out; out="$(build_daemon_json 0 1 overlay2)"
  assert_contains "iptables 降級 → iptables:false" '"iptables": false' "$out"
  assert_contains "iptables 降級 → ip-masq:false" '"ip-masq": false' "$out"
  assert_not_contains "僅 iptables 降級不含 bridge:none" '"bridge": "none"' "$out"
}

test_json_no_bridge_implies_no_iptables() {
  local out; out="$(build_daemon_json 1 0 overlay2)"
  assert_contains "bridge 降級 → bridge:none" '"bridge": "none"' "$out"
  assert_contains "bridge 降級連帶 iptables:false" '"iptables": false' "$out"
  assert_contains "bridge 降級連帶 ip-masq:false" '"ip-masq": false' "$out"
}

test_json_vfs_fallback() {
  local out; out="$(build_daemon_json 0 0 vfs)"
  assert_contains "vfs 後備 storage-driver" '"storage-driver": "vfs"' "$out"
  assert_contains "vfs 模式 bridge:none" '"bridge": "none"' "$out"
}

test_json_log_rotation_always() {
  local out; out="$(build_daemon_json 1 1 overlay2)"
  assert_contains "固定 log-driver json-file" '"log-driver": "json-file"' "$out"
  assert_contains "固定 max-size" '"max-size": "10m"' "$out"
  assert_contains "固定 max-file" '"max-file": "3"' "$out"
}

test_json_valid_no_trailing_comma() {
  local out; out="$(build_daemon_json 0 0 vfs)"
  assert_not_contains "不得有尾隨逗號(粗檢)" ', }' "$out"
  assert_not_contains "不得有尾隨逗號(行檢)" ',}' "$out"
}
