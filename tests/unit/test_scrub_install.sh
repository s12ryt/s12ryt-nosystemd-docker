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
            [[ "${args[$i]}" == docker-archive:* ]] && out="${args[$i]#docker-archive:}"
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

# ---------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    for _t in test_scrub_needed_matrix test_install_scrub_tools_deploys \
        test_install_scrub_tools_skips_when_not_needed test_scrub_pull_command \
        test_scrub_pull_requires_bin test_doctor_mentions_scrub; do
        "$_t"
    done
    summary "test_scrub_install.sh"
fi
