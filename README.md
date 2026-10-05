# docker-nosystemd

在**沒有 systemd 的環境**中安裝並運行 Docker 的單檔案腳本 — 專為「Docker 裡面的 VPS」(容器型 VPS / LXC / chroot 環境)設計。

自動完成:Docker Engine + Compose v2 安裝、核心能力探測(iptables / bridge / overlay)、`daemon.json` 降級配置、開機自啟注入,全程冪等,可重複執行。

## 一鍵安裝

```bash
curl -fsSL https://raw.githubusercontent.com/s12ryt/s12ryt-nosystemd-docker/main/install.sh | sudo bash
```

或使用 `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/s12ryt/s12ryt-nosystemd-docker/main/install.sh | sudo bash
```

Alpine(預設無 bash / sudo,先以 root 安裝依賴):

```sh
apk add bash curl
curl -fsSL https://raw.githubusercontent.com/s12ryt/s12ryt-nosystemd-docker/main/install.sh | bash
```

安裝完成後即可使用 `docker` / `docker compose`,並可透過 `docker-nosystemd` 命令管理 daemon。

## 支援環境

| 發行版 | 版本 | 說明 |
|---|---|---|
| Debian | 11 / 12 / 13 | 已實測(WSL Debian 13) |
| Ubuntu | 20.04+ | 與 Debian 同路徑(apt 官方源 → docker.io 回退) |
| Alpine | 3.18+ | 需先 `apk add bash curl` |

- **有 systemd 的機器也能用**:偵測到 systemd 時自動改走 `systemctl enable --now`,失敗則回退手動管理模式。
- CentOS / RHEL 系不支援(需求外)。

## 手動安裝

```bash
git clone https://github.com/s12ryt/s12ryt-nosystemd-docker.git
cd s12ryt-nosystemd-docker
sudo bash src/docker-nosystemd.sh install
```

## 命令

安裝後主腳本位於 `/usr/local/bin/docker-nosystemd`:

| 命令 | 說明 | 需要 root |
|---|---|---|
| `install` | 安裝 Engine + Compose v2、生成 `daemon.json` 並啟動 | ✅ |
| `start` | 啟動 dockerd(冪等;自動收養已運行的 dockerd) | ✅ |
| `stop` | 停止 dockerd(TERM → 15s → KILL;冪等) | ✅ |
| `restart` | 重啟 dockerd | ✅ |
| `scrub-pull <image>` | 下載映像 → 層歸零重簽 → `docker load`(單映射環境的 pull 替代) | ❌ |
| `status` | 查詢狀態(運行中返回 0,未運行返回 1) | ❌ |
| `logs [N\|-f]` | 查看 dockerd 日誌(默認 50 行,`-f` 跟隨) | ❌ |
| `doctor` | 環境診斷(不修改任何東西) | ❌ |

高級選項(環境變量):

```bash
DSND_FORCE_NET_MODE=full|noiptables|none   # 強制網路模式(跳過自動探測)
DSND_FORCE_STORAGE=overlay2|vfs            # 強制存儲驅動
DSND_FORCE_INSTALL=1                       # 強制重裝 engine
DSND_USERNS_MODE=auto|never|force          # dockerd 啟動包裝(見下節)
```

`start` / `stop` 支援 `--quiet, -q` 靜默模式。

## 網路自動降級

安裝時實測核心能力(iptables NAT 表、bridge 建立、overlay 掛載),按結果生成 `/etc/docker/daemon.json`;啟動失敗時分析日誌自動降級重試(最多 4 輪):

| 模式 | daemon.json | 適用場景 |
|---|---|---|
| `full` | `iptables=true` + bridge | 一般無特權容器 |
| `noiptables` | `iptables=false` | 缺 NET_ADMIN / NAT 表的環境 |
| `none` | `iptables=false` + `bridge=none` | 網路完全受限,配合用户層隧道 |

`none` 模式下容器預設無對外網路 — 適合搭配 **Cloudflare Tunnel**(cloudflared)等用户層隧道打通進出,這正是本項目的目標場景之一。

## user namespace 包裝模式(實驗性)

無特權容器缺少 `CAP_SYS_ADMIN` 時,Docker 註冊映像層的 `unshare(CLONE_NEWNS)` 會被拒(見下方已知限制)。若核心允許 unprivileged user namespace,腳本會自動把 dockerd 包進 `unshare -Ur` 啟動 — 在新的 user namespace 內 uid 0 擁有全部 capabilities,映像層註冊即可放行(rootless Docker 同原理)。

- `auto`(默認):直接 `unshare -m` 可行 → 不包裝;被拒但 `unshare -U` 可行 → 自動包裝
- `never`:禁用;`force`:只要 userns 可行就包裝
- 探測命令:`unshare -U true && echo 可行`(失敗 = 核心/seccomp 擋了 userns,此模式無法使用)
- `doctor` 會顯示 `userns 包裝模式` / `userns 範圍映射` 決策結果
- 包裝模式會自動傳 `-G root` 給 dockerd:unix socket 的 group 改為映射內的 gid 0,否則 chown `/var/run/docker.sock` 到默認 `docker` group(映射外 gid)會報 `invalid argument`

### 範圍映射模式(0-65535 恆等映射)

包裝模式啟動時,腳本會進一步探測能否寫入 user namespace 的恆等範圍映射(`uid_map`/`gid_map` 各 `0 0 65536`,需要容器 root 具備 `CAP_SETUID`/`CAP_SETGID`):

- **可用**(範圍映射模式):dockerd 由 `unshare --user` 起的 bash 在**新 ns 內部**直接寫 `/proc/self/{setgroups,uid_map,gid_map}` 完成 0-65535 恆等映射後再 exec — 內部寫法繞過父進程寫 `/proc/$pid/*` 的 ptrace 權限檢查(無特權容器常剝 `CAP_SYS_PTRACE`,外部寫法會 `Permission denied`);層內任意 uid/gid 的 `lchown` 均落在映射內,`docker pull` 解壓層可正常註冊(等效 rootless Docker 的 subuid 方案,但無需 `/etc/subuid`)。
- **不可用**(單映射模式,`unshare -Ur -G root`):映像層註冊的 `unshare` 可放行,但 tar 檔內**映射外** uid/gid 的檔案(如 `/home` 的 nobody:nogroup 65534、`/etc/shadow` 的 gid 42)會在 `docker pull` 時報 `failed to Lchown ... invalid argument` — 此為核心硬限制,只能由宿主以特權模式運行容器徹底解決。`doctor` 與安裝輸出會附具體失敗原因(如 `uid_map 寫入被拒(需 CAP_SETUID)`)。

此模式配搭 `vfs` 存儲 + `bridge=none` 網路(腳本會自動降級)即為無特權容器的完整組合;`docker pull` / `docker run` 行為需實機驗證。

## 開機自啟

無 systemd 時自動注入(冪等,帶 `# BEGIN/END docker-nosystemd autostart` 標記):

- `/etc/profile.d/00-docker-nosystemd.sh` — 首個登入 shell 啟動 dockerd
- `/etc/rc.local` — 開機腳本(若環境支援)

## 測試

```bash
bash tests/run-tests.sh              # 單元測試(bash mini 框架,204 斷言;單文件逾時自動標記 TIMEOUT)
bash tests/run-tests.sh && shellcheck install.sh src/docker-nosystemd.sh
bash tests/integration/test_install_debian.sh   # 需 root + 無 systemd 的 Debian
```

- 單元測試覆蓋:發行版 / init 偵測、`daemon.json` 降級矩陣、自啟注入冪等、pidfile 生命週期、CLI 行為、一鍵安裝入口。
- 整合測試已於 WSL Debian 13(關閉 systemd)實機驗證:官方源安裝 docker-ce + Compose v2 → 啟動 → `docker run --rm busybox true` smoke 通過;從零純淨安裝(移除既有 engine)同樣通過。

## 映像清洗工具(scrub,已整合進一鍵安裝)

當環境連 user namespace 範圍映射都被沙箱攔截(如 gVisor 類平台,`doctor` 顯示 `uid_map 寫入被拒` 且 caps 齊全),`docker pull` 解壓層的 `Lchown` 無法放行 — 此時改走**補丁映像而非補丁 docker** 的等效路線。**`install` 偵測到此環境(單映射模式)會自動部署整套工具**(也可 `DSND_INSTALL_SCRUB=1` 強制):

- `/usr/local/bin/dsnd-scrub` — Go 靜態二進制([Release v1.1.0-scrub](https://github.com/s12ryt/s12ryt-nosystemd-docker/releases/tag/v1.1.0-scrub),無需 python;含 `file` 清洗與 `proxy` 兩子命令)
- `skopeo` — 無 daemon 的映像下載器(apt/apk 自動裝)
- `/usr/local/bin/docker` 包裝 — **`docker pull busybox` 自動轉發 scrub 流程**,其餘命令原樣透傳(絕對路徑 `/usr/bin/docker` 可繞過)
- **本地 pull-through proxy** — `dsnd-scrub proxy` 常駐(默認 `127.0.0.1:5200`),`daemon.json` 自動注入 `registry-mirrors` + `insecure-registries` → **`docker pull` 完全透明走清洗管線**;`docker info` 的 Registry Mirrors 可確認;隨 `docker-nosystemd start` / `stop` 一同啟停

```bash
docker pull busybox:latest            # 自動轉發:下載 → 清洗 → load
# 等效手動:docker-nosystemd scrub-pull busybox:latest
docker run --rm busybox:latest true   # 驗證
```

原理:`skopeo copy` 以 docker-archive 形式下載映像(不解壓層,繞開死點)→ `dsnd-scrub` 把每層 tar 內所有檔案的 uid/gid 歸零為 `0:0`,並級聯重算層 digest → config `diff_ids` → manifest → index → legacy `manifest.json` → `docker load` 匯入。單映射模式(`unshare -Ur`)的 dockerd 對 `Lchown(x, 0, 0)` 全放行 — 死點反轉。

- 已於 WSL 實測:busybox 清洗後 `docker load` 成功、`docker run` 通過(Go 二進制與 python 版行為等價)
- 副作用:映像內所有檔案變 `root:root`(一般應用無感;sshd 等權限敏感應用的極少數檔案有影響)
- **compose 全透明**:本地 proxy 已接入 `registry-mirrors`,`docker compose up` 的內建自動 pull 也走清洗管線(注意 `registry-mirrors` 僅對 docker.io 映像生效;其他 registry 的 pull 由 `/usr/local/bin/docker` 包裝攔截轉發)
- 支援未壓縮 / gzip 層、多 manifest 遍歷;`doctor` 顯示 scrub 工具與 proxy 運行狀態

## 已知限制

- Alpine 路徑已實作並通過單元測試,但未實機驗證。
- 極舊核心連 `vfs` 存儲都無法掛載時,腳本會明確報錯退出(不做進一步降級)。
- `rc.local` 自啟依賴容器內存在 init 進程;純 `profile.d` 注入在無 init 容器仍有效(首個登入時啟動)。
- **無特權容器(無 `CAP_SYS_ADMIN`)的硬限制**:dockerd 可以 `vfs` + `bridge=none` 模式啟動,但 Docker 註冊映像層時必須調用 `unshare(CLONE_NEWNS)`(安全隔離),缺該 capability 時 `docker pull` / `docker load` 會報 `failed to register layer: unshare: operation not permitted`。這是 Docker 上游設計([moby#22139](https://github.com/moby/moby/issues/22139)),無任何 daemon.json 選項可繞過。緩解方式依優先級:**①核心允許 unprivileged userns 時**,腳本自動以 user namespace 包裝模式啟動(見上節);**②宿主以特權模式(`--privileged`)運行容器**;③兩者皆不可行時只能換環境或改用無權限方案(如 uDocker/PROot)。安裝腳本會在此情境提前警告,`doctor` 會顯示 `unshare` / `user namespace` / `Seccomp` / `CapEff` / `userns 包裝模式` 精確狀態供判定。
