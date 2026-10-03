#!/usr/bin/env bash
# test_install_debian.sh — 整合測試:無 systemd 環境完整安裝 + 啟動 + smoke
# 前置條件:
#   1. 以 root 執行
#   2. PID 1 不是 systemd(模擬容器 VPS)
# 用法:WSL 内 bash tests/integration/test_install_debian.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/tests/lib.sh"

echo "== 前置檢查 =="
if [[ "$(id -u)" -ne 0 ]]; then
    echo "FAIL: 需以 root 執行" >&2
    exit 1
fi
PID1="$(tr -d '[:space:]' < /proc/1/comm 2>/dev/null || echo '?')"
echo "PID1 = $PID1"
if [[ "$PID1" == "systemd" ]]; then
    echo "SKIP: PID1 是 systemd,本測試需在無 systemd 環境執行" >&2
    exit 2
fi

SRC="$SCRIPT_DIR/src/docker-nosystemd.sh"

# ── install 全流程 ──
echo "== 執行 install =="
install_output="$(bash "$SRC" install 2>&1)"; install_rc=$?
echo "$install_output"
assert_eq "install 應成功退出 0" "0" "$install_rc"

# ── 安裝產物驗證 ──
assert_ok "docker info 應成功" docker info
assert_ok "docker compose version 應成功" docker compose version
assert_file_exists "管理腳本應安裝到 /usr/local/bin" /usr/local/bin/docker-nosystemd
assert_ok "daemon.json 應為合法 JSON(docker info 已驗證配置)" test -s /etc/docker/daemon.json

assert_ok "rc.local 應含自啟標記" grep -q "BEGIN docker-nosystemd autostart" /etc/rc.local
assert_file_exists "profile.d 條目應存在" /etc/profile.d/00-docker-nosystemd.sh

# ── 生命週期驗證 ──
docker-nosystemd status >/dev/null 2>&1
assert_eq "status:運行中應返回 0" "0" "$?"

pid_before="$(cat /var/run/docker-nosystemd.pid)"
docker-nosystemd start --quiet >/dev/null 2>&1
pid_after="$(cat /var/run/docker-nosystemd.pid)"
assert_eq "重複 start 冪等(PID 不變)" "$pid_before" "$pid_after"

docker-nosystemd stop --quiet >/dev/null 2>&1
docker-nosystemd status >/dev/null 2>&1
stop_rc=$?
assert_eq "stop 後 status 應非 0(實際 \$? != 0)" "1" "$stop_rc"

docker-nosystemd start >/dev/null 2>&1
assert_eq "stop 後可重新 start" "0" "$?"
assert_ok "重啟後 docker info 正常" docker info

# ── smoke:真實跑一個容器 ──
echo "== smoke: docker run busybox =="
if docker run --rm busybox true >/dev/null 2>&1; then
    _t_assert; _t_pass
else
    _t_fail "docker run --rm busybox true 失敗"
fi

echo
echo "整合測試結果:run=$_DSND_TESTS_RUN passed=$_DSND_TESTS_PASSED failed=$_DSND_TESTS_FAILED"
if [[ "$_DSND_TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
