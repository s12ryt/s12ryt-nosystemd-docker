#!/usr/bin/env bash
# test_proxy.sh - Phase2 scrub proxy 整合測試:
# daemon.json registry-mirrors 注入 / proxy 生命週期冪等 / do_start 聯動 / doctor 行
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../src/docker-nosystemd.sh"

T="$(t_tmpdir)"

# --- daemon.json proxy 注入 ---

test_daemon_json_with_proxy() {
    local out j
    DSND_PROXY_PORT=5200 out="$(build_daemon_json 1 1 overlay2)"
    assert_contains "proxy: 應含 registry-mirrors" "registry-mirrors" "$out"
    assert_contains "proxy: mirror 位址" "http://127.0.0.1:5200" "$out"
    assert_contains "proxy: 應含 insecure-registries" "insecure-registries" "$out"
    printf '%s\n' "$out" > "$T/j.json"
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$T/j.json" 2>/dev/null; then
        _t_pass "proxy: daemon.json 應為合法 JSON"
    else
        _t_fail "proxy: daemon.json 應為合法 JSON" "parse error"
    fi
    # 回歸:未設 PORT 時不注入
    DSND_PROXY_PORT= out="$(build_daemon_json 1 1 overlay2)"
    if [[ "$out" != *"registry-mirrors"* ]]; then
        _t_pass "無 PORT 時不應注入 registry-mirrors"
    else
        _t_fail "無 PORT 時不應注入 registry-mirrors" "$out"
    fi
}

# --- proxy 生命週期 ---

test_proxy_lifecycle() {
    local fake="$T/fake-scrub"
    printf '#!/bin/bash\nsleep 300\n' > "$fake"
    chmod +x "$fake"
    DSND_SCRUB_BIN="$fake"
    DSND_PROXY_PID_FILE="$T/proxy.pid"
    DSND_PROXY_LOG_FILE="$T/proxy.log"
    scrub_needed() { return 0; }
    assert_ok "proxy_start 應成功" proxy_start
    assert_file_exists "proxy pidfile 應存在" "$T/proxy.pid"
    local p1 p2
    p1="$(cat "$T/proxy.pid")"
    if kill -0 "$p1" 2>/dev/null; then
        _t_pass "proxy 進程應存活"
    else
        _t_fail "proxy 進程應存活" "pid $p1 dead"
    fi
    proxy_start 2>/dev/null
    p2="$(cat "$T/proxy.pid")"
    assert_eq "proxy_start 冪等(pid 不變)" "$p1" "$p2"
    assert_ok "proxy_stop 應成功" proxy_stop
    if ! kill -0 "$p1" 2>/dev/null; then
        _t_pass "proxy 進程應已終止"
    else
        _t_fail "proxy 進程應已終止" "pid $p1 alive"
    fi
    if [[ ! -f "$T/proxy.pid" ]]; then
        _t_pass "proxy pidfile 應已刪除"
    else
        _t_fail "proxy pidfile 應已刪除" "still exists"
    fi
    assert_ok "proxy_stop 冪等(無 pidfile 返 0)" proxy_stop
    DSND_SCRUB_BIN=""; DSND_PROXY_PID_FILE=""; DSND_PROXY_LOG_FILE=""
    source "$SCRIPT_DIR/../../src/docker-nosystemd.sh"
}

# --- do_start 聯動啟動 proxy ---

test_do_start_starts_proxy() {
    local fake="$T/fake-scrub2"
    printf '#!/bin/bash\nsleep 300\n' > "$fake"
    chmod +x "$fake"
    local dock="$T/fake-dockerd"
    printf '#!/bin/bash\nsleep 300\n' > "$dock"
    chmod +x "$dock"
    DSND_PID_FILE="$T/d.pid"
    DSND_LOG_FILE="$T/d.log"
    DSND_DOCKERD_BIN="$dock"
    DSND_DOCKERD_DEFAULT_PIDFILE="$T/nonexistent-docker.pid"
    DSND_READY_PROBE="true"
    DSND_QUIET=1
    DSND_SCRUB_BIN="$fake"
    DSND_PROXY_PID_FILE="$T/p2.pid"
    DSND_PROXY_LOG_FILE="$T/p2.log"
    is_running() { return 1; }
    userns_wrap_needed() { return 1; }
    wait_daemon_ready() { return 0; }
    scrub_needed() { return 0; }
    local rc=0
    do_start || rc=$?
    assert_eq "do_start 應成功" "0" "$rc"
    assert_file_exists "do_start 應啟動 proxy pidfile" "$T/p2.pid"
    local pp
    pp="$(cat "$T/p2.pid" 2>/dev/null || true)"
    kill "$pp" 2>/dev/null || true
    local dp
    dp="$(cat "$T/d.pid" 2>/dev/null || true)"
    kill "$dp" 2>/dev/null || true
    rm -f "$T/d.pid" "$T/p2.pid"
    DSND_PID_FILE=""; DSND_LOG_FILE=""; DSND_DOCKERD_BIN=""
    DSND_DOCKERD_DEFAULT_PIDFILE=""; DSND_READY_PROBE=""; DSND_QUIET=""
    DSND_SCRUB_BIN=""; DSND_PROXY_PID_FILE=""; DSND_PROXY_LOG_FILE=""
    source "$SCRIPT_DIR/../../src/docker-nosystemd.sh"
}

# --- doctor 顯示 proxy 行 ---

test_doctor_mentions_proxy() {
    local fake="$T/fake-scrub3"
    printf '#!/bin/bash\nsleep 300\n' > "$fake"
    chmod +x "$fake"
    DSND_SCRUB_BIN="$fake"
    DSND_PROXY_PID_FILE="$T/p3.pid"
    probe_unshare_mount_ok() { return 0; }
    probe_unshare_userns_ok() { return 0; }
    probe_userns_range_map_ok() { return 0; }
    scrub_needed() { return 0; }
    printf '999999\n' > "$T/p3.pid"
    proxy_running() { return 0; }
    local out
    out="$(do_doctor 2>&1)"
    assert_contains "doctor 應含 scrub proxy 行" "scrub proxy" "$out"
    assert_contains "doctor 應顯示運行中" "運行中" "$out"
    # 未部署分支
    DSND_SCRUB_BIN="$T/not-deployed"
    scrub_needed() { return 1; }
    out="$(do_doctor 2>&1)"
    assert_contains "doctor 未部署應顯示無需或提示" "未部署" "$out"
    DSND_SCRUB_BIN=""; DSND_PROXY_PID_FILE=""
    source "$SCRIPT_DIR/../../src/docker-nosystemd.sh"
}

run_tests "$@"
