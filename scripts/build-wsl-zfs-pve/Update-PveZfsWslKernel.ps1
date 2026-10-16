param(
    [string]$GitHubRepo = "pascal-lcc/dotfiles",
    [string]$DistroName = "pve",
    [switch]$Help
)

if ($Help -or $args -contains "--help") {
    Write-Host @"
====================================================================
 腳本名稱：Update-PveZfsWslKernel.ps1
====================================================================
【主要功能】
  1. 自動偵測最佳磁碟槽位 (優先使用 D:\Wsl，若無則降級至 C:\Wsl)。
  2. 透過 GitHub API 自動線上查詢指定儲存庫的最新 Release 版本。
  3. 比對本地與遠端版本，若有新核心則自動下載。
  4. 同步下載對應的核心模組壓縮檔 (module-*.tgz)。
  5. 自動產生內建模板的 .wslconfig 設定檔（修正雙反斜線與 LF 換行）。
  6. 透過 Stdin 管道將模組直接傳輸並安裝至 WSL 內。
====================================================================
"@ -ForegroundColor Cyan
    exit 0
}

$ErrorActionPreference = "Stop"

Write-Host "[*] 正在檢查系統硬碟與決定基礎路徑..." -ForegroundColor Cyan

# 1. 動態決定 D 槽或 C 槽基礎路徑
$BaseDir = if (Test-Path "D:\") { "D:\Wsl" } else { "C:\Wsl" }
$DiskDir = "$BaseDir\disk"
$KernelDir = "$BaseDir\kernel"

Write-Host "[+] 決定基礎路徑為：$BaseDir" -ForegroundColor Green

# 2. 建立目錄
if (!(Test-Path $DiskDir)) { New-Item -ItemType Directory -Force -Path $DiskDir | Out-Null }
if (!(Test-Path $KernelDir)) { New-Item -ItemType Directory -Force -Path $KernelDir | Out-Null }

# 3. 透過 GitHub API 取得最新 Release 資訊與比對
Write-Host "[*] 正在透過 GitHub API 查詢 $GitHubRepo 最新版本..." -ForegroundColor Cyan
try {
    $apiUrl = "https://api.github.com/repos/$GitHubRepo/releases/latest"
    $releaseInfo = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing
    
    $latestTag = $releaseInfo.tag_name
    Write-Host "[+] 成功對應到最新 Tag: $latestTag" -ForegroundColor Green

    $kernelAsset = $releaseInfo.assets | Where-Object { $_.name -match '^bzImage-' } | Select-Object -First 1
    $moduleAsset = $releaseInfo.assets | Where-Object { $_.name -match '^module-.*\.tgz$' } | Select-Object -First 1

    if ($null -eq $kernelAsset) {
        Write-Error "[-] 在 GitHub Release 中找不到符合 bzImage- 的核心檔案。"
        exit 1
    }

    $kernelName = $kernelAsset.name
    $kernelDownloadUrl = $kernelAsset.browser_download_url
    $TargetKernelPath = Join-Path $KernelDir $kernelName

    $NeedUpdateKernel = $true
    if (Test-Path $TargetKernelPath) {
        Write-Host "[+] 本地已存在相同核心檔案：$TargetKernelPath" -ForegroundColor Yellow
        $NeedUpdateKernel = $false
    }

    $HasModule = $false
    if ($null -ne $moduleAsset) {
        $moduleName = $moduleAsset.name
        # $moduleDownloadUrl = $moduleAsset.browser_download_url
        $TargetModulePath = Join-Path $KernelDir $moduleName
        # $HasModule = $true
    }

} catch {
    Write-Error "[-] 無法連線至 GitHub API 或解析 Release 資訊：$_"
    exit 1
}

# 4. 條件式下載核心與模組
$NeedWslRestart = $false

if ($NeedUpdateKernel) {
    Write-Host "[*] 下載新核心檔案至 $TargetKernelPath ..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $kernelDownloadUrl -OutFile $TargetKernelPath -UseBasicParsing
    $NeedWslRestart = $true
} else {
    Write-Host "[*] 核心版本無須更新，跳過下載。" -ForegroundColor Green
}

if ($HasModule) {
    if (!(Test-Path $TargetModulePath)) {
        Write-Host "[*] 下載對應的模組壓縮檔 $moduleName ..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $moduleDownloadUrl -OutFile $TargetModulePath -UseBasicParsing
    } else {
        Write-Host "[+] 本地已存在模組壓縮檔：$TargetModulePath" -ForegroundColor Yellow
    }
}

# 5. 渲染並產生 .wslconfig（使用 .Replace 確保反斜線剛好兩條，並強制 LF）
Write-Host "[*] 正在計算硬體規格並產生 .wslconfig..." -ForegroundColor Cyan
$winCpu = [int]$env:NUMBER_OF_PROCESSORS
$totalBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
$totalGb = [int]($totalBytes / 1GB)

$wslCpu = [Math]::Max(2, $winCpu - 2)
$wslMemGb = [int]($totalGb * 0.75)
$zfsMax = [long]($wslMemGb * 0.75 * 1GB)
$zfsMin = [long]($wslMemGb * 0.25 * 1GB)
$wslSwapGb = [int]($totalGb * 0.2)

# 修正：直接用 .Replace 把 \ 換成 \\，避免多出一倍
$escapedKernelPath = $TargetKernelPath.Replace('\', '\\')

$wslConfigTemplate = @"
[wsl2]
memory={{MEM}}GB
processors={{CPU}}
kernel={{KERNEL_PATH}}
swap={{SWAP_SIZE}}GB
nestedVirtualization=true
networkingMode=Mirrored
ipv6=false
dhcp=false
# ZFS ARC 自動根據分配的記憶體調整
kernelCommandLine = elevator=none sysctl.vm.vfs_cache_pressure=50 sysctl.vm.swappiness=10 zfs.zfs_arc_max={{ZFS_MAX}} zfs.zfs_arc_min={{ZFS_MIN}} zfs.zfs_arc_meta_limit_percent=75

[experimental]
dnsTunneling=false
autoMemoryReclaim=gradual
hostAddressLoopback=true
sparseVhd=true
"@

$configContent = $wslConfigTemplate.Replace('{{MEM}}', $wslMemGb)
$configContent = $configContent.Replace('{{CPU}}', $wslCpu)
$configContent = $configContent.Replace('{{SWAP_SIZE}}', $wslSwapGb)
$configContent = $configContent.Replace('{{ZFS_MAX}}', $zfsMax)
$configContent = $configContent.Replace('{{ZFS_MIN}}', $zfsMin)
$configContent = $configContent.Replace('{{KERNEL_PATH}}', $escapedKernelPath)

$configContent = $configContent -replace "`r`n", "`n"

$wslConfigPath = "$env:USERPROFILE\.wslconfig"
[System.IO.File]::WriteAllText($wslConfigPath,$configContent, [System.Text.Encoding]::UTF8)
Write-Host "[+] 已成功為 ${totalGb}GB RAM 系統產生 .wslconfig" -ForegroundColor Green

# 6. 透過 Stdin 傳遞字串，直接在 WSL 內部存檔、賦予權限並執行
$pkgVer = $moduleName -replace '^module-', '' -replace '\.tgz$', ''
$downloadUrl = $moduleAsset.browser_download_url
Write-Host "[*] test $TargetModulePath" -ForegroundColor Cyan

if ( $true ) {
    Write-Host "[*] 正在透過 Stdin 將腳本寫入 WSL 內部並顯示內容..." -ForegroundColor Cyan

    wsl --terminate $DistroName

    $drive = $TargetModulePath.Substring(0, 1).ToLower()

    $scriptContent = @"
#!/usr/bin/env bash
pkg_ver="$pkgVer"
download_url="$downloadUrl"
tmp_tar="/tmp/module_download.tgz"
wsl_module_dir="/lib/modules/`$pkg_ver"

echo "[WSL-DEBUG] 準備檢查模組版本: `$pkg_ver"
echo "[WSL-DEBUG] 下載網址: `$download_url"

if [ ! -d "`$wsl_module_dir" ]; then
    echo "[WSL-DEBUG] 發現模組尚未安裝，開始準備壓縮檔..."
 
    echo "[WSL-DEBUG] 從 GitHub 遠端下載模組..."
    if command -v curl &> /dev/null; then
        curl -L -o "`$tmp_tar" "`$download_url"
    elif command -v wget &> /dev/null; then
        wget -O "`$tmp_tar" "`$download_url"
    else
        echo "Error: WSL 內找不到 curl 或 wget 可供下載。"
        exit 1
    fi

    if [ -s "`$tmp_tar" ]; then
        echo "[WSL-DEBUG] 檢查壓縮檔大小正常，準備安裝..."
        mkdir -p /lib/modules
        tar -xzf "`$tmp_tar" -C /lib/modules
        depmod -a "`$pkg_ver"
        echo "Modules installed successfully."
        rm -f "`$tmp_tar"
    else
        echo "Error: 取得的模組檔案為空或下載失敗。"
        exit 1
    fi
else
    echo "[WSL-DEBUG] 模組版本 `$pkg_ver 已經存在於 /lib/modules 中，跳過安裝。"
fi
"@

    # 透過管道傳入 WSL，清除 \r 換行符號並僅 cat 印出供檢查
    $scriptContent | wsl -d $DistroName -u root bash -c "tr -d '\r' > /tmp/ins.sh && chmod +x /tmp/ins.sh && /tmp/ins.sh && /bin/rm /tmp/ins.sh"
}


# if ($HasModule -and (Test-Path $TargetModulePath)) {
if (0) {
    Write-Host "[*] 正在透過 WSL 安裝模組 ($DistroName)..." -ForegroundColor Cyan
    
    $pkgVer = $moduleName -replace '^module-', '' -replace '\.tgz$', ''
    
    # 將 Windows 路徑轉為 WSL 內部 /mnt/ 路徑 (例如 D:\Wsl\... -> /mnt/d/Wsl/...)
    $drive = $TargetModulePath.Substring(0, 1).ToLower()
    $wslModulePath = "/mnt/$drive" + $TargetModulePath.Substring(2).Replace('\', '/')

    Write-Host "[DEBUG] 本地路徑: $TargetModulePath" -ForegroundColor Yellow
    Write-Host "[DEBUG] WSL 路徑: $wslModulePath" -ForegroundColor Yellow
    Write-Host "[DEBUG] 目標版本: $pkgVer" -ForegroundColor Yellow

    # 透過 PowerShell 預先展開變數，直接傳入 WSL 執行
    wsl -d $DistroName -u root bash -c "
        if [ -f '$wslModulePath' ]; then
            if [ ! -d '/lib/modules/$pkgVer' ]; then
                echo 'Installing modules for version $pkgVer...'
                mkdir -p /lib/modules
                tar -xzf '$wslModulePath' -C /lib/modules
                depmod -a '$pkgVer'
                echo 'Modules installed successfully.'
            else
                echo 'Modules for $pkgVer already exist.'
            fi
        else
            echo 'Error: Module file not found inside WSL at $wslModulePath'
        fi
    "
}
# 7. 重啟 WSL
if ($NeedWslRestart) {
    Write-Host "[*] 正在終止並重啟 WSL 服務以載入新核心..." -ForegroundColor Cyan
    wsl --shutdown
    Write-Host "[+] WSL 核心與模組更新流程全部完成！" -ForegroundColor Green
} else {
    Write-Host "[+] 系統已是最新狀態，無需重啟 WSL。" -ForegroundColor Green
}
