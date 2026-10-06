#!/bin/bash
# test_scrub_run.sh — docker-nosystemd run(do_scrub_run)單元測試
# docker create → export → chroot 執行;--rm 清理
# shellcheck source=/dev/null
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/tests/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/src/docker-nosystemd.sh"

T="$(t_tmpdir)"

# 恢復函數 override(重新 source 主腳本,定義冪等)
_clear_overrides() {
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/src/docker-nosystemd.sh"
}

# 共用 stub:docker 命令記錄呼叫;chroot 記錄參數
_setup_run_stubs() {
    : > "$T/docker.calls"
    : > "$T/chroot.calls"
    docker() {
        echo "docker $*" >> "$T/docker.calls"
        case "$1" in
            create) echo "fake-cid-123" ;;
            export)
                # 輸出最小合法 tar 流(單檔案),do_scrub_run 的 tar -x 能解開
                mkdir -p "$T/export-src"
                echo stub-content > "$T/export-src/stub.txt"
                tar -c -C "$T/export-src" stub.txt
                ;;
            *) return 0 ;;
        esac
    }
    chroot() {
        echo "chroot $*" >> "$T/chroot.calls"
        return 0
    }
}

test_scrub_run_executes_chroot() {
    _clear_overrides
    _setup_run_stubs
    export DSND_CHROOT_ROOT="$T/chroots"
    do_scrub_run busybox:latest true >/dev/null 2>&1
    assert_contains "應 docker create 映像" "create busybox:latest" "$(cat "$T/docker.calls")"
    assert_contains "應 docker export 容器" "export fake-cid-123" "$(cat "$T/docker.calls")"
    assert_contains "chroot 應指向 rootfs 目錄" "chroot $T/chroots/" "$(cat "$T/chroot.calls")"
    assert_contains "chroot 應執行用戶命令" "true" "$(cat "$T/chroot.calls")"
    unset DSND_CHROOT_ROOT
    _clear_overrides
}

test_scrub_run_rm_cleans_rootfs() {
    _clear_overrides
    _setup_run_stubs
    export DSND_CHROOT_ROOT="$T/chroots2"
    do_scrub_run --rm busybox:latest echo hi >/dev/null 2>&1
    # --rm:執行後 rootfs 目錄應被刪除(目錄樹內容清空)
    local n
    n="$(find "$T/chroots2" -mindepth 1 2>/dev/null | wc -l)"
    assert_eq "--rm 應清空 rootfs 目錄" "0" "$n"
    assert_contains "應清理 docker 容器" "rm fake-cid-123" "$(cat "$T/docker.calls")"
    unset DSND_CHROOT_ROOT
    _clear_overrides
}

test_scrub_run_keeps_rootfs_without_rm() {
    _clear_overrides
    _setup_run_stubs
    export DSND_CHROOT_ROOT="$T/chroots3"
    do_scrub_run busybox:latest echo hi >/dev/null 2>&1
    # 無 --rm:rootfs 內容應保留(fake-tar-content 解開後目錄非空)
    local n
    n="$(find "$T/chroots3" -mindepth 1 2>/dev/null | wc -l)"
    if [[ "$n" -gt 0 ]]; then _t_pass "無 --rm 應保留 rootfs"; else _t_fail "無 --rm 應保留 rootfs(實際為空)"; fi
    unset DSND_CHROOT_ROOT
    _clear_overrides
}

test_scrub_run_missing_image_fails() {
    _clear_overrides
    # docker create 失敗路徑會 die(內含 exit)— 必須在子進程跑,防殺測試 shell
    assert_fails "映像不存在應失敗" bash -c 'source "'"$SCRIPT_DIR"'/src/docker-nosystemd.sh"; docker() { case "$1" in create) return 1 ;; *) return 0 ;; esac; }; DSND_QUIET=1 DSND_CHROOT_ROOT="'"$T"'/chroots4" do_scrub_run no-such-image:latest true'
    _clear_overrides
}

test_scrub_run_env_option() {
    _clear_overrides
    _setup_run_stubs
    chroot() {
        echo "chroot $* FOO=${FOO:-unset}" >> "$T/chroot.calls"
        return 0
    }
    export DSND_CHROOT_ROOT="$T/chroots-env"
    do_scrub_run -e FOO=bar busybox:latest env >/dev/null 2>&1
    assert_contains "-e 應注入環境變數" "FOO=bar" "$(cat "$T/chroot.calls")"
    unset DSND_CHROOT_ROOT FOO
    _clear_overrides
}

test_scrub_run_volume_option() {
    _clear_overrides
    _setup_run_stubs
    mkdir -p "$T/hostdata"
    echo snapshot-content > "$T/hostdata/file.txt"
    export DSND_CHROOT_ROOT="$T/chroots-vol"
    do_scrub_run -v "$T/hostdata:/data" busybox:latest cat /data/file.txt >/dev/null 2>&1
    assert_file_exists "-v 應快照複製 host 檔案到 rootfs" "$T/chroots-vol/busybox_latest/data/file.txt"
    unset DSND_CHROOT_ROOT
    _clear_overrides
}

test_scrub_run_detach() {
    _clear_overrides
    _setup_run_stubs
    export DSND_CHROOT_ROOT="$T/chroots-d"
    export DSND_CHROOT_LOG="$T/detach.log"
    do_scrub_run -d busybox:latest true >/dev/null 2>&1
    local rc=$?
    assert_eq "-d 應立即返回 0" 0 "$rc"
    assert_file_exists "-d 應寫背景日誌" "$T/detach.log"
    unset DSND_CHROOT_ROOT DSND_CHROOT_LOG
    _clear_overrides
}

test_scrub_run_workdir() {
    _clear_overrides
    _setup_run_stubs
    export DSND_CHROOT_ROOT="$T/chroots-w"
    do_scrub_run -w /srv busybox:latest worker >/dev/null 2>&1
    assert_contains "-w 應以 sh -c cd 組裝" 'cd "$0"' "$(cat "$T/chroot.calls")"
    unset DSND_CHROOT_ROOT
    _clear_overrides
}

test_scrub_run_entrypoint() {
    _clear_overrides
    _setup_run_stubs
    export DSND_CHROOT_ROOT="$T/chroots-ep"
    do_scrub_run --entrypoint /bin/echo busybox:latest hi >/dev/null 2>&1
    assert_contains "--entrypoint 應組合為首參數" "/bin/echo hi" "$(cat "$T/chroot.calls")"
    unset DSND_CHROOT_ROOT
    _clear_overrides
}

test_scrub_run_ignores_common_flags() {
    _clear_overrides
    _setup_run_stubs
    export DSND_CHROOT_ROOT="$T/chroots-ign"
    do_scrub_run -it --name mybox -p 8080:80 busybox:latest true >/dev/null 2>&1
    assert_contains "忽略旗標後仍應執行命令" "true" "$(cat "$T/chroot.calls")"
    assert_contains "仍應 create 映像" "create busybox:latest" "$(cat "$T/docker.calls")"
    unset DSND_CHROOT_ROOT
    _clear_overrides
}

test_scrub_run_defaults_to_image_cmd() {
    _clear_overrides
    : > "$T/docker.calls"
    : > "$T/chroot.calls"
    docker() {
        echo "docker $*" >> "$T/docker.calls"
        case "$1" in
            create) echo "fake-cid-123" ;;
            export)
                mkdir -p "$T/export-src"
                echo stub-content > "$T/export-src/stub.txt"
                tar -c -C "$T/export-src" stub.txt
                ;;
            image)
                case "$*" in
                    *Entrypoint*) echo '["/app/server","--mode"]' ;;
                    *Cmd*) echo '["serve"]' ;;
                esac
                ;;
            *) return 0 ;;
        esac
    }
    chroot() {
        echo "chroot $*" >> "$T/chroot.calls"
        return 0
    }
    export DSND_CHROOT_ROOT="$T/chroots9"
    do_scrub_run busybox:latest >/dev/null 2>&1 || true
    assert_contains "無 cmd 應使用映像默認 Entrypoint+Cmd" "/app/server --mode serve" "$(cat "$T/chroot.calls")"
    unset DSND_CHROOT_ROOT
    _clear_overrides
}

test_cr_ps_parses_meta() {
    _clear_overrides
    local T2
    T2="$(t_tmpdir)"
    mkdir -p "$T2/containers/app1"
    cat > "$T2/containers/app1/meta.env" <<EOF
NAME=app1
IMAGE=busybox:latest
PID=$$
CREATED=2026-10-06 00:00:00
LOG=$T2/app1.log
EOF
    local out
    out="$(DSND_CHROOT_ROOT="$T2" dsnd_cr_ps)"
    assert_contains "ps 應顯示容器名(meta 大寫鍵)" "app1" "$out"
    assert_contains "ps 應顯示 Running(活 PID)" "Running" "$out"
    assert_contains "ps 應顯示映像" "busybox:latest" "$out"
    _clear_overrides
}

# ── runner ──
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    for _t in test_scrub_run_executes_chroot test_scrub_run_rm_cleans_rootfs \
        test_scrub_run_keeps_rootfs_without_rm test_scrub_run_missing_image_fails \
        test_scrub_run_env_option test_scrub_run_volume_option test_scrub_run_detach \
        test_scrub_run_workdir test_scrub_run_entrypoint test_scrub_run_ignores_common_flags \
        test_scrub_run_defaults_to_image_cmd test_cr_ps_parses_meta; do
        "$_t"
    done
    summary "test_scrub_run.sh"
fi
