#!/usr/bin/env bash
# install.sh — curl | bash 一鍵安裝入口
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/s12ryt/s12ryt-nosystemd-docker/main/install.sh | sudo bash
#
# 說明:管道模式下 BASH_SOURCE 不是真實檔案,主腳本的自我複製(install_self)
#       無法運作,故此入口先把主腳本下載為暫存檔,再以檔案方式執行。
# 測試鉤子:DSND_ENTRY_URL 覆蓋下載來源(單元測試用 file:// 協議)。

log() { printf '[docker-nosystemd] %s\n' "$*"; }
die() { printf '[docker-nosystemd] ERROR: %s\n' "$*" >&2; exit 1; }

entry_url() {
  printf '%s' "${DSND_ENTRY_URL:-https://raw.githubusercontent.com/s12ryt/s12ryt-nosystemd-docker/main/src/docker-nosystemd.sh}"
}

require_root_entry() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "此安裝器需要 root(用法:curl -fsSL <install.sh 網址> | sudo bash)"
  fi
}

download_main_script() { # dest — 下載主腳本並做基本驗證
  local dest="$1" url
  url="$(entry_url)"
  curl -fsSL "$url" -o "$dest" || die "下載失敗: $url"
  [[ -s "$dest" ]] || die "下載內容為空: $url"
  head -n1 "$dest" | grep -q '^#!.*bash' || die "下載內容不是 bash 腳本(URL 可能錯誤): $url"
}

main() {
  require_root_entry
  if [[ $# -eq 0 ]]; then
    set -- install
  fi
  local tmp rc=0
  tmp="$(mktemp /tmp/docker-nosystemd.XXXXXX.sh)" || die "mktemp 失敗"
  if ! download_main_script "$tmp"; then
    rm -f "$tmp"
    die "無法取得 docker-nosystemd.sh"
  fi
  chmod +x "$tmp"
  log "已取得主腳本,執行: docker-nosystemd $*"
  bash "$tmp" "$@" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
