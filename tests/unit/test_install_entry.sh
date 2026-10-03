#!/usr/bin/env bash
# test_install_entry.sh — curl | bash 一鍵安裝入口(install.sh)單元測試
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/install.sh"

T="$(t_tmpdir)"
SRC_URL="file://$SCRIPT_DIR/src/docker-nosystemd.sh"

test_entry_default_url() {
  unset DSND_ENTRY_URL || true
  assert_eq "默認 URL 指向官方 raw main 分支" \
    "https://raw.githubusercontent.com/s12ryt/s12ryt-nosystemd-docker/main/src/docker-nosystemd.sh" \
    "$(entry_url)"
}

test_entry_url_override() {
  DSND_ENTRY_URL="file:///tmp/custom-dsnd.sh"
  assert_eq "DSND_ENTRY_URL 可覆蓋(測試鉤子)" "file:///tmp/custom-dsnd.sh" "$(entry_url)"
  unset DSND_ENTRY_URL
}

test_download_main_script_ok() {
  DSND_ENTRY_URL="$SRC_URL"
  local dst="$T/main.sh"
  local rc=0
  ( download_main_script "$dst" ) >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then _t_assert; _t_pass; else _t_assert; _t_fail "file:// 下載主腳本應成功(rc=$rc)"; fi
  assert_file_exists "下載產物存在" "$dst"
  assert_contains "下載內容非空且含 shebang" "#!/usr/bin/env bash" "$(head -n1 "$dst")"
  unset DSND_ENTRY_URL
}

test_download_missing_fails() {
  DSND_ENTRY_URL="file:///nonexistent-dsnd-path/main.sh"
  local rc=0
  ( download_main_script "$T/bad.sh" ) >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then _t_assert; _t_pass; else _t_assert; _t_fail "下載 404 應失敗"; fi
  unset DSND_ENTRY_URL
}

test_download_empty_fails() {
  : > "$T/empty.sh"
  DSND_ENTRY_URL="file://$T/empty.sh"
  local rc=0
  ( download_main_script "$T/empty-out.sh" ) >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then _t_assert; _t_pass; else _t_assert; _t_fail "空文件應拒絕"; fi
  unset DSND_ENTRY_URL
}

test_download_not_script_fails() {
  printf 'just plain text\n' > "$T/plain.txt"
  DSND_ENTRY_URL="file://$T/plain.txt"
  local rc=0
  ( download_main_script "$T/plain-out.sh" ) >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then _t_assert; _t_pass; else _t_assert; _t_fail "非 bash 腳本內容應拒絕"; fi
  unset DSND_ENTRY_URL
}

_make_fake_main() { # capfile -> echo fake script path
  local cap="$1"
  local fake="$T/fake-main-$RANDOM.sh"
  {
    echo '#!/usr/bin/env bash'
    printf 'printf "%%s\\n" "$@" > %q\n' "$cap"
  } > "$fake"
  printf '%s' "$fake"
}

test_main_defaults_to_install() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "  (非 root,跳過 main 預設參數斷言)" >&2
    _t_assert; _t_pass
    return
  fi
  local cap="$T/args-default.txt"
  DSND_ENTRY_URL="file://$(_make_fake_main "$cap")"
  local rc=0
  ( main ) >/dev/null 2>&1 || rc=$?
  assert_eq "main 執行假腳本應成功" "0" "$rc"
  assert_contains "無參數時默認執行 install" "install" "$(cat "$cap" 2>/dev/null)"
  unset DSND_ENTRY_URL
}

test_main_forwards_args() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "  (非 root,跳過 main 參數透傳斷言)" >&2
    _t_assert; _t_pass
    return
  fi
  local cap="$T/args-forward.txt"
  DSND_ENTRY_URL="file://$(_make_fake_main "$cap")"
  local rc=0
  ( main status --foo bar ) >/dev/null 2>&1 || rc=$?
  assert_eq "main status 透傳應成功" "0" "$rc"
  local out
  out="$(cat "$cap" 2>/dev/null)"
  assert_contains "參數透傳 status" "status" "$out"
  assert_contains "參數透傳 --foo" "--foo" "$out"
  assert_contains "參數透傳 bar" "bar" "$out"
  unset DSND_ENTRY_URL
}

test_main_cleans_tmpfile() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "  (非 root,跳過 main 清理斷言)" >&2
    _t_assert; _t_pass
    return
  fi
  local cap="$T/args-clean.txt"
  DSND_ENTRY_URL="file://$(_make_fake_main "$cap")"
  local before after
  before="$(find /tmp -maxdepth 1 -name 'docker-nosystemd.*.sh' 2>/dev/null | sort)"
  ( main ) >/dev/null 2>&1
  after="$(find /tmp -maxdepth 1 -name 'docker-nosystemd.*.sh' 2>/dev/null | sort)"
  assert_eq "main 執行後不留暫存檔" "$before" "$after"
  unset DSND_ENTRY_URL
}
