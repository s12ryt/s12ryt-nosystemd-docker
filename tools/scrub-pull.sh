#!/usr/bin/env bash
# scrub-pull.sh — 無 pull 環境的映像拉取一條龍:
#   skopeo 下載(無 daemon,不解壓層)→ 層 uid/gid 歸零重簽 → docker load
# 適用:單映射 user namespace 模式的 dockerd — docker pull 死於
#   failed to Lchown "..." invalid argument(層內 uid/gid 在映射外)
# 用法:scrub-pull.sh IMAGE_REF
#   例:scrub-pull.sh busybox
#       scrub-pull.sh library/debian:bookworm
# 依賴:skopeo、python3、docker CLI(daemon 運行中)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRUB_PY="$SCRIPT_DIR/docker-scrub.py"

die() { echo "[scrub-pull] 錯誤: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺 $1 — 請先安裝(Debian/Ubuntu: apt-get install -y $1 / Alpine: apk add $1)"; }

usage() {
  cat <<'EOF'
Usage: scrub-pull.sh IMAGE_REF
  例: scrub-pull.sh busybox
      scrub-pull.sh library/debian:bookworm

流程:skopeo copy(無 daemon 下載)→ docker-scrub.py(層 uid/gid 歸零 + 重簽)
     → docker load。產出映像內所有檔案為 root:root。
依賴:skopeo、python3、docker CLI(daemon 運行中)。
EOF
  exit "${1:-0}"
}

[[ $# -ge 1 ]] || usage 2
REF="$1"
[[ "$REF" == "-h" || "$REF" == "--help" ]] && usage 0

need skopeo
need python3
command -v docker >/dev/null 2>&1 || die "缺 docker CLI"
docker info >/dev/null 2>&1 || die "docker daemon 未運行(先執行 docker-nosystemd start)"
[[ -f "$SCRUB_PY" ]] || die "找不到 $SCRUB_PY(需與本腳本同目錄部署)"

TMP="$(mktemp /tmp/scrub-pull.XXXXXX)"
CLEAN="$TMP.clean"
trap 'rm -f "$TMP" "$CLEAN"' EXIT

echo "[scrub-pull] 1/3 skopeo 拉取 $REF ..."
skopeo copy "docker://$REF" "docker-archive:$TMP" \
  || die "skopeo 拉取失敗(檢查 ref 拼寫 / 網路 / 私有倉庫需 --registry-login 參數自行擴展)"

echo "[scrub-pull] 2/3 清洗層 uid/gid → 0:0 並重簽 ..."
python3 "$SCRUB_PY" "$TMP" "$CLEAN" || die "清洗失敗"

echo "[scrub-pull] 3/3 docker load ..."
docker load -i "$CLEAN" || die "docker load 失敗(可用 docker-nosystemd logs 查看原因)"

echo "[scrub-pull] 完成:$REF 已載入(映像內所有檔案 root:root,權限敏感應用請自行評估)"
