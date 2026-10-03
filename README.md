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
| `status` | 查詢狀態(運行中返回 0,未運行返回 1) | ❌ |
| `logs [N\|-f]` | 查看 dockerd 日誌(默認 50 行,`-f` 跟隨) | ❌ |
| `doctor` | 環境診斷(不修改任何東西) | ❌ |

高級選項(環境變量):

```bash
DSND_FORCE_NET_MODE=full|noiptables|none   # 強制網路模式(跳過自動探測)
DSND_FORCE_STORAGE=overlay2|vfs            # 強制存儲驅動
DSND_FORCE_INSTALL=1                       # 強制重裝 engine
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

## 開機自啟

無 systemd 時自動注入(冪等,帶 `# BEGIN/END docker-nosystemd autostart` 標記):

- `/etc/profile.d/00-docker-nosystemd.sh` — 首個登入 shell 啟動 dockerd
- `/etc/rc.local` — 開機腳本(若環境支援)

## 測試

```bash
bash tests/run-tests.sh              # 單元測試(bash mini 框架,120 斷言)
bash tests/run-tests.sh && shellcheck install.sh src/docker-nosystemd.sh
bash tests/integration/test_install_debian.sh   # 需 root + 無 systemd 的 Debian
```

- 單元測試覆蓋:發行版 / init 偵測、`daemon.json` 降級矩陣、自啟注入冪等、pidfile 生命週期、CLI 行為、一鍵安裝入口。
- 整合測試已於 WSL Debian 13(關閉 systemd)實機驗證:官方源安裝 docker-ce + Compose v2 → 啟動 → `docker run --rm busybox true` smoke 通過;從零純淨安裝(移除既有 engine)同樣通過。

## 已知限制

- Alpine 路徑已實作並通過單元測試,但未實機驗證。
- 極舊核心連 `vfs` 存儲都無法掛載時,腳本會明確報錯退出(不做進一步降級)。
- `rc.local` 自啟依賴容器內存在 init 進程;純 `profile.d` 注入在無 init 容器仍有效(首個登入時啟動)。
- **無特權容器(無 `CAP_SYS_ADMIN`)的硬限制**:dockerd 可以 `vfs` + `bridge=none` 模式啟動,但 Docker 註冊映像層時必須調用 `unshare(CLONE_NEWNS)`(安全隔離),缺該 capability 時 `docker pull` / `docker load` 會報 `failed to register layer: unshare: operation not permitted`。這是 Docker 上游設計([moby#22139](https://github.com/moby/moby/issues/22139)),無任何 daemon.json 選項可繞過 — 需要**宿主以特權模式(`--privileged`)運行容器**。安裝腳本會在此情境提前警告,`doctor` 會顯示 `unshare` / `Seccomp` / `CapEff` 精確狀態供判定。
