#!/bin/bash
# test_scrub_install.sh — scrub 工具整合(scrub_needed / install_scrub_tools / scrub-pull / doctor)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../tests/lib.sh
source "$SCRIPT_DIR/tests/lib.sh"
# shellcheck source=../../src/docker-nosystemd.sh
source "$SCRIPT_DIR/src/docker-nosystemd.sh"

T="$(t_tmpdir)"

_clear_overrides() {
    source "$SCRIPT_DIR/src/docker-nosystemd.sh"
}

# ---------------------------------------------------------------
test_scrub_needed_matrix() {
    _clear_overrides
    userns_wrap_needed() { return 0; }
    probe_userns_range_map_ok() { return 1; }
    assert_ok "單映射環境應需要 scrub" scrub_needed
    probe_userns_range_map_ok() { return 0; }
    assert_fails "範圍映射可用時不應需要 scrub" scrub_needed
    userns_wrap_needed() { return 1; }
    assert_fails "不需包裝時不應需要 scrub" scrub_needed
    _clear_overrides
}

test_install_scrub_tools_deploys() {
    _clear_overrides
    local bindir="$T/bin"
    mkdir -p "$bindir"
    : > "$T/curl.calls"
    : > "$T/apt.calls"
    curl() {
        echo "curl $*" >> "$T/curl.calls"
        local out="" args=("$@")
        local i
        for ((i = 0; i < $#; i++)); do
            [[ "${args[$i]}" == "-o" ]] && out="${args[$((i + 1))]}"
        done
        [[ -n "$out" ]] && printf 'fakeelf' > "$out"
        return 0
    }
    apt-get() { echo "apt-get $*" >> "$T/apt.calls"; return 0; }
    uname() { echo x86_64; }
    DSND_BIN_DIR="$bindir" DSND_SCRUB_URL="https://example.com/dsnd-scrub-test" \
        DSND_SKOPEO_BIN="$T/no-skopeo" \
        install_scrub_tools >/dev/null 2>&1
    assert_file_exists "應下載 dsnd-scrub 二進制" "$bindir/dsnd-scrub"
    assert_contains "URL 應含 amd64 架構" "dsnd-scrub-linux-amd64" "$(cat "$T/curl.calls")"
    assert_contains "應安裝 skopeo" "skopeo" "$(cat "$T/apt.calls")"
    assert_file_exists "應部署 docker wrapper" "$bindir/docker"
    assert_contains "wrapper 應攔截 pull 轉 scrub-pull" "scrub-pull" "$(cat "$bindir/docker")"
    assert_ok "二進制應為可執行" test -x "$bindir/dsnd-scrub"
    _clear_overrides
}

test_install_scrub_tools_skips_when_not_needed() {
    _clear_overrides
    local bindir="$T/bin2"
    mkdir -p "$bindir"
    scrub_needed() { return 1; }
    DSND_BIN_DIR="$bindir" install_scrub_tools >/dev/null 2>&1
    assert_fails "不需 scrub 時不部署" test -e "$bindir/dsnd-scrub"
    assert_fails "不需 scrub 時不部署 wrapper" test -e "$bindir/docker"
    _clear_overrides
}

test_scrub_pull_command() {
    _clear_overrides
    : > "$T/skopeo.calls"
    : > "$T/docker.calls"
    : > "$T/scrub.calls"
    export TMPDIR="$T"
    skopeo() {
        echo "skopeo $*" >> "$T/skopeo.calls"
        local args=("$@") i out=""
        for ((i = 0; i < $#; i++)); do
            if [[ "${args[$i]}" == docker-archive:* ]]; then
                out="${args[$i]#docker-archive:}"
                out="${out%%:*}" # docker-archive:file[:repo[:tag]] — 檔名到第一個冒號
            fi
        done
        [[ -n "$out" ]] && printf 'faketar' > "$out"
        return 0
    }
    local scrubbin="$T/fake-dsnd-scrub"
    printf '#!/bin/bash\necho "dsnd-scrub $*" >> %s/scrub.calls\nprintf x > "$2"\n' "$T" > "$scrubbin"
    chmod +x "$scrubbin"
    docker() { echo "docker $*" >> "$T/docker.calls"; return 0; }
    DSND_SCRUB_BIN="$scrubbin" do_scrub_pull busybox:latest >/dev/null 2>&1
    assert_contains "skopeo 應拉 docker://busybox:latest" "docker://busybox:latest" "$(cat "$T/skopeo.calls")"
    assert_contains "應執行 docker load" "load" "$(cat "$T/docker.calls")"
    assert_contains "應調 dsnd-scrub file" "file" "$(cat "$T/scrub.calls")"
    : > "$T/skopeo.calls"
    DSND_SCRUB_BIN="$scrubbin" do_scrub_pull busybox >/dev/null 2>&1
    assert_contains "無 tag ref 應補 :latest(docker pull 語義)" "docker://busybox:latest" "$(cat "$T/skopeo.calls")"
    assert_contains "docker-archive 應帶 tag 參數(否則 load 後映像無 RepoTags)" ":busybox:latest" "$(cat "$T/skopeo.calls")"
    _clear_overrides
}

test_scrub_pull_requires_bin() {
    _clear_overrides
    assert_fails "scrub 二進制缺失應失敗" env DSND_SCRUB_BIN="$T/nonexistent-scrub" \
        bash -c 'source "'"$SCRIPT_DIR"'/src/docker-nosystemd.sh"; skopeo() { return 0; }; do_scrub_pull foo:latest'
    _clear_overrides
}

test_doctor_mentions_scrub() {
    _clear_overrides
    assert_contains "doctor 應顯示 scrub 狀態" "scrub" \
        "$(DSND_SCRUB_BIN=/nonexistent/dsnd-scrub DSND_SKOPEO_BIN=/nonexistent/skopeo DSND_BIN_DIR="$T/bin3" do_doctor 2>/dev/null)"
    _clear_overrides
}

test_install_scrub_stops_proxy_first() {
    curl() {
        echo "curl $*" >> "$T/curl.calls"
        local _out=""
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == "-o" && -n "${2:-}" ]]; then _out="$2"; shift 2; continue; fi
            shift
        done
        [[ -n "$_out" ]] && printf '#!/bin/sh\n' > "$_out"
        return 0
    }
    apt-get() { echo "apt-get $*" >> "$T/apt.calls"; }
    uname() { echo x86_64; }
    proxy_stop() { touch "$T/proxy-stopped.marker"; }
    export DSND_BIN_DIR="$T/bin"
    export DSND_SCRUB_URL="https://example.com/dsnd-scrub-test"
    export DSND_SKOPEO_BIN="$T/no-skopeo"
    install_scrub_tools >/dev/null 2>&1 || true
    assert_file_exists "install_scrub_tools 應先停 proxy 釋放二進制(防 ETXTBSY)" "$T/proxy-stopped.marker"
    _clear_overrides
    unset DSND_BIN_DIR DSND_SCRUB_URL DSND_SKOPEO_BIN
}

# wrapper 應攔截 docker run/ps 原樣轉發 docker-nosystemd,其餘透傳真 docker
test_wrapper_intercepts_run_and_ps() {
    _clear_overrides
    local W; W="$(t_tmpdir)"
    mkdir -p "$W/dsndbin"
    printf '#!/bin/bash\necho "dsnd $*" >> %s/dsnd.calls\n' "$W" > "$W/dsndbin/docker-nosystemd"
    chmod +x "$W/dsndbin/docker-nosystemd"
    printf '#!/bin/bash\necho "real $*" >> %s/real.calls\n' "$W" > "$W/real-docker"
    chmod +x "$W/real-docker"
    curl() {
        local _out="" a
        for a in "$@"; do
            if [[ -n "${_expect_out:-}" && "$a" == "$_expect_out" ]]; then _out="$a"; fi
        done
        # 掃 -o 參數寫 stub elf
        local args=("$@") i
        for ((i = 0; i < $#; i++)); do
            if [[ "${args[$i]}" == "-o" && -n "${args[$((i + 1))]:-}" ]]; then
                printf '#!/bin/sh\n' > "${args[$((i + 1))]}"
            fi
        done
        return 0
    }
    apt-get() { return 0; }
    uname() { echo x86_64; }
    proxy_stop() { return 0; }
    export DSND_BIN_DIR="$W/bin"
    export DSND_SCRUB_URL="https://example.com/dsnd-scrub-test"
    export DSND_SKOPEO_BIN="$W/no-skopeo"
    install_scrub_tools >/dev/null 2>&1 || true
    # 部署後以運行時變量導向 stub,驗證攔截/透傳(wrapper 運行時讀這些變量)
    export DSND_BIN_DIR="$W/dsndbin"
    export DSND_REAL_DOCKER="$W/real-docker"
    "$W/bin/docker" run -e A=b busybox:latest true >/dev/null 2>&1 || true
    "$W/bin/docker" ps >/dev/null 2>&1 || true
    "$W/bin/docker" version >/dev/null 2>&1 || true
    assert_contains "run 應原樣轉發 docker-nosystemd(含全部選項)" "run -e A=b busybox:latest true" "$(cat "$W/dsnd.calls" 2>/dev/null)"
    assert_contains "ps 應轉發 docker-nosystemd" "ps" "$(cat "$W/dsnd.calls" 2>/dev/null)"
    assert_contains "非攔截命令應透傳真 docker" "real version" "$(cat "$W/real.calls" 2>/dev/null)"
    local _leak
    _leak="$(grep -c '^real run' "$W/real.calls" 2>/dev/null || true)"
    assert_eq "run 不應透傳真 docker" "0" "${_leak:-0}"
    _clear_overrides
    unset DSND_BIN_DIR DSND_SCRUB_URL DSND_SKOPEO_BIN DSND_REAL_DOCKER
}

# ---------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    for _t in test_scrub_needed_matrix test_install_scrub_tools_deploys \
        test_install_scrub_tools_skips_when_not_needed test_scrub_pull_command \
        test_scrub_pull_requires_bin test_doctor_mentions_scrub \
        test_install_scrub_stops_proxy_first test_wrapper_intercepts_run_and_ps; do
        "$_t"
    done
    summary "test_scrub_install.sh"
fi
