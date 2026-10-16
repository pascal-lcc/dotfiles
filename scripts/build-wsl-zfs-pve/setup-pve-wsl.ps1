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

# ==========================================
# 0. Check and Auto-Install WSL (Safe Try/Catch Wrapper)
# ==========================================
Write-Host "[*] 正在檢查系統 WSL 狀態..." -ForegroundColor Cyan

$wslExitCode = 0
try {
    # 用 try/catch 強制包覆，徹底封鎖 PowerShell 的 NativeCommandError 紅字中斷
    $null = wsl --status 2>&1
    $wslExitCode =$LASTEXITCODE
} catch {
    # 如果外部指令噴錯被攔截，我們手動給它一個非零的 ExitCode 代表尚未就緒
    $wslExitCode = if ($LASTEXITCODE -ne 0) {$LASTEXITCODE } else { 1 }
}

# 只要 ExitCode 不為 0 (例如未安裝時回傳的 50)，就代表需要安裝或重開機
if ($wslExitCode -ne 0) {
    Write-Host "[!] 偵測到本機尚未完整安裝 WSL，或者尚未重新開機！ (ExitCode: $wslExitCode)" -ForegroundColor Red
    Write-Host "[*] 正在自動觸發 WSL 安裝 (wsl --install --no-launch)..." -ForegroundColor Yellow
    
    # 加入友善提示，避免使用者以為畫面卡死
    Write-Host "[*] 正在背景安裝 WSL 核心元件，這需要一點時間（約數十秒），請耐心等候..." -ForegroundColor Cyan

    # 執行無互動安裝
    try {
        # wsl --install --no-launch 2>&1 | Out-Null
        wsl --install 2>&1 | Out-Null
    } catch {
        # 吞掉錯誤
    }

    Write-Host "[+] WSL 安裝指令已執行完畢。" -ForegroundColor Green

    # 準備重開機後自動續傳的指令 (修正 Join-Path 空格)
    $resumeCommand = ""
    if ($PSScriptRoot) {
        $mainScriptPath = Join-Path $PSScriptRoot "setup-pve-wsl.ps1"
        if (Test-Path $mainScriptPath) {$resumeCommand = "powershell -NoExit -ExecutionPolicy Bypass -File `"$mainScriptPath`""
        }
    }
    if (-not $resumeCommand) {$resumeCommand = "powershell -NoExit -ExecutionPolicy Bypass -Command `"iex (irm 'https://raw.githubusercontent.com/pascal-lcc/dotfiles/main/scripts/build-wsl-zfs-pve/Install-PveZfs.ps1')`""
    }

    # 寫入 Windows RunOnce 登錄檔
    $RegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    Set-ItemProperty -Path $RegistryPath -Name "ResumePveWslInstall" -Value $resumeCommand -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host " [重要通知] WSL 功能已安裝或啟用，系統必須重新開機才能生效！" -ForegroundColor Yellow
    Write-Host " -> 電腦重開機並登入後，安裝程式將會【自動繼續執行】。" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Yellow
    
    $rebootChoice = Read-Host "是否要現在立即重新啟動電腦？(Y/n)"
    if ($rebootChoice -eq 'y' -or $rebootChoice -eq 'Y' -or [string]::IsNullOrEmpty($rebootChoice)) {
        Write-Host "[+] 正在重新啟動電腦，請稍候..." -ForegroundColor Green
        Restart-Computer -Force
    } else {
        Write-Host "[-] 腳本已終止。請手動重開機後再次執行。" -ForegroundColor Red
        exit
    }
} else {
    Write-Host "[+] WSL 狀態正常，繼續執行後續部署..." -ForegroundColor Green
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
# 讓 WSL 系統自己去算出正確的 Linux 掛載路徑
    $wslScriptPath = "/mnt/" + $shFullPath.Substring(0,1).ToLower() + $shFullPath.Substring(2).Replace('\', '/')
    Write-Host "script [$wslScriptPath]" -ForegroundColor Yellow

    wsl -d pve -u root bash -c "
        tr -d '\r' < '$wslScriptPath' > /root/init-pve.sh
        chmod +x /root/init-pve.sh
        /root/init-pve.sh
        rm /root/init-pve.sh
    "
    # wsl -d pve -u root bash -c "
    #     tr -d '\r' < '$wslScriptPath' > /tmp/init-pve.sh
    #     chmod +x /tmp/init-pve.sh
    #     /tmp/init-pve.sh
    # "
    # Write-Host "[*] 正在將 [$shFullPath] init-pve.sh 傳入 pve 內部並執行初始化..." -ForegroundColor Yellow
    # # 透過管線傳入 WSL，並在 Linux 側即時移除所有 \r 字元後再交由 bash 執行
    # Get-Content $shFullPath -Raw | wsl -d pve -u root bash -c "tr -d '\r' | bash"
    # [System.IO.File]::ReadAllBytes($shFullPath) | wsl -d pve -u root bash -c " tr -d '\r' | tee /root/init-pve.sh | bash"
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


