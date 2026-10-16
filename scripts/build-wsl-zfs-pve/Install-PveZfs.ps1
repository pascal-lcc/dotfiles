<#
.SYNOPSIS
    PVE WSL ZFS 遠端一鍵安裝引導程式 (Bootstrap)
.DESCRIPTION
    不需要 git clone，從 GitHub 下載相依腳本至暫存區執行，結束後自動清理環境。
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "    PVE WSL ZFS 遠端一鍵安裝與部署工具引導器" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$BaseUrl = "https://raw.githubusercontent.com/pascal-lcc/dotfiles/main/scripts/build-wsl-zfs-pve"
$TempDir = "$env:TEMP\PveZfsWslInstall"

try {
    # 1. 建立本機暫存工作目錄
    if (!(Test-Path $TempDir)) {
        New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
    }

    Write-Host "[*] 正在從 GitHub 下載最新安裝腳本..." -ForegroundColor Yellow

    # 2. 下載相依檔案
    $Files = @("setup-pve-wsl.ps1", "init-pve.sh", "Update-PveZfsWslKernel.ps1")

    foreach ($file in $Files) {
        $fileUrl = "$BaseUrl/$file"
        $destPath = Join-Path $TempDir $file
        Write-Host "    - 下載: $file ..." -NoNewline
        try {
            Invoke-WebRequest -Uri $fileUrl -OutFile $destPath -UseBasicParsing
            Write-Host " [成功]" -ForegroundColor Green
        } catch {
            Write-Host " [失敗]" -ForegroundColor Red
            throw "無法從遠端下載 $file，請檢查網路連線或 GitHub 路徑是否正確。錯誤: $_"
        }
    }

    Write-Host "[+] 所有相依檔案已成功下載至暫存區。" -ForegroundColor Green
    Write-Host "[*] 準備啟動主安裝程式 (setup-pve-wsl.ps1)..." -ForegroundColor Yellow
    Write-Host ""

    # 3. 執行主安裝腳本
    $MainScript = Join-Path $TempDir "setup-pve-wsl.ps1"
    & $MainScript

} finally {
    # 4. 清理機制：無論成功或發生錯誤，結束前自動刪除暫存資料夾
    if (Test-Path $TempDir) {
        Write-Host ""
        Write-Host "[*] 正在清理暫存檔案..." -ForegroundColor Yellow
        $Files = @("setup-pve-wsl.ps1", "init-pve.sh", "Update-PveZfsWslKernel.ps1")
        foreach ($file in $Files) {
            $filePath = Join-Path $TempDir $file
            if (Test-Path $filePath) {
                Remove-Item -Force $filePath -ErrorAction SilentlyContinue
            }
        }
        Write-Host "[+] 暫存檔案已清理完畢。" -ForegroundColor Green
    }
    wsl --shutdown
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "    部署引導流程執行完畢！" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
