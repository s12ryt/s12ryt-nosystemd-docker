# run-tests-in-wsl.ps1 — 從 Windows 一鍵在 WSL Debian 跑單元測試
# 用法:powershell -File run-tests-in-wsl.ps1 [-Integration]
param(
    [switch]$Integration  # 加上則同時跑整合測試(需無 systemd 的 WSL,會改動環境)
)

$distro = "Debian"
$proj = "/mnt/f/Project/sh/s12ryt-nosystemd-docker"

Write-Host "== unit tests =="
wsl.exe -d $distro -- bash -lc "cd $proj && bash tests/run-tests.sh"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($Integration) {
    Write-Host "== integration tests (root, requires non-systemd WSL) =="
    wsl.exe -d $distro -u root -- bash -lc "cd $proj && bash tests/integration/test_install_debian.sh"
    exit $LASTEXITCODE
}
exit 0
