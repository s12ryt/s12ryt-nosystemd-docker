#!/usr/bin/env bash
# test_apt_repo.sh — Docker apt 倉庫重複配置檢測單元測試
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/src/docker-nosystemd.sh"

T="$(t_tmpdir)"

test_repo_not_configured_when_empty() {
  mkdir -p "$T/empty-d"
  DSND_APT_SOURCES_DIR="$T/empty-d"
  DSND_APT_SOURCES_LIST="$T/no-main.list"
  if docker_apt_repo_configured; then _t_assert; _t_fail "空配置應判定未配置"; else _t_assert; _t_pass; fi
}

test_repo_configured_by_docker_list() {
  mkdir -p "$T/d1"
  echo 'deb https://download.docker.com/linux/ubuntu noble stable' > "$T/d1/docker.list"
  DSND_APT_SOURCES_DIR="$T/d1"
  DSND_APT_SOURCES_LIST="$T/no-main.list"
  if docker_apt_repo_configured; then _t_assert; _t_pass; else _t_assert; _t_fail "docker.list 存在應判定已配置"; fi
}

test_repo_configured_by_docker_sources_deb822() {
  mkdir -p "$T/d2"
  printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\n' > "$T/d2/docker.sources"
  DSND_APT_SOURCES_DIR="$T/d2"
  DSND_APT_SOURCES_LIST="$T/no-main.list"
  if docker_apt_repo_configured; then _t_assert; _t_pass; else _t_assert; _t_fail "docker.sources(deb822)存在應判定已配置"; fi
}

test_repo_configured_by_main_sources_list() {
  mkdir -p "$T/d3"
  echo 'deb https://download.docker.com/linux/ubuntu noble stable' > "$T/main.list"
  DSND_APT_SOURCES_DIR="$T/d3"
  DSND_APT_SOURCES_LIST="$T/main.list"
  if docker_apt_repo_configured; then _t_assert; _t_pass; else _t_assert; _t_fail "主 sources.list 含 docker.com 應判定已配置"; fi
}

test_repo_configured_by_other_file_in_dir() {
  mkdir -p "$T/d4"
  echo 'deb [signed-by=x] https://download.docker.com/linux/debian trixie stable' > "$T/d4/zz-custom.list"
  DSND_APT_SOURCES_DIR="$T/d4"
  DSND_APT_SOURCES_LIST="$T/no-main.list"
  if docker_apt_repo_configured; then _t_assert; _t_pass; else _t_assert; _t_fail "目錄內其他檔含 download.docker.com 應判定已配置"; fi
}

test_repo_not_configured_by_unrelated() {
  mkdir -p "$T/d5"
  echo 'deb http://archive.ubuntu.com/ubuntu noble main' > "$T/d5/ubuntu.list"
  echo 'deb http://security.ubuntu.com/ubuntu noble-security main' > "$T/main2.list"
  DSND_APT_SOURCES_DIR="$T/d5"
  DSND_APT_SOURCES_LIST="$T/main2.list"
  if docker_apt_repo_configured; then _t_assert; _t_fail "無關倉庫應判定未配置"; else _t_assert; _t_pass; fi
}

test_setup_skips_when_already_configured() {
  mkdir -p "$T/pre" "$T/bin"
  printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\n' > "$T/pre/docker.sources"
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/apt-get"
  chmod +x "$T/bin/apt-get"
  DSND_APT_SOURCES_DIR="$T/pre"
  local rc=0
  ( PATH="$T/bin:$PATH" DSND_APT_SOURCES_DIR="$T/pre" setup_docker_apt_repo ubuntu ) >/dev/null 2>&1 || rc=$?
  assert_eq "已配置時 setup 應成功早退" "0" "$rc"
  if [[ -f "$T/pre/docker.list" ]]; then
    _t_assert; _t_fail "已配置時不應再寫入 docker.list(重複配置)"
  else
    _t_assert; _t_pass
  fi
}
