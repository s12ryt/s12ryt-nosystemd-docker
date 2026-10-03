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
# DSND_USERNS_MODE      dockerd 啟動包裝:auto(默認)| never | force(unshare -Ur)
# DSND_FORCE_INSTALL   =1 強制重裝(即使 dockerd 已存在)

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
    out+="  }$nl"
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
    if userns_wrap_needed; then
        [[ -z "${DSND_QUIET:-}" ]] && log "以 user namespace 包裝模式啟動 dockerd(unshare -Ur):映像層註冊將於 ns 內取得 CAP_SYS_ADMIN"
        nohup unshare -Ur "$dockerdbin" >> "$logfile" 2>&1 &
    else
        nohup "$dockerdbin" >> "$logfile" 2>&1 &
    fi
    local pid=$!
    echo "$pid" > "$pidfile"
    if wait_daemon_ready; then
        [[ -z "${DSND_QUIET:-}" ]] && log "dockerd 已啟動 (PID $pid)"
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
                    log "dockerd 以 user namespace 包裝模式運行:映像層註冊將於 ns 內取得 CAP_SYS_ADMIN(請實測 docker pull)"
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
  start      啟動 dockerd,冪等(已運行則跳過)(需 root)
  stop       停止 dockerd,冪等(需 root)
  restart    重啟 dockerd(需 root)
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
EOF
    return 0
}

main() {
    local cmd="${1:-}"
    if [[ -z "$cmd" ]]; then
        usage >&2
        return 1
    fi
    case "$cmd" in
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
        status)
            do_status
            ;;
        logs)
            shift
            do_logs "$@"
            ;;
        doctor)
            do_doctor
            ;;
        *)
            warn "未知命令:$cmd(使用 --help 查看用法)"
            return 1
            ;;
    esac
}

# 直接管線嚴格模式;被 source(單元測試)時不影響調用方
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    main "$@"
fi
