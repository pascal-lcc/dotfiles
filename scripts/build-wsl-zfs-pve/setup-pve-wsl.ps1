# ==========================================
# PVE on WSL 完整安裝與初始化腳本 (setup-pve-wsl.ps1)
# ==========================================

$scriptDir   = $PSScriptRoot
$targetDrive = if (Test-Path "D:") { "D:" } else { "C:" }
$targetDir   = "$targetDrive\Wsl\disk"
$pveInstDir  = "$targetDir\pve"
$tarPath     = "$targetDir\pve_temp.tar"
$shFullPath  = Join-Path $scriptDir "init-pve.sh"
$updateScriptFullPath = Join-Path $scriptDir "Update-PveZfsWslKernel.ps1"

if (-not (Test-Path $targetDir)) {
    New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
}

$wslList = wsl --list --quiet 2>$null

# 1. 檢查 pve 實例是否存在

# if (0) {

if ($wslList -contains "pve") {
    Write-Host "[!] 警告：系統中已經存在名為 'pve' 的 WSL 實例。" -ForegroundColor Yellow
    $choicePve = Read-Host "是否要刪除舊的 pve 並重新建立？(y/N)"
    if ($choicePve -eq 'y') {
        Write-Host "[*] 正在終止並註銷舊的 pve 實例..." -ForegroundColor Yellow
        wsl --terminate pve 2>$null
        wsl --unregister pve
    } else {
        Write-Host "[-] 操作已取消，結束腳本。" -ForegroundColor Red
        exit
    }
}

$sourceDistro = ""

# 2. 檢查是否有現成 Debian
if ($wslList -match "^Debian\s*$") {
    Write-Host "[*] 偵測到系統中原本已存在 Debian 實例。" -ForegroundColor Cyan
    Write-Host "請選擇處理方式："
    Write-Host "  1) 直接使用現有的 Debian 轉換成 pve（會被匯出並改名，原 Debian 移除）"
    Write-Host "  2) 保留現有的 Debian 不動，另外安裝一個新的乾淨 Debian 來轉成 pve"
    
    $ans = Read-Host "請輸入選項 (1 或 2，預設 2)"
    if ($ans -eq "1") {
        $sourceDistro = "Debian"
    } else {
        $sourceDistro = "Debian_Temp_Install"
    }
} else {
    $sourceDistro = "Debian_Temp_Install"
}


wsl --shutdown
Stop-Service WslService -Force -ErrorAction SilentlyContinue

$wslConfigPath = "$env:USERPROFILE\.wslconfig"
$shouldRestoreToTrue =$false

if (Test-Path $wslConfigPath) {
    Write-Host "[*] 正在檢查 .wslconfig 的 sparseVhd 設定..." -ForegroundColor Cyan
    $configContent = Get-Content $wslConfigPath -Raw
    
    if ($configContent -match 'sparseVhd\s*=\s*true') {
        # 情況 A：原本是 true。我們要暫時改成 false 供匯入使用，最後再改回 true
        $shouldRestoreToTrue =$true
        Write-Host "[*] 偵測到 sparseVhd 目前為 true，暫時改為 false 準備匯入..." -ForegroundColor Yellow
        $configContent =$configContent -replace 'sparseVhd\s*=\s*true', 'sparseVhd=false'
        Set-Content -Path $wslConfigPath -Value $configContent -NoNewline
    }
    elseif ($configContent -match 'sparseVhd\s*=\s*false') {
        # 情況 B：原本就是 false。我們知道最後要把它統一改成 true
        $shouldRestoreToTrue =$true
        Write-Host "[+] 偵測到 sparseVhd 目前為 false（流程結束後將統一改為 true）。" -ForegroundColor Green
    }
    else {
        # 情況 C：原本沒有這一行。我們幫它補上 false 供匯入使用，最後也把它統一改成 true
        $shouldRestoreToTrue =$true
        Write-Host "[*] 未偵測到 sparseVhd 設定，暫時寫入 sparseVhd=false 準備匯入（流程結束後將改為 true）..." -ForegroundColor Yellow
        
        if ($configContent -match '[wsl2]') {
            $configContent =$configContent -replace '[wsl2]', "[wsl2]`nsparseVhd=false"
        } else {
            $configContent += "`n[wsl2]`nsparseVhd=false`n"
        }
        Set-Content -Path $wslConfigPath -Value$configContent -NoNewline
    }
} else {
    # 如果連 .wslconfig 都沒有，我們也可以選擇建立它並設為 true（或者視你的需求而定）
    # $shouldRestoreToTrue =$true
}

# 3. 必要時安裝新 Debian
if ($sourceDistro -eq "Debian_Temp_Install") {
    Write-Host "[*] 正在安裝全新的 Debian 基礎環境..." -ForegroundColor Yellow
    wsl --install -d Debian --no-launch
    $sourceDistro = "Debian"
}

# 4. 匯出與重新匯入
Write-Host "[*] 正在將 $sourceDistro 匯出至暫存檔..." -ForegroundColor Yellow
wsl --export $sourceDistro $tarPath

Write-Host "[*] 清理來源發行版..." -ForegroundColor Yellow
wsl --unregister $sourceDistro

Write-Host "[*] 正在將 pve 匯入至目標路徑: $pveInstDir ..." -ForegroundColor Yellow
wsl --import pve $pveInstDir $tarPath

if (Test-Path $tarPath) {
    Remove-Item $tarPath -Force
}

Write-Host "[+] WSL pve 實例基礎匯入完成！" -ForegroundColor Green

if ($shouldRestoreToTrue -and (Test-Path $wslConfigPath)) {
    $configContent = Get-Content $wslConfigPath -Raw
    # 把檔案裡的 sparseVhd=false 統一改回 true
    $configContent = $configContent -replace 'sparseVhd\s*=\s*false', 'sparseVhd=true'
    Set-Content -Path $wslConfigPath -Value $configContent -NoNewline
    Write-Host "[+] .wslconfig 的 sparseVhd 已順利還原/更新為 true。" -ForegroundColor Green
}
# }

# 5. 執行 Linux 側的初始化腳本 (init-pve.sh)
if (Test-Path $shFullPath) {
    Write-Host "[*] 正在將 init-pve.sh 傳入 pve 內部並執行初始化..." -ForegroundColor Yellow
    
    # 透過管線傳入 WSL，並在 Linux 側即時移除所有 \r 字元後再交由 bash 執行
    Get-Content $shFullPath -Raw | wsl -d pve -u root bash -c "tr -d '\r' | bash"
    
    Write-Host "[+] WSL 內部初始化腳本執行完畢！" -ForegroundColor Green
} else {
    Write-Host "[-] 找不到初始化腳本: $shFullPath，跳過內部初始化。" -ForegroundColor Red
}

# 串接執行核心與模組更新腳本
if (Test-Path $updateScriptFullPath) {
    Write-Host "[*] 正在執行核心與 ZFS 模組更新腳本..." -ForegroundColor Cyan
    & $updateScriptFullPath
} else {
    Write-Warning "[-] 找不到更新腳本：$updateScriptFullPath"
}
#
# 6. 重啟 WSL 實例使設定生效
Write-Host "[*] 正在重啟 pve 實例（wsl --terminate）..." -ForegroundColor Yellow
wsl --terminate pve
Write-Host "[+] pve 實例已成功重啟，所有基礎設定與網路已生效！" -ForegroundColor Cyan


