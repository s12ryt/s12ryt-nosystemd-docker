#!/usr/bin/env bash
# tests/lib.sh — mini bash 測試框架(零依賴)
# 用法:source 後定義 test_* 函數,由 run-tests.sh 收集執行。

_DSND_TESTS_RUN=0
_DSND_TESTS_PASSED=0
_DSND_TESTS_FAILED=0
_DSND_CURRENT=""

# 內部:記錄斷言(每個 test_* 函數至少計 1 次)
_t_assert() {
  _DSND_TESTS_RUN=$(( _DSND_TESTS_RUN + 1 ))
}

_t_pass() {
  _DSND_TESTS_PASSED=$(( _DSND_TESTS_PASSED + 1 ))
}

_t_fail() {
  _DSND_TESTS_FAILED=$(( _DSND_TESTS_FAILED + 1 ))
  printf '  ✗ [%s] %s\n' "$_DSND_CURRENT" "$1" >&2
}

# 斷言:相等
assert_eq() { # desc expected actual
  local desc="$1" expected="$2" actual="$3"
  _t_assert
  if [[ "$expected" == "$actual" ]]; then
    _t_pass
  else
    _t_fail "$desc — expected: <$(printf '%q' "$expected")> actual: <$(printf '%q' "$actual")>"
  fi
}

# 斷言:字串包含
assert_contains() { # desc needle haystack
  local desc="$1" needle="$2" haystack="$3"
  _t_assert
  if [[ "$haystack" == *"$needle"* ]]; then
    _t_pass
  else
    _t_fail "$desc — <$(printf '%q' "$haystack")> 不包含 <$(printf '%q' "$needle")>"
  fi
}

# 斷言:字串不包含
assert_not_contains() { # desc needle haystack
  local desc="$1" needle="$2" haystack="$3"
  _t_assert
  if [[ "$haystack" != *"$needle"* ]]; then
    _t_pass
  else
    _t_fail "$desc — <$(printf '%q' "$haystack")> 不應包含 <$(printf '%q' "$needle")>"
  fi
}

# 斷言:檔案存在
assert_file_exists() { # desc path
  local desc="$1" path="$2"
  _t_assert
  if [[ -f "$path" ]]; then
    _t_pass
  else
    _t_fail "$desc — 檔案不存在: $path"
  fi
}

# 斷言:命令成功(exit 0)
assert_ok() { # desc cmd...
  local desc="$1"; shift
  _t_assert
  if "$@" >/dev/null 2>&1; then
    _t_pass
  else
    _t_fail "$desc — 命令失敗: $*"
  fi
}

# 斷言:命令失敗(非 0)
assert_fails() { # desc cmd...
  local desc="$1"; shift
  _t_assert
  if "$@" >/dev/null 2>&1; then
    _t_fail "$desc — 命令意外成功: $*"
  else
    _t_pass
  fi
}

# 每個測試文件的臨時目錄(自動清理)
_t_tmpdir=""
t_tmpdir() {
  if [[ -z "$_t_tmpdir" ]]; then
    _t_tmpdir="$(mktemp -d)"
  fi
  printf '%s' "$_t_tmpdir"
}

_t_cleanup() {
  [[ -n "$_t_tmpdir" && -d "$_t_tmpdir" ]] && rm -rf "$_t_tmpdir"
}
trap _t_cleanup EXIT
