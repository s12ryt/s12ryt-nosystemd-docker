#!/usr/bin/env bash
# =============================================================================
# docker-nosystemd — 在沒有 systemd 的環境(容器 VPS / DinD)安裝並管理 Docker
#
# 支援:Debian / Ubuntu(官方 docker-ce 倉庫,失敗回退 docker.io)
#       Alpine(apk:docker + docker-cli-compose)
#
# 特性:
#   - 無 systemd 時以 nohup 背景啟動 dockerd(pidfile + 日誌檔)
#   - daemon.json 依環境自動生成,iptables/bridge 不可用時自動降級
#     (full → noiptables → none),storage overlay2 失敗回退 vfs
#   - 冪等自啟動配置:/etc/rc.local + /etc/profile.d/
#   - 有 systemd 的機器自動退回 systemctl enable --now docker
#
# 用法:
#   sudo ./docker-nosystemd.sh install          # 一鍵安裝 + 配置 + 啟動
#   sudo docker-nosystemd start|stop|restart    # 生命週期管理(冪等)
#   docker-nosystemd status|logs|doctor         # 狀態 / 日誌 / 診斷
# =============================================================================

set -u

# ── 可覆蓋配置(測試與特殊環境鉤子)──────────────────────────────────────
# DSND_PID_FILE      pidfile 路徑            (默認 /var/run/docker-nosystemd.pid)
# DSND_LOG_FILE      dockerd 日誌路徑         (默認 /var/log/docker-nosystemd.log)
# DSND_DOCKERD_BIN   dockerd 可執行檔        (默認 dockerd,走 PATH)
# DSND_READY_PROBE   就緒探測命令            (默認 docker info)
# DSND_READY_TIMEOUT 就緒等待秒數            (默認 30)
# DSND_CONF_FILE     daemon.json 路徑         (默認 /etc/docker/daemon.json)
# DSND_RC_LOCAL      rc.local 路徑            (默認 /etc/rc.local)
# DSND_PROFILE_DIR   profile.d 目錄           (默認 /etc/profile.d)
# DSND_BIN_PATH      自身安裝目標             (默認 /usr/local/bin/docker-nosystemd)
# DSND_OS_RELEASE    替代 os-release 檔(測試)
# DSND_INIT_PROBE_ROOT / DSND_FORCE_NO_SYSTEMD(測試 init 偵測)
# DSND_FORCE_NET_MODE   full|noiptables|none(強制網路模式,跳過探測)
# DSND_FORCE_STORAGE    overlay2|vfs(強制存儲驅動)
# DSND_PROC_STATUS      /proc/self/status 替代路徑(測試用)
# DSND_USERNS_MAP_SIZE  userns 恆等映射寬度(默認 65536;映射由子 ns 內寫 /proc/self)
# DSND_USERNS_MODE      dockerd 啟動包裝:auto(默認)| never | force(unshare -Ur)
# DSND_FORCE_INSTALL   =1 強制重裝(即使 dockerd 已存在)
# DSND_INSTALL_SCRUB   =1 強制部署映像清洗工具鏈(默認僅單映射 pull 會死環境自動部署)
# DSND_SCRUB_URL       dsnd-scrub 二進制下載基底 URL(GitHub Release)
# DSND_BIN_DIR         工具部署目錄(默認 /usr/local/bin)
# DSND_PROXY_PORT      本地 scrub proxy 埠(默認 5200;設定後 daemon.json 注入 registry-mirrors)
# DSND_PROXY_PID_FILE  scrub proxy pidfile(默認 /var/run/dsnd-scrub-proxy.pid)
# DSND_PROXY_LOG_FILE  scrub proxy 日誌(默認 /var/log/dsnd-scrub-proxy.log)
# DSND_SKOPEO_BIN      scrub-pull 用 skopeo 命令(默認 skopeo)
# DSND_DOCKER_BIN      scrub-pull 用 docker 命令(默認 docker)

AUTOSTART_BEGIN="# BEGIN docker-nosystemd autostart"
AUTOSTART_END="# END docker-nosystemd autostart"
DSND_NET_MODE_RESULT=""
DSND_STORAGE_RESULT=""

log() { printf '[docker-nosystemd] %s\n' "$*"; }
warn() { printf '[docker-nosystemd] 警告: %s\n' "$*" >&2; }
die() { printf '[docker-nosystemd] 錯誤: %s\n' "$*" >&2; exit 1; }

# ═══════════════════════════ 偵測 ═══════════════════════════

# 輸出 debian|ubuntu|alpine;不支援時輸出 unsupported 並返回 1
detect_distro() {
    local os_release="${DSND_OS_RELEASE:-/etc/os-release}"
    if [[ ! -f "$os_release" ]]; then
        echo "unsupported"
        return 1
    fi
    local id id_like like
    id="$(grep -E '^ID=' "$os_release" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' || true)"
    id_like="$(grep -E '^ID_LIKE=' "$os_release" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' || true)"
    case "$id" in
        debian | ubuntu | alpine) echo "$id"; return 0 ;;
    esac
    for like in $id_like; do
        case "$like" in
            debian) echo "debian"; return 0 ;;
            ubuntu) echo "ubuntu"; return 0 ;;
        esac
    done
    echo "unsupported"
    return 1
}

# 輸出 systemd|none
detect_init() {
    if [[ -n "${DSND_FORCE_NO_SYSTEMD:-}" ]]; then
        echo "none"
        return 0
    fi
    local root="${DSND_INIT_PROBE_ROOT:-}"
    if [[ -d "$root/run/systemd/system" ]]; then
        echo "systemd"
        return 0
    fi
    local pid1
    pid1="$(tr -d '[:space:]' < /proc/1/comm 2>/dev/null || true)"
    if [[ "$pid1" == "systemd" ]]; then
        echo "systemd"
        return 0
    fi
    echo "none"
    return 0
}

# ═════════════════════ daemon.json 生成 ═════════════════════

# build_daemon_json <iptables_ok:0|1> <bridge_ok:0|1> <storage_driver>
# 規則:bridge=0 時連帶 iptables=0(bridge none 下 iptables 管理無意義)
build_daemon_json() {
    local iptables_ok="$1" bridge_ok="$2" storage="$3"
    local nl=$'\n'
    local out='{'"$nl"
    out+="  \"storage-driver\": \"$storage\",$nl"
    if [[ "$bridge_ok" != "1" ]]; then
        iptables_ok=0
    fi
    if [[ "$iptables_ok" != "1" ]]; then
        out+="  \"iptables\": false,$nl"
        out+="  \"ip-masq\": false,$nl"
    fi
    if [[ "$bridge_ok" != "1" ]]; then
        out+="  \"bridge\": \"none\",$nl"
    fi
    out+="  \"log-driver\": \"json-file\",$nl"
    out+="  \"log-opts\": {$nl"
    out+="    \"max-size\": \"10m\",$nl"
    out+="    \"max-file\": \"3\"$nl"
    local proxy_port="${DSND_PROXY_PORT:-}"
    if [[ -n "$proxy_port" ]]; then
        out+="  },$nl"
        out+="  \"registry-mirrors\": [\"http://127.0.0.1:${proxy_port}\"],$nl"
        out+="  \"insecure-registries\": [\"127.0.0.1:${proxy_port}\"]$nl"
    else
        out+="  }$nl"
    fi
    out+='}'
    printf '%s\n' "$out"
}

# 將 daemon.json 寫入 DSND_CONF_FILE(首次會備份原檔)
write_daemon_config() { # iptables_ok bridge_ok storage
    local file="${DSND_CONF_FILE:-/etc/docker/daemon.json}"
    mkdir -p "$(dirname "$file")"
    if [[ -f "$file" && ! -f "$file.bak.nosystemd" ]]; then
        cp "$file" "$file.bak.nosystemd" || warn "無法備份原有 $file"
    fi
    build_daemon_json "$1" "$2" "$3" > "$file"
}

# 分析 dockerd 日誌,返回 storage|net|unknown 供降級決策
analyze_log_hint() {
    local logfile="${DSND_LOG_FILE:-/var/log/docker-nosystemd.log}"
    [[ -f "$logfile" ]] || { echo "unknown"; return 0; }
    if grep -qiE 'overlay|storage-driver|error creating.*graph' "$logfile" 2>/dev/null; then
        echo "storage"
        return 0
    fi
    if grep -qiE 'iptables|firewalld|nat |bridge|address already in use|network' "$logfile" 2>/dev/null; then
        echo "net"
        return 0
    fi
    echo "unknown"
}

# 失敗時輸出 daemon 日誌尾部(省去手動找日誌),走 stderr 與錯誤訊息一致
dump_log_tail() { # [lines]
    local lines="${1:-20}"
    local logfile="${DSND_LOG_FILE:-/var/log/docker-nosystemd.log}"
    [[ -f "$logfile" ]] || return 0
    printf '── dockerd 日誌(最後 %s 行,完整日誌:%s)──\n' "$lines" "$logfile" >&2
    tail -n "$lines" "$logfile" >&2
}

# ═════════════════════ 環境探測 ═════════════════════

probe_iptables_ok() {
    command -v iptables >/dev/null 2>&1 || return 1
    iptables -t nat -L -n >/dev/null 2>&1
}

probe_bridge_ok() {
    command -v ip >/dev/null 2>&1 || return 1
    ip link add dsndprobe0 type bridge >/dev/null 2>&1 || return 1
    ip link del dsndprobe0 >/dev/null 2>&1 || true
    return 0
}

# cgroup 掛載檢測(無特權容器缺 cgroup 時 dockerd 無法啟動)
probe_cgroup() {
    local mounts="${DSND_PROC_MOUNTS:-/proc/mounts}"
    [[ -f "$mounts" ]] || return 1
    grep -q ' cgroup2\? ' "$mounts" 2>/dev/null
}

# 輸出 v2|v1|none(v2 優先判定)
cgroup_flavor() {
    local mounts="${DSND_PROC_MOUNTS:-/proc/mounts}"
    if [[ -f "$mounts" ]]; then
        grep -q ' cgroup2 ' "$mounts" 2>/dev/null && { echo "v2"; return 0; }
        grep -q ' cgroup ' "$mounts" 2>/dev/null && { echo "v1"; return 0; }
    fi
    echo "none"
}

# 核心是否支援 overlay 檔案系統(不支援則只能用 vfs)
probe_overlay_fs() {
    local fsfiles="${DSND_PROC_FILESYSTEMS:-/proc/filesystems}"
    [[ -f "$fsfiles" ]] || return 1
    grep -qw overlay "$fsfiles" 2>/dev/null
}

# overlay 實際掛載實測:無特權容器核心支援(/proc/filesystems 有 overlay)但掛載會 EPERM,
# 只有實測才能分辨;探測用臨時目錄,結束即清理
probe_overlay_mount_ok() {
    local d
    d="$(mktemp -d 2>/dev/null)" || return 1
    mkdir -p "$d/l" "$d/w" "$d/u" "$d/m" 2>/dev/null || { rm -rf "$d"; return 1; }
    if ! mount -t overlay dsndprobe -o "lowerdir=$d/l,upperdir=$d/w,workdir=$d/u" "$d/m" >/dev/null 2>&1; then
        rm -rf "$d"
        return 1
    fi
    umount "$d/m" >/dev/null 2>&1 || true
    rm -rf "$d"
    return 0
}

# unshare(CLONE_NEWNS) 探測:Docker 註冊映像層(chrootarchive 解壓安全隔離)必需,
# 需要 CAP_SYS_ADMIN;無特權容器被拒 → docker pull/load 報
# "failed to register layer: unshare: operation not permitted"
probe_unshare_mount_ok() {
    command -v unshare >/dev/null 2>&1 || return 1
    unshare -m true >/dev/null 2>&1
}

# unprivileged user namespace 探測(rootless 運行模式的必要條件)
probe_unshare_userns_ok() {
    command -v unshare >/dev/null 2>&1 || return 1
    unshare -U true >/dev/null 2>&1
}

# 對指定進程寫入 user namespace 恆等範圍映射(uid/gid 0..N-1 → 0..N-1)。
# 範圍映射 user namespace 探測(內部寫法):由子進程在新 user namespace 內
# 直接寫 /proc/self/{setgroups,uid_map,gid_map} — 繞過父進程寫 /proc/$pid/*
# 的 ptrace 權限檢查(無特權容器常剝 CAP_SYS_PTRACE 導致外部寫法 EACCES)。
# 成功 = 容器內 root 具備寫 uid_map/gid_map 的權限(CAP_SETUID/CAP_SETGID),
# docker pull 解壓層的 lchown(任意 uid/gid)全落在 0-65535 恆等映射內 → 不再 EINVAL。
# 失敗時將具體原因記錄到全局變量 _DSND_RANGE_FAIL_REASON 供上游輸出。
# DSND_USERNS_MAP_SIZE:映射寬度(默認 65536)
# 註:內部腳本重定向採「2>/dev/null > file」順序 — 先導 stderr 再開檔,
# open 失敗的 shell 錯誤才會被吞掉,僅以非零退出碼傳遞失敗原因。
# 退出碼約定:10 = uid_map 寫入失敗;11 = gid_map 寫入失敗;其他 = ns 建立失敗。
probe_userns_range_map_ok() {
    command -v unshare >/dev/null 2>&1 || { _DSND_RANGE_FAIL_REASON="unshare 命令不可用"; return 1; }
    _DSND_RANGE_FAIL_REASON=""
    local rc=0
    # shellcheck disable=SC2016  # $1 需在子 ns 的 bash 內展開
    unshare --user bash -c '
        echo deny 2>/dev/null > /proc/self/setgroups || true
        printf "0 0 %s\n" "$1" 2>/dev/null > /proc/self/uid_map || exit 10
        printf "0 0 %s\n" "$1" 2>/dev/null > /proc/self/gid_map || exit 11
        exit 0
    ' _ "${DSND_USERNS_MAP_SIZE:-65536}" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) return 0 ;;
        10) _DSND_RANGE_FAIL_REASON="uid_map 寫入被拒(需 CAP_SETUID)" ;;
        11) _DSND_RANGE_FAIL_REASON="gid_map 寫入被拒(需 CAP_SETGID,且需先成功 deny setgroups)" ;;
        *) _DSND_RANGE_FAIL_REASON="user namespace 建立失敗(rc=$rc)" ;;
    esac
    return 1
}

# 是否需要以 user namespace 包裝模式啟動 dockerd(unshare -Ur)。
# 原理:unshare(CLONE_NEWNS) 檢查「當前 user namespace 內」的 CAP_SYS_ADMIN;
# 無特權容器直接調用 EPERM,但若核心允許 unprivileged userns,把 dockerd 包進
# unshare -Ur 後在新 userns 內即擁有全部 caps → 映像層註冊的 unshare/mount 放行
# (rootless Docker 同原理)。返回 0 = 需要包裝。
# DSND_USERNS_MODE:auto(默認:直接 unshare -m 可行→不包;不可行且 userns 可行→包)
#                   / never(禁用)/ force(只要 userns 可行就包)
userns_wrap_needed() {
    local mode="${DSND_USERNS_MODE:-auto}"
    [[ "$mode" == "never" ]] && return 1
    if [[ "$mode" == "force" ]]; then
        probe_unshare_userns_ok
        return
    fi
    probe_unshare_mount_ok && return 1
    probe_unshare_userns_ok
}

# 讀 /proc/self/status 指定欄位值(如 Seccomp / CapEff);檔案或欄位不存在返回 1
proc_status_field() { # <欄位名> 例:Seccomp
    local f="${DSND_PROC_STATUS:-/proc/self/status}"
    [[ -f "$f" ]] || return 1
    awk -v k="$1:" '$1 == k { print $2; found = 1; exit } END { exit found ? 0 : 1 }' "$f" 2>/dev/null
}

netmode_iptables() { case "$1" in full) echo 1 ;; *) echo 0 ;; esac; }
netmode_bridge() { case "$1" in full | noiptables) echo 1 ;; *) echo 0 ;; esac; }
next_net_mode() {
    case "$1" in
        full) echo "noiptables" ;;
        noiptables) echo "none" ;;
        *) echo "none" ;;
    esac
}

# ═════════════════════ dockerd 生命週期 ═════════════════════

is_running() {
    local pidfile="${DSND_PID_FILE:-/var/run/docker-nosystemd.pid}"
    [[ -f "$pidfile" ]] || return 1
    local pid
    pid="$(cat "$pidfile" 2>/dev/null)" || return 1
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

wait_daemon_ready() {
    local timeout="${DSND_READY_TIMEOUT:-30}"
    local probe="${DSND_READY_PROBE:-docker info}"
    local waited=0
    while ((waited < timeout)); do
        if bash -c "$probe" >/dev/null 2>&1 && is_running; then
            return 0
        fi
        is_running || return 1 # 進程已死,提前失敗
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

# 以範圍映射 user namespace 啟動 dockerd(內部寫法):
#   unshare --user 起的 bash 在新 ns 內直接寫 /proc/self/{setgroups,uid_map,gid_map}
#   (0..65535 恆等映射),成功後 exec dockerd → pid 全程不變。
#   內部寫 /proc/self 繞過父進程寫 /proc/$pid 的 ptrace 權限檢查
#   (無特權容器常剝 CAP_SYS_PTRACE);映射後 ns 內 root 對映射內任意
#   uid/gid 的 chown/lchown 全放行,docker pull 解壓層不再 EINVAL
#   (如 /home 的 nobody:nogroup 65534、/etc/shadow 的 gid 42)。
# 回顯 pid 供呼叫方寫入 pidfile(exec 鏈 pid 不變,kill/收養語義一致)。
launch_dockerd_userns_range() { # <dockerdbin> <logfile>
    local dockerdbin="$1" logfile="$2"
    # shellcheck disable=SC2016  # $1/$@ 需在子 ns 的 bash 內展開
    nohup unshare --user bash -c '
        echo deny 2>/dev/null > /proc/self/setgroups || true
        printf "0 0 %s\n" "$1" 2>/dev/null > /proc/self/uid_map || { echo "[dsnd] uid_map 寫入失敗,即將退出" >&2; exit 90; }
        printf "0 0 %s\n" "$1" 2>/dev/null > /proc/self/gid_map || { echo "[dsnd] gid_map 寫入失敗,即將退出" >&2; exit 91; }
        exec "$@"' _ "${DSND_USERNS_MAP_SIZE:-65536}" "$dockerdbin" >> "$logfile" 2>&1 &
    echo "$!"
}

do_start() {
    local pidfile="${DSND_PID_FILE:-/var/run/docker-nosystemd.pid}"
    local logfile="${DSND_LOG_FILE:-/var/log/docker-nosystemd.log}"
    local dockerdbin="${DSND_DOCKERD_BIN:-dockerd}"
    local dpidfile="${DSND_DOCKERD_DEFAULT_PIDFILE:-/var/run/docker.pid}"
    if is_running; then
        [[ -z "${DSND_QUIET:-}" ]] && log "dockerd 已在運行 (PID $(cat "$pidfile"))"
        return 0
    fi
    mkdir -p "$(dirname "$pidfile")" "$(dirname "$logfile")"
    # 處理 dockerd 默認 pidfile(/var/run/docker.pid)殘留:
    #   - 指向活進程(如 systemd 啟動的 dockerd)→ 收養,避免啟動衝突
    #   - 指向死進程 → 刪除殘留,否則 dockerd 拒絕啟動
    if [[ -f "$dpidfile" ]]; then
        local dpid
        dpid="$(cat "$dpidfile" 2>/dev/null)" || dpid=""
        if [[ -n "$dpid" ]] && kill -0 "$dpid" 2>/dev/null; then
            echo "$dpid" > "$pidfile"
            if wait_daemon_ready; then
                [[ -z "${DSND_QUIET:-}" ]] && log "已收養運行中的 dockerd (PID $dpid)"
                return 0
            fi
            rm -f "$pidfile" # 收養失敗(未就緒/非 dockerd),回退正常啟動
        else
            rm -f "$dpidfile"
        fi
    fi
    rm -f "$pidfile"
    local pid
    if userns_wrap_needed; then
        if probe_userns_range_map_ok; then
            [[ -z "${DSND_QUIET:-}" ]] && log "以 user namespace 範圍映射模式啟動 dockerd(0-65535 恆等映射):層內任意 uid/gid chown 均在映射內"
            pid="$(launch_dockerd_userns_range "$dockerdbin" "$logfile")"
        else
            [[ -z "${DSND_QUIET:-}" ]] && log "以 user namespace 單映射包裝模式啟動 dockerd(unshare -Ur -G root):docker pull 對映射外 gid 檔案仍會 EINVAL(範圍映射不可用:${_DSND_RANGE_FAIL_REASON:-原因未知})"
            # -G root:socket group 設為 gid 0(userns 映射內);默認 docker group 的 gid
            # 不在 unshare -Ur 的單一 gid 映射內,chown docker.sock 會 EINVAL
            nohup unshare -Ur "$dockerdbin" -G root >> "$logfile" 2>&1 &
            pid=$!
        fi
    else
        nohup "$dockerdbin" >> "$logfile" 2>&1 &
        pid=$!
    fi
    echo "$pid" > "$pidfile"
    if wait_daemon_ready; then
        [[ -z "${DSND_QUIET:-}" ]] && log "dockerd 已啟動 (PID $pid)"
        if [[ -x "${DSND_SCRUB_BIN:-${DSND_BIN_DIR:-/usr/local/bin}/dsnd-scrub}" ]] && scrub_needed; then
            if proxy_start; then
                [[ -z "${DSND_QUIET:-}" ]] && log "scrub proxy 已啟動(docker pull 將自動清洗)"
            fi
        fi
        return 0
    fi
    if is_running; then
        warn "dockerd 進程存活但未就緒(超時 ${DSND_READY_TIMEOUT:-30}s),請檢查 $logfile"
    else
        warn "dockerd 進程已退出,請檢查 $logfile"
    fi
    return 1
}

do_stop() {
    proxy_stop
    local pidfile="${DSND_PID_FILE:-/var/run/docker-nosystemd.pid}"
    if [[ ! -f "$pidfile" ]]; then
        return 0
    fi
    local pid
    pid="$(cat "$pidfile" 2>/dev/null)" || { rm -f "$pidfile"; return 0; }
    if [[ -z "$pid" ]]; then
        rm -f "$pidfile"
        return 0
    fi
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        local i=0
        while kill -0 "$pid" 2>/dev/null && ((i < 30)); do
            sleep 0.5
            i=$((i + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    rm -f "$pidfile"
    [[ -z "${DSND_QUIET:-}" ]] && log "dockerd 已停止"
    return 0
}

do_restart() {
    do_stop
    sleep 1
    do_start
}

do_status() {
    local pidfile="${DSND_PID_FILE:-/var/run/docker-nosystemd.pid}"
    if is_running; then
        log "dockerd 運行中 (PID $(cat "$pidfile"))"
        return 0
    fi
    log "dockerd 未運行"
    return 1
}

do_logs() {
    local logfile="${DSND_LOG_FILE:-/var/log/docker-nosystemd.log}"
    local lines=50 follow=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f | --follow) follow="-f" ;;
            *[0-9]*) lines="$1" ;;
        esac
        shift
    done
    [[ -f "$logfile" ]] || die "日誌不存在:$logfile(dockerd 尚未啟動過?)"
    # shellcheck disable=SC2086
    tail -n "$lines" $follow "$logfile"
}

# ═════════════════════ 自啟動注入 ═════════════════════

render_autostart_snippet() {
    local bin="${DSND_BIN_NAME:-docker-nosystemd}"
    printf '%s\n' \
        "$AUTOSTART_BEGIN" \
        "if command -v $bin >/dev/null 2>&1; then" \
        "  $bin start --quiet >/dev/null 2>&1 || true" \
        "fi" \
        "$AUTOSTART_END"
}

inject_autostart() {
    local rc_local="${DSND_RC_LOCAL:-/etc/rc.local}"
    local profile_dir="${DSND_PROFILE_DIR:-/etc/profile.d}"
    local profile_file="$profile_dir/00-docker-nosystemd.sh"

    # 1) profile.d(登入 shell 觸發)
    mkdir -p "$profile_dir"
    if [[ ! -f "$profile_file" ]] || ! grep -qF "$AUTOSTART_BEGIN" "$profile_file" 2>/dev/null; then
        {
            echo '#!/bin/sh'
            echo '# docker-nosystemd autostart(登入時確保 daemon 運行)'
            render_autostart_snippet
        } > "$profile_file"
    fi

    # 2) rc.local(若有初始化系統會執行它)
    if [[ -f "$rc_local" ]] && grep -qF "$AUTOSTART_BEGIN" "$rc_local" 2>/dev/null; then
        :
    else
        local snippet
        snippet="$(render_autostart_snippet)"
        if [[ ! -f "$rc_local" ]]; then
            {
                echo '#!/bin/sh'
                echo "$snippet"
                echo 'exit 0'
            } > "$rc_local"
        elif grep -q '^exit 0' "$rc_local"; then
            # 插入到第一個 exit 0 之前
            local tmp
            tmp="$(mktemp)"
            awk -v snippet="$snippet" '/^exit 0/ && !done { print snippet; done = 1 } { print }' \
                "$rc_local" > "$tmp"
            mv "$tmp" "$rc_local"
        else
            printf '%s\n' "$snippet" >> "$rc_local"
        fi
    fi
    chmod +x "$rc_local" 2>/dev/null || true
    return 0
}

# ═════════════════════ 安裝 ═════════════════════

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        warn "此命令需要 root 權限,請加 sudo 執行"
        return 1
    fi
    return 0
}

# 偵測 Docker apt 倉庫是否已配置(docker.list / docker.sources / 任何含
# download.docker.com 的來源)— 避免重複配置造成 apt 警告
docker_apt_repo_configured() {
    local dir="${DSND_APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
    local main_list="${DSND_APT_SOURCES_LIST:-/etc/apt/sources.list}"
    if [[ -f "$dir/docker.list" || -f "$dir/docker.sources" ]]; then
        return 0
    fi
    grep -rh 'download\.docker\.com' "$main_list" "$dir" 2>/dev/null | grep -q .
}

setup_docker_apt_repo() { # distro(debian|ubuntu)
    local distro="$1" codename
    local sources_dir="${DSND_APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
    if docker_apt_repo_configured; then
        log "偵測到既有 Docker apt 倉庫配置,跳過重複添加"
        apt-get update -y >/dev/null 2>&1 || true
        return 0
    fi
    # shellcheck disable=SC1091
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    [[ -n "$codename" ]] || return 1
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y ca-certificates curl >/dev/null 2>&1 || return 1
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$distro/gpg" -o /etc/apt/keyrings/docker.asc || return 1
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$distro $codename stable" \
        > "$sources_dir/docker.list"
    apt-get update -y || return 1
}

install_docker_apt() { # distro
    local distro="$1"
    if command -v dockerd >/dev/null 2>&1 && [[ -z "${DSND_FORCE_INSTALL:-}" ]]; then
        log "dockerd 已安裝,跳過 engine 安裝"
        return 0
    fi
    export DEBIAN_FRONTEND=noninteractive
    log "配置 Docker 官方 apt 倉庫($distro)…"
    if setup_docker_apt_repo "$distro"; then
        log "安裝 docker-ce + compose plugin…"
        if apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
            return 0
        fi
        warn "官方倉庫套件安裝失敗,回退發行版套件"
    else
        warn "官方倉庫不可用,改用發行版套件"
    fi
    apt-get install -y docker.io docker-compose-v2 \
        || apt-get install -y docker.io docker-compose \
        || apt-get install -y docker.io
}

install_docker_alpine() {
    if command -v dockerd >/dev/null 2>&1 && [[ -z "${DSND_FORCE_INSTALL:-}" ]]; then
        log "dockerd 已安裝,跳過 engine 安裝"
        return 0
    fi
    log "apk 安裝 docker + compose…"
    apk add --no-cache docker docker-cli-compose
}

ensure_compose() { # distro
    if docker compose version >/dev/null 2>&1; then
        return 0
    fi
    local distro="$1"
    log "補裝 Docker Compose v2…"
    if [[ "$distro" == "alpine" ]]; then
        apk add --no-cache docker-cli-compose >/dev/null 2>&1 || true
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y docker-compose-v2 >/dev/null 2>&1 \
            || apt-get install -y docker-compose-plugin >/dev/null 2>&1 \
            || true
    fi
    if docker compose version >/dev/null 2>&1; then
        return 0
    fi
    warn "docker compose 不可用(容器建議顯式安裝)"
    return 1
}

install_self() {
    local target="${DSND_BIN_PATH:-/usr/local/bin/docker-nosystemd}"
    local src="${BASH_SOURCE[0]}"
    mkdir -p "$(dirname "$target")"
    if [[ "$src" == "$target" ]] || cmp -s "$src" "$target" 2>/dev/null; then
        return 0
    fi
    cp "$src" "$target"
    chmod +x "$target"
}

# 是否為「docker pull 會死」的環境:dockerd 需要 userns 包裝(缺 CAP_SYS_ADMIN)
# 且範圍映射不可用(層內映射外 uid/gid 會 Lchown EINVAL)— 此時 scrub 流程是唯一解。
scrub_needed() {
    userns_wrap_needed && ! probe_userns_range_map_ok
}

# ── 本地 scrub proxy 生命週期(docker pull 透明清洗)──
# dsnd-scrub proxy 在 127.0.0.1:DSND_PROXY_PORT 提供 pull-through registry,
# 層 uid/gid 歸零重簽後回供;daemon.json registry-mirrors 指向它。
# 鉤子:DSND_PROXY_PID_FILE / DSND_PROXY_LOG_FILE / DSND_SCRUB_BIN。
proxy_pidfile() {
    echo "${DSND_PROXY_PID_FILE:-/var/run/dsnd-scrub-proxy.pid}"
}

proxy_running() {
    local pf
    pf="$(proxy_pidfile)"
    [[ -f "$pf" ]] || return 1
    local pid
    pid="$(cat "$pf" 2>/dev/null)" || return 1
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

proxy_start() {
    local scrubbin="${DSND_SCRUB_BIN:-${DSND_BIN_DIR:-/usr/local/bin}/dsnd-scrub}"
    [[ -x "$scrubbin" ]] || return 1
    proxy_running && return 0
    local pf logfile
    pf="$(proxy_pidfile)"
    logfile="${DSND_PROXY_LOG_FILE:-/var/log/dsnd-scrub-proxy.log}"
    DSND_PROXY_ADDR="${DSND_PROXY_ADDR:-127.0.0.1:${DSND_PROXY_PORT:-5200}}" \
        nohup "$scrubbin" proxy >> "$logfile" 2>&1 &
    echo "$!" > "$pf"
    return 0
}

proxy_stop() {
    local pf pid i
    pf="$(proxy_pidfile)"
    [[ -f "$pf" ]] || return 0
    pid="$(cat "$pf" 2>/dev/null)" || { rm -f "$pf"; return 0; }
    [[ -z "$pid" ]] && { rm -f "$pf"; return 0; }
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        for i in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    rm -f "$pf"
    return 0
}

# 部署映像清洗工具(僅 scrub 環境;DSND_INSTALL_SCRUB=1 強制):
#   1. dsnd-scrub 靜態二進制(GitHub Release 下載,鉤子 DSND_SCRUB_URL 覆蓋基底 URL)
#   2. skopeo(apt/apk,無 daemon 的映像下載器)
#   3. /usr/local/bin/docker 包裝:攔 `docker pull REF` 轉發 scrub-pull,其餘原樣透傳
# 任何一步失敗僅 warn 不 die(scrub 是增益功能)。
install_scrub_tools() {
    if [[ "${DSND_INSTALL_SCRUB:-0}" != "1" ]] && ! scrub_needed; then
        return 0
    fi
    # 先冪等停舊 scrub proxy,釋放其佔用的 dsnd-scrub 二進制 —
    # 否則 curl 下載覆蓋執行中的二進制會 ETXTBSY(curl: (23) write 失敗)。
    # (do_install 中本函數在 provision/do_stop 之前執行,舊 proxy 此時仍在運行)
    proxy_stop || true
    local bindir="${DSND_BIN_DIR:-/usr/local/bin}"
    local arch
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64 | arm64) arch="arm64" ;;
        *) warn "dsnd-scrub 未支援此架構($(uname -m)),跳過 scrub 工具部署"; return 1 ;;
    esac
    local base_url="${DSND_SCRUB_URL:-https://github.com/s12ryt/s12ryt-nosystemd-docker/releases/download/v1.1.2-scrub}"
    local scrubbin="${DSND_SCRUB_BIN:-$bindir/dsnd-scrub}"
    mkdir -p "$bindir"
    if curl -fsSL -o "$scrubbin" "$base_url/dsnd-scrub-linux-$arch"; then
        chmod +x "$scrubbin"
        log "dsnd-scrub 二進制已部署:$scrubbin"
    else
        rm -f "$scrubbin"
        warn "dsnd-scrub 下載失敗($base_url/dsnd-scrub-linux-$arch);可用 DSND_SCRUB_URL 覆蓋或手動部署"
        return 1
    fi
    if ! command -v "${DSND_SKOPEO_BIN:-skopeo}" >/dev/null 2>&1; then
        log "安裝 skopeo(無 daemon 映像下載器)…"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -y -qq skopeo >/dev/null 2>&1 || warn "skopeo 安裝失敗(apt);scrub-pull 將不可用"
        elif command -v apk >/dev/null 2>&1; then
            apk add --quiet skopeo >/dev/null 2>&1 || warn "skopeo 安裝失敗(apk);scrub-pull 將不可用"
        else
            warn "找不到套件管理器安裝 skopeo;scrub-pull 將不可用"
        fi
    fi
    # docker 包裝:攔 pull/run/ps/rm/stop/logs 轉發 chroot 容器體系;
    # 本腳本內部以絕對路徑 /usr/bin/docker 呼叫避免遞迴
    cat > "$bindir/docker" <<'WRAPPER'
#!/bin/sh
# BEGIN docker-nosystemd pull interceptor
# 攔 `docker pull REF`(轉發映像清洗)與 run/ps/rm/stop/logs(轉發 chroot
# 容器體系);其餘命令原樣透傳真實 docker CLI。路徑可由環境變量覆蓋。
REAL=${DSND_REAL_DOCKER:-/usr/bin/docker}
DSND=${DSND_BIN_DIR:-/usr/local/bin}/docker-nosystemd
SCRUB=${DSND_SCRUB_BIN:-/usr/local/bin/dsnd-scrub}
[ -x "$DSND" ] || exec "$REAL" "$@"
case "$1" in
    pull)
        if [ -n "$2" ] && [ -z "$3" ] && [ -x "$SCRUB" ] \
            && command -v skopeo >/dev/null 2>&1; then
            exec "$DSND" scrub-pull "$2"
        fi
        ;;
    run|ps|rm)
        exec "$DSND" "$@"
        ;;
    stop)
        # 帶容器名 = chroot 容器;無參(dockerd 操作)透傳
        if [ -n "$2" ]; then
            exec "$DSND" "$@"
        fi
        ;;
    logs)
        # 帶非 -f/數字參數 = chroot 容器日誌;否則透傳(dockerd 日誌)
        if [ -n "$2" ] && [ "$2" != "-f" ] && [ "$2" != "--follow" ]; then
            case "$2" in
                *[!0-9]*) exec "$DSND" "$@" ;;
            esac
        fi
        ;;
esac
exec "$REAL" "$@"
# END docker-nosystemd pull interceptor
WRAPPER
    chmod +x "$bindir/docker"
    log "docker 包裝已部署:$bindir/docker(pull 清洗轉發;run/ps/rm/stop/logs 轉發 chroot 容器體系)"
    log "注意:docker compose 內建的自動 pull 不經包裝;compose 環境請先 docker pull 各映像再 up"
}

# scrub-pull:skopeo 下載(不解壓)→ dsnd-scrub 歸零重簽 → docker load
# 鉤子:DSND_SKOPEO_BIN / DSND_SCRUB_BIN / DSND_DOCKER_BIN(默認 docker)
do_scrub_pull() {
    local ref="${1:?用法:docker-nosystemd scrub-pull <image>[:tag]}"
    # 補全 tag(docker pull busybox 等同 busybox:latest):ref 不帶 tag 時
    # skopeo docker-archive 產出的 manifest.json RepoTags 為空 → docker load
    # 後映像無 tag(僅 Loaded image ID),docker run <ref> 找不到本地映像
    # 又觸發原生 pull 反而失敗。basename(最後 / 後)不含 : 且非 @digest 才補。
    local _base="${ref##*/}"
    if [[ "$_base" != *:* && "$ref" != *@* ]]; then
        ref="${ref}:latest"
    fi
    local scrubbin="${DSND_SCRUB_BIN:-/usr/local/bin/dsnd-scrub}"
    local skopeobin="${DSND_SKOPEO_BIN:-skopeo}"
    local dockerbin="${DSND_DOCKER_BIN:-docker}"
    [[ -x "$scrubbin" ]] || die "dsnd-scrub 不存在($scrubbin);請重新執行 install 或手動部署"
    command -v "$skopeobin" >/dev/null 2>&1 || die "skopeo 不可用;請安裝(apt-get install -y skopeo)"
    local tmp_raw tmp_clean
    tmp_raw="$(mktemp "${TMPDIR:-/tmp}/dsnd-pull-raw.XXXXXX.tar")"
    tmp_clean="$(mktemp "${TMPDIR:-/tmp}/dsnd-pull-clean.XXXXXX.tar")"
    # shellcheck disable=SC2064 # trap 展開此刻的變量
    trap "rm -f '$tmp_raw' '$tmp_clean'" RETURN
    log "下載映像(不經 dockerd):$ref"
    # docker-archive:file:repo:tag — 第三段 tag 讓 skopeo 把 RepoTags 寫進
    # manifest.json(load 後映像帶 tag);@digest 引用無 tag 可寫,保持無 tag
    local _dst="docker-archive:$tmp_raw"
    [[ "$ref" != *@* ]] && _dst="$_dst:$ref"
    "$skopeobin" copy "docker://$ref" "$_dst" || die "skopeo 下載失敗:$ref"
    log "清洗層 uid/gid → 0:0 並重簽 digest 鏈…"
    "$scrubbin" file "$tmp_raw" "$tmp_clean" || die "dsnd-scrub 清洗失敗"
    log "匯入本機 dockerd…"
    "$dockerbin" load -i "$tmp_clean" || die "docker load 失敗(映像:$ref)"
    log "完成:$ref 已以清洗後形式載入(屬主全為 root:root)"
}

# 解析 JSON 字串陣列(["a","b"])為逐行輸出(供 mapfile);空/null 輸出空。
# 簡化解析:僅適用映像 Entrypoint/Cmd 這類簡單詞元素(無內嵌逗號/引號)。
_dsnd_json_arr_to_args() {
    local s="${1:-}"
    s="${s#\[}"
    s="${s%\]}"
    [[ -z "$s" || "$s" == "null" ]] && return 0
    local part
    local IFS=','
    for part in $s; do
        part="${part#\"}"
        part="${part%\"}"
        part="${part//\\\"/\"}"
        printf '%s\n' "$part"
    done
    return 0
}

# scrub-run:docker create → export 解出 → chroot 執行(「窮人容器」)
# 適用:沙箱連 OCI runtime rootless 都焊死(cgroup ro + mount seccomp)、
# 但 chroot 可用的環境(如 K8s unprivileged pod)。無 ns/cgroup 隔離,
# 無 /proc — busybox/腳本/靜態服務可用;讀 /proc 的複雜應用不行。
# 支援 docker run 常用選項:-d/-e/--name/-v(快照複製)/-w/--entrypoint/--rm;
# -i/-t/--network/--user/-p 等語義上無意義或天然成立者靜默忽略。
# 鉤子:DSND_DOCKER_BIN / DSND_CHROOT_ROOT(默認 /var/lib/dsnd-chroot)/ DSND_CHROOT_LOG
do_scrub_run() {
    local rm_flag=0 detach=0 workdir="" entrypoint="" name=""
    local -a envs=() vols=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rm) rm_flag=1; shift ;;
            -d|--detach) detach=1; shift ;;
            -i|-t|-it|--interactive|--tty) shift ;; # stdio 已繼承
            -e|--env) [[ $# -ge 2 ]] || die "-e 缺少值"; envs+=("$2"); shift 2 ;;
            -e=*|--env=*) envs+=("${1#*=}"); shift ;;
            --name) [[ $# -ge 2 ]] || die "--name 缺少值"; name="$2"; shift 2 ;;
            --name=*) name="${1#*=}"; shift ;;
            -v|--volume) [[ $# -ge 2 ]] || die "-v 缺少值"; vols+=("$2"); shift 2 ;;
            -v=*|--volume=*) vols+=("${1#*=}"); shift ;;
            -p|--publish) shift 2 ;; -p=*|--publish=*) shift ;;
            -w|--workdir) [[ $# -ge 2 ]] || die "-w 缺少值"; workdir="$2"; shift 2 ;;
            -w=*|--workdir=*) workdir="${1#*=}"; shift ;;
            --entrypoint) [[ $# -ge 2 ]] || die "--entrypoint 缺少值"; entrypoint="$2"; shift 2 ;;
            --entrypoint=*) entrypoint="${1#*=}"; shift ;;
            -u|--user|--network|--net|--restart|-m|--memory|--cpus|--hostname|-h)
                shift 2 ;;
            --user=*|--network=*|--net=*|--restart=*|--memory=*|--cpus=*|--hostname=*)
                shift ;;
            -*) warn "run:忽略不支援的選項:$1"; shift ;;
            *) break ;;
        esac
    done
    local image="${1:?用法:docker-nosystemd run [docker-run 選項] <image> [cmd [args...]]}"
    shift
    local -a cmd=()
    [[ $# -gt 0 ]] && cmd=("$@")
    local dockerbin="${DSND_DOCKER_BIN:-docker}"
    # docker 語義:未指定命令時用映像默認 ENTRYPOINT+CMD(docker image inspect)
    local -a img_ep=() img_cmd=()
    if [[ ${#cmd[@]} -eq 0 || -z "$entrypoint" ]]; then
        local _j
        _j="$("$dockerbin" image inspect --format '{{json .Config.Entrypoint}}' "$image" 2>/dev/null || true)"
        mapfile -t img_ep < <(_dsnd_json_arr_to_args "$_j")
        _j="$("$dockerbin" image inspect --format '{{json .Config.Cmd}}' "$image" 2>/dev/null || true)"
        mapfile -t img_cmd < <(_dsnd_json_arr_to_args "$_j")
    fi
    if [[ -n "$entrypoint" ]]; then
        # --entrypoint 覆寫:entrypoint + (用戶 cmd 或映像 CMD)
        [[ ${#cmd[@]} -eq 0 ]] && cmd=("${img_cmd[@]}")
        cmd=("$entrypoint" "${cmd[@]}")
    elif [[ ${#cmd[@]} -eq 0 ]]; then
        cmd=("${img_ep[@]}" "${img_cmd[@]}")
    elif [[ ${#img_ep[@]} -gt 0 ]]; then
        # 用戶命令作為映像 ENTRYPOINT 的參數(docker 語義)
        cmd=("${img_ep[@]}" "${cmd[@]}")
    fi
    [[ ${#cmd[@]} -gt 0 ]] || die "未指定要執行的命令,且映像無默認 CMD(用法:docker-nosystemd run [選項] <image> [cmd...])"
    local base="${DSND_CHROOT_ROOT:-/var/lib/dsnd-chroot}"
    local cid
    cid="$("$dockerbin" create "$image" 2>/dev/null)" || die "docker create 失敗(映像存在嗎?$image)"
    local safe="${image//\//_}"
    safe="${safe//:/_}"
    local rootfs="$base/$safe"
    rm -rf "$rootfs"
    mkdir -p "$rootfs"
    if ! "$dockerbin" export "$cid" | tar -x -C "$rootfs"; then
        "$dockerbin" rm "$cid" >/dev/null 2>&1 || true
        rm -rf "$rootfs"
        die "docker export/解出失敗(映像:$image)"
    fi
    "$dockerbin" rm "$cid" >/dev/null 2>&1 || true
    # -v 快照複製(chroot 無法共享掛載:單向副本,容器內修改不回寫)
    local vol hpath cpath
    for vol in "${vols[@]}"; do
        hpath="${vol%%:*}"; cpath="${vol#*:}"
        if [[ -z "$hpath" || -z "$cpath" || "$cpath" != /* ]]; then
            warn "忽略無效 -v:$vol(格式 HOST:CONT,CONT 需絕對路徑)"
            continue
        fi
        if [[ -e "$hpath" ]]; then
            mkdir -p "$rootfs$cpath"
            cp -a "$hpath"/. "$rootfs$cpath"/ 2>/dev/null || warn "-v 快照複製失敗:$vol"
            log "-v $vol:已快照複製(單向副本)"
        else
            mkdir -p "$hpath" "$rootfs$cpath"
            log "-v $vol:宿主路徑不存在,已建立空目錄"
        fi
    done
    # -e 環境變量(chroot exec 繼承)
    local kv
    for kv in "${envs[@]}"; do
        export "${kv:?}"
    done
    # 容器註冊(-d 持久容器供 ps/stop/rm/logs 管理;前台跑完即清)
    local crdir=""
    if [[ $detach -eq 1 ]]; then
        [[ -z "$name" ]] && name="dsnd-$(date +%s)-$RANDOM"
        crdir="$base/containers/$name"
        mkdir -p "$crdir"
    fi
    # 命令組裝(-w 以內層 sh -c cd;entrypoint 已併入 cmd)
    local -a exec_cmd=("${cmd[@]}")
    if [[ -n "$workdir" ]]; then
        # shellcheck disable=SC2016  # $0/$@ 需在 rootfs 內的 sh 展開
        exec_cmd=(/bin/sh -c 'cd "$0" >/dev/null 2>&1 || exit 1; exec "$@"' "$workdir" "${cmd[@]}")
    fi
    local rc=0
    if [[ $detach -eq 1 ]]; then
        local logfile="${DSND_CHROOT_LOG:-/var/log/dsnd-chroot.log}"
        nohup chroot "$rootfs" "${exec_cmd[@]}" >> "$logfile" 2>&1 &
        local bgpid=$!
        {
            echo "NAME=$name"
            echo "IMAGE=$image"
            echo "PID=$bgpid"
            echo "CREATED=$(date '+%Y-%m-%d %H:%M:%S')"
            echo "LOG=$logfile"
        } > "$crdir/meta.env"
        if [[ $rm_flag -eq 1 ]]; then
            warn "--rm 與 -d 併用:rootfs 與容器記錄保留(後台進程退出後不自動清理,請以 rm 子命令清理)"
        fi
        log "後台執行:$name(PID $bgpid);日誌:$logfile"
        return 0
    fi
    log "以 chroot 執行(rootfs:$rootfs):${cmd[*]}"
    chroot "$rootfs" "${exec_cmd[@]}"
    rc=$?
    if [[ $rm_flag -eq 1 ]]; then
        rm -rf "$rootfs"
        log "--rm 已清理 rootfs"
    else
        log "rootfs 保留於 $rootfs(重跑同映像更快;--rm 可自動清理)"
    fi
    return $rc
}

# ── chroot 容器管理兼容層(docker ps/stop/rm/logs 對應)──
# 容器記錄:$DSND_CHROOT_ROOT/containers/<name>/{meta.env,}
_dsnd_cr_meta() { # <name> — 輸出 meta 檔路徑
    local base="${DSND_CHROOT_ROOT:-/var/lib/dsnd-chroot}"
    echo "$base/containers/$1/meta.env"
}

dsnd_cr_ps() {
    local base="${DSND_CHROOT_ROOT:-/var/lib/dsnd-chroot}"
    local d name pid img created status
    printf '%-24s %-28s %-8s %-10s %s\n' NAME IMAGE PID STATUS CREATED
    for d in "$base"/containers/*/; do
        [[ -f "$d/meta.env" ]] || continue
        name=""; pid=""; img=""; created=""
        # shellcheck disable=SC1090
        # shellcheck disable=SC1091  # 動態路徑的 meta 狀態檔
        . "$d/meta.env" 2>/dev/null || true
        status="Exited"
        if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
            status="Running"
        fi
        printf '%-24s %-28s %-8s %-10s %s\n' "${name:-?}" "${img:-?}" "${pid:--}" "$status" "${created:-?}"
        # 防迭代污染:清掉本輪變量
        name=""; pid=""; img=""; created=""
    done
    return 0
}

dsnd_cr_stop() { # <name>
    local meta
    meta="$(_dsnd_cr_meta "${1:?用法:docker-nosystemd stop <容器名>}")"
    [[ -f "$meta" ]] || die "找不到容器:$1(以 docker-nosystemd ps 查看)"
    local pid=""
    # shellcheck disable=SC1090
    . "$meta" 2>/dev/null || true
    pid="${PID:-}"
    [[ -n "$pid" ]] || die "容器 $1 無 PID 記錄(非 -d 容器?)"
    if ! kill -0 "$pid" 2>/dev/null; then
        log "容器 $1 已不在運行(PID $pid)"
        return 0
    fi
    kill "$pid" 2>/dev/null || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    log "容器 $1 已停止(PID $pid)"
    return 0
}

dsnd_cr_rm() { # <name>
    local base="${DSND_CHROOT_ROOT:-/var/lib/dsnd-chroot}"
    local name="${1:?用法:docker-nosystemd rm <容器名>}"
    local crdir="$base/containers/$name"
    [[ -f "$crdir/meta.env" ]] || die "找不到容器:$name(以 docker-nosystemd ps 查看)"
    local pid=""
    # shellcheck disable=SC1090
    # shellcheck disable=SC1091  # 動態路徑的 meta 狀態檔
    . "$crdir/meta.env" 2>/dev/null || true
    pid="${PID:-}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -rf "$crdir"
    log "容器 $name 已刪除(rootfs 映像快取不受影響)"
    return 0
}

dsnd_cr_logs() { # <name> [lines]
    local meta
    meta="$(_dsnd_cr_meta "${1:?用法:docker-nosystemd logs <容器名> [行數]}")"
    [[ -f "$meta" ]] || die "找不到容器:$1(以 docker-nosystemd ps 查看)"
    local logfile="" pid=""
    # shellcheck disable=SC1090
    . "$meta" 2>/dev/null || true
    logfile="${LOG:-}"
    [[ -n "$logfile" && -f "$logfile" ]] || die "容器 $1 無日誌檔($logfile)"
    local n="${2:-50}"
    tail -n "$n" -- "$logfile"
    return 0
}

# 探測 + 生成 daemon.json + 啟動,失敗自動降級重試
provision_with_fallback() {
    local net="${DSND_FORCE_NET_MODE:-}"
    if [[ -z "$net" ]]; then
        if probe_iptables_ok && probe_bridge_ok; then
            net="full"
        elif probe_bridge_ok; then
            net="noiptables"
        else
            net="none"
        fi
    fi
    # 起始存儲驅動:核心支援 + 實測掛載成功才用 overlay2;
    # 無特權容器掛載會 EPERM,直接以 vfs 起始省一輪失敗(DSND_FORCE_STORAGE 可覆蓋)
    local storage="${DSND_FORCE_STORAGE:-}"
    if [[ -z "$storage" ]]; then
        if probe_overlay_fs && probe_overlay_mount_ok; then
            storage="overlay2"
        else
            storage="vfs"
            warn "overlay 不可用(核心不支援或無掛載權限),存儲驅動直接使用 vfs"
        fi
    fi
    local attempt=0
    local prev_net prev_storage
    while ((attempt < 4)); do
        log "嘗試啟動 dockerd(網路模式:$net / 存儲:$storage)"
        write_daemon_config "$(netmode_iptables "$net")" "$(netmode_bridge "$net")" "$storage"
        do_stop >/dev/null 2>&1 || true
        rm -f "${DSND_LOG_FILE:-/var/log/docker-nosystemd.log}"
        if DSND_READY_TIMEOUT="${DSND_INSTALL_READY_TIMEOUT:-20}" do_start; then
            DSND_NET_MODE_RESULT="$net"
            DSND_STORAGE_RESULT="$storage"
            [[ "$net" != "full" ]] && warn "已降級網路模式:$net(端口映射不可用;Cloudflare Tunnel 不受影響)"
            [[ "$storage" == "vfs" ]] && warn "存儲驅動降級為 vfs(效能較低,但相容性最好)"
            # dockerd 起來 ≠ 可用:映像層註冊需要 unshare(CLONE_NEWNS);
            # 無 CAP_SYS_ADMIN 的容器會在 pull/load 時才爆 EPERM,提前點破
            if ! probe_unshare_mount_ok; then
                if userns_wrap_needed; then
                    if probe_userns_range_map_ok; then
                        log "dockerd 以 user namespace 範圍映射模式運行:層內任意 uid/gid chown 均在映射內,docker pull 可正常註冊映像層"
                    else
                        log "dockerd 以 user namespace 單映射模式運行:映像層註冊的 unshare 將放行,但 tar 內映射外 gid 檔案(如 /etc/shadow,gid 42)chown 仍會 EINVAL(範圍映射不可用:${_DSND_RANGE_FAIL_REASON:-原因未知})"
                        warn "docker pull 可能部分失敗(lchown: invalid argument);宿主以特權模式運行容器可徹底解決"
                    fi
                else
                    warn "unshare(CLONE_NEWNS)不可用:dockerd 已啟動,但拉取/載入映像會失敗"
                    warn "(failed to register layer: unshare: operation not permitted)。此容器缺少 CAP_SYS_ADMIN,需要宿主以特權模式運行容器才能完整使用 Docker"
                fi
            fi
            return 0
        fi
        # 記住本輪剛嘗試過的組合,再計算降級目標
        prev_net="$net"
        prev_storage="$storage"
        local hint
        hint="$(analyze_log_hint)"
        case "$hint" in
            storage) storage="vfs" ;;
            *) net="$(next_net_mode "$net")" ;;
        esac
        # 只有「降級前後組合不變」= 本輪已是 none/vfs 且剛試過,才允許放棄;
        # 直接檢查新組合會導致 vfs 輪從未執行(無特權容器 net 起始即 none 時必現)
        if [[ "$net" == "$prev_net" && "$storage" == "$prev_storage" ]]; then
            break
        fi
        attempt=$((attempt + 1))
    done
    if ! probe_cgroup; then
        warn "偵測到 cgroup 未掛載:無特權容器通常無法運行 dockerd(需宿主提供 cgroup 掛載或特權模式)"
    fi
    dump_log_tail 25
    die "dockerd 在所有降級組合下均啟動失敗,請執行 docker-nosystemd doctor 診斷"
}

do_install() {
    local distro init
    distro="$(detect_distro)" || die "不支援的發行版(僅支援 Debian/Ubuntu/Alpine)"
    init="$(detect_init)"
    log "偵測結果:發行版=$distro / init=$init"

    # 1) 安裝 engine + compose
    if [[ "$distro" == "alpine" ]]; then
        install_docker_alpine || die "apk 安裝 docker 失敗"
    else
        install_docker_apt "$distro" || die "apt 安裝 docker 失敗"
    fi
    command -v dockerd >/dev/null 2>&1 || die "dockerd 安裝後仍不存在"
    ensure_compose "$distro" || true

    # 2) 安裝管理腳本自身
    install_self || warn "無法複製自身到 ${DSND_BIN_PATH:-/usr/local/bin/docker-nosystemd}"

    # 3) 啟動 + 自啟配置
    if [[ "$init" == "systemd" ]]; then
        log "檢測到 systemd,使用 systemctl 啟用…"
        if systemctl enable --now docker >/dev/null 2>&1; then
            print_summary "$distro" "systemd"
            return 0
        fi
        warn "systemctl 啟用失敗,改用無 systemd 手動模式"
    fi
    # 單映射(pull 會死)環境:先部署映像清洗工具鏈(dsnd-scrub + skopeo + docker 包裝),
    # 並啟動本地 scrub proxy + 注入 registry-mirrors — 讓 docker pull 透明走清洗
    install_scrub_tools || true
    local scrubbin="${DSND_SCRUB_BIN:-${DSND_BIN_DIR:-/usr/local/bin}/dsnd-scrub}"
    if [[ -x "$scrubbin" ]] && scrub_needed; then
        export DSND_PROXY_PORT="${DSND_PROXY_PORT:-5200}"
        proxy_start || true
    fi
    provision_with_fallback
    inject_autostart
    print_summary "$distro" "rc.local+profile.d"
}

print_summary() { # distro autostart_method
    local distro="$1" method="$2"
    local dver cver
    dver="$(docker -v 2>/dev/null || echo '未知')"
    cver="$(docker compose version 2>/dev/null || echo '未安裝')"
    printf '\n'
    printf '═════════ 安裝摘要 ═════════\n'
    printf '  發行版      : %s\n' "$distro"
    printf '  Docker     : %s\n' "$dver"
    printf '  Compose    : %s\n' "$cver"
    printf '  daemon 狀態: %s\n' "$(is_running && echo '運行中' || echo '未運行')"
    printf '  網路模式   : %s\n' "${DSND_NET_MODE_RESULT:-N/A}"
    printf '  存儲驅動   : %s\n' "${DSND_STORAGE_RESULT:-N/A}"
    printf '  自啟配置   : %s\n' "$method"
    printf '  配置檔     : %s\n' "${DSND_CONF_FILE:-/etc/docker/daemon.json}"
    printf '  日誌       : %s\n' "${DSND_LOG_FILE:-/var/log/docker-nosystemd.log}"
    printf '════════════════════════════\n'
}

# ═════════════════════ 診斷 ═════════════════════

do_doctor() {
    local distro="?" init="?" rc=0
    distro="$(detect_distro 2>/dev/null)" || { distro="unsupported"; rc=1; }
    init="$(detect_init)"
    printf '── docker-nosystemd 環境診斷 ──\n'
    printf '發行版        : %s\n' "$distro"
    printf 'init 系統     : %s\n' "$init"
    printf '當前用戶      : %s(uid=%s)\n' "$(id -un)" "$(id -u)"
    printf 'dockerd       : %s\n' "$(command -v dockerd || echo '未安裝')"
    printf 'docker CLI    : %s\n' "$(command -v docker || echo '未安裝')"
    if command -v docker >/dev/null 2>&1; then
        printf 'docker compose: %s\n' "$(docker compose version 2>/dev/null || echo '不可用')"
    fi
    printf 'iptables 可用 : %s\n' "$(probe_iptables_ok && echo '是' || echo '否(將降級 iptables=false)')"
    printf 'bridge 可用   : %s\n' "$(probe_bridge_ok && echo '是' || echo '否(將降級 bridge=none)')"
    local cg
    cg="$(cgroup_flavor)"
    case "$cg" in
        v2) printf 'cgroup 掛載   : 是(v2 unified)\n' ;;
        v1) printf 'cgroup 掛載   : 是(v1)\n' ;;
        *) printf 'cgroup 掛載   : 否(無特權容器將無法運行 dockerd)\n' ;;
    esac
    printf 'overlay 支援  : %s\n' "$(probe_overlay_fs && echo '是' || echo '否(將使用 vfs)')"
    printf 'overlay 掛載實測: %s\n' "$(probe_overlay_mount_ok && echo '是' || echo '否(核心支援但掛載被拒,將使用 vfs;常見於無特權容器)')"
    local sec cap sec_desc cap_desc
    sec="$(proc_status_field Seccomp || true)"
    case "$sec" in
        0) sec_desc="0(禁用)" ;;
        1) sec_desc="1(strict)" ;;
        2) sec_desc="2(過濾模式,系統調用可能受限)" ;;
        *) sec_desc="未知" ;;
    esac
    cap="$(proc_status_field CapEff || true)"
    if [[ "$cap" =~ ^0+$ ]]; then
        cap_desc="${cap:-未知}(無任何 capability)"
    else
        cap_desc="${cap:-未知}"
    fi
    printf 'unshare 掛載ns: %s\n' "$(probe_unshare_mount_ok && echo '是' || echo '否(缺 CAP_SYS_ADMIN:映像層註冊將失敗,需宿主開特權)')"
    printf 'user namespace: %s\n' "$(probe_unshare_userns_ok && echo '是' || echo '否(rootless 模式不可用)')"
    printf 'userns 包裝模式: %s\n' "$(userns_wrap_needed && echo '將啟用(dockerd 包進 unshare -Ur,繞過映像層註冊 EPERM)' || echo '未啟用')"
local _range_ok=0
probe_userns_range_map_ok && _range_ok=1
if [[ "$_range_ok" == 1 ]]; then
    printf 'userns 範圍映射: 可用(0-65535 恆等映射,層內任意 chown 放行)\n'
else
    printf 'userns 範圍映射: 不可用(%s;pull 對映射外 gid 檔案會 EINVAL)\n' "${_DSND_RANGE_FAIL_REASON:-原因未知}"
fi
local _scrub_bin="${DSND_SCRUB_BIN:-${DSND_BIN_DIR:-/usr/local/bin}/dsnd-scrub}"
local _scrub_desc
if [[ -x "$_scrub_bin" ]]; then
    _scrub_desc="已部署($_scrub_bin"
    if command -v "${DSND_SKOPEO_BIN:-skopeo}" >/dev/null 2>&1; then
        _scrub_desc+=" + skopeo"
    else
        _scrub_desc+="，但 skopeo 缺失"
    fi
    [[ -x "${DSND_BIN_DIR:-/usr/local/bin}/docker" ]] && _scrub_desc+="；docker pull 已自動轉發"
    _scrub_desc+=")"
elif scrub_needed; then
    _scrub_desc="未部署(此環境 docker pull 會 Lchown EINVAL；重新執行 install 可自動部署)"
else
    _scrub_desc="未部署(非單映射環境，無需)"
fi
printf 'scrub 工具     : %s\n' "$_scrub_desc"
local _proxy_desc
if [[ -x "$_scrub_bin" ]]; then
    if proxy_running; then
        _proxy_desc="運行中(PID $(cat "$(proxy_pidfile)" 2>/dev/null),埠 ${DSND_PROXY_PORT:-5200})"
    else
        _proxy_desc="未運行(start 將自動啟動)"
    fi
elif scrub_needed; then
    _proxy_desc="未部署(此環境 pull 會 EINVAL,重跑 install 可自動部署)"
else
    _proxy_desc="未部署(非單映射無需)"
fi
printf 'scrub proxy    : %s\n' "$_proxy_desc"
    printf 'Seccomp       : %s\n' "$sec_desc"
    printf 'CapEff        : %s\n' "$cap_desc"
    printf 'daemon 狀態   : %s\n' "$(is_running && echo "運行中(PID $(cat "${DSND_PID_FILE:-/var/run/docker-nosystemd.pid}"))" || echo '未運行')"
    if is_running && command -v docker >/dev/null 2>&1; then
        printf 'docker info   : %s\n' "$(docker info >/dev/null 2>&1 && echo '正常' || echo '異常')"
    fi
    return "$rc"
}

# ═════════════════════ CLI ═════════════════════

usage() {
    cat <<'EOF'
docker-nosystemd — 無 systemd 環境的 Docker 安裝與管理

用法: docker-nosystemd <命令> [選項]

命令:
  install    安裝 Docker Engine + Compose v2,生成 daemon.json 並啟動(需 root)
             單映射(pull 會 EINVAL)環境自動部署 dsnd-scrub + skopeo + docker 包裝
  start      啟動 dockerd,冪等(已運行則跳過)(需 root)
  stop       停止 dockerd,冪等(需 root)
  restart    重啟 dockerd(需 root)
   scrub-pull <image>[:tag]
              下載映像 → 層 uid/gid 歸零重簽 → docker load(單映射環境的一鍵拉取)
   run [--rm] <image> <cmd> [args...]
              docker create → export 解出 → chroot 執行(「窮人容器」,需 root;
              適用連 OCI runtime 都被沙箱焊死的環境;無 ns/cgroup/proc 隔離)
              支援 docker run 選項:-d/-e/--name/-v(快照)/-w/--entrypoint/--rm;
              -d 容器可由 ps/stop/rm/logs 管理
   ps         列出 chroot 容器(-d 啟動的)
   rm <name>  刪除 chroot 容器(自動停止其進程)
   stop <name> 停止 chroot 容器(無參 = 停 dockerd,原行為)
   logs <name> [N] 查看 chroot 容器日誌(無參/-f/N = dockerd 日誌,原行為)
   status     查詢運行狀態(運行中返回 0,未運行返回 1)
  logs [N|-f] 查看 dockerd 日誌(默認 50 行,-f 跟隨)
  doctor     環境診斷(不修改任何東西)
  help       顯示本說明

選項(start/stop 支援):
  --quiet, -q   靜默模式

環境變量(高級):
  DSND_FORCE_NET_MODE=full|noiptables|none   強制網路模式
  DSND_FORCE_STORAGE=overlay2|vfs            強制存儲驅動
  DSND_FORCE_INSTALL=1                       強制重裝 engine
  DSND_USERNS_MODE=auto|never|force          dockerd 啟動包裝
  DSND_INSTALL_SCRUB=1                       強制部署 scrub 工具鏈
  DSND_SCRUB_URL=<base-url>                  dsnd-scrub 下載基底 URL
  DSND_PROXY_PORT=<port>                     scrub proxy 埠(默認 5200;單映射環境
                                              install 自動設定並注入 registry-mirrors)
  DSND_PROXY_PID_FILE / DSND_PROXY_LOG_FILE  proxy pidfile / 日誌路徑覆蓋
EOF
    return 0
}

main() {
    local _sub="${1:-}"
    if [[ -z "$_sub" ]]; then
        usage >&2
        return 1
    fi
    case "$_sub" in
        -h | --help | help)
            usage
            return 0
            ;;
        install)
            require_root || return 1
            shift
            do_install "$@"
            ;;
        start)
            require_root || return 1
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --quiet | -q) export DSND_QUIET=1 ;;
                esac
                shift
            done
            do_start
            ;;
        stop)
            require_root || return 1
            shift
            # 帶容器名參數 = 停 chroot 容器;無參(或僅 --quiet)= 停 dockerd
            if [[ $# -gt 0 && "$1" != --quiet && "$1" != -q ]]; then
                dsnd_cr_stop "$1"
                return $?
            fi
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --quiet | -q) export DSND_QUIET=1 ;;
                esac
                shift
            done
            do_stop
            ;;
        restart)
            require_root || return 1
            do_restart
            ;;
        scrub-pull)
            shift
            do_scrub_pull "$@"
            ;;
        run)
            require_root || return 1
            shift
            do_scrub_run "$@"
            ;;
        ps)
            dsnd_cr_ps
            ;;
        rm)
            shift
            dsnd_cr_rm "${1:?用法:docker-nosystemd rm <容器名>}"
            ;;
        status)
            do_status
            ;;
        logs)
            shift
            # 第一參為 -f 或純數字 = dockerd 日誌(原行為);其他 = chroot 容器日誌
            if [[ $# -gt 0 && "$1" != -f && "$1" != --follow && ! "$1" =~ ^[0-9]+$ ]]; then
                dsnd_cr_logs "$1" "${2:-}"
                return $?
            fi
            do_logs "$@"
            ;;
        doctor)
            do_doctor
            ;;
        *)
            warn "未知命令:$_sub(使用 --help 查看用法)"
            return 1
            ;;
    esac
}

# 直接管線嚴格模式;被 source(單元測試)時不影響調用方
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    main "$@"
fi
