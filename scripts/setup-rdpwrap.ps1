<#
.SYNOPSIS
    自動化安裝 RDP Wrapper 並套用 sebaxakerhtc 最新 rdpwrap.ini 的 PowerShell 腳本
    相容於 Windows PowerShell 5.1 與 PowerShell 7 (pwsh)
#>

# 1. 確保以「系統管理員」身分執行（改用 powershell 確保絕對相容）
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] 此腳本需要系統管理員權限，正在嘗試自動提權重新執行..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$ErrorActionPreference = "Stop"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " 開始安裝與設定 RDP Wrapper (結合最新 INI)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$tempDir = "$env:TEMP\RDPWrapInstall"
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    # 2. 下載官方 RDPWrap v1.6.2 ZIP 壓縮檔
    $zipUrl = "https://github.com/stascorp/rdpwrap/releases/download/v1.6.2/RDPWrap-v1.6.2.zip"
    $zipPath = "$tempDir\RDPWrap.zip"
    
    Write-Host "[*] 正在下載 RDP Wrapper v1.6.2..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath

    Write-Host "[*] 正在解壓縮檔案..." -ForegroundColor Yellow
    Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force

    # 3. 下載 sebaxakerhtc 維護的最新 rdpwrap.ini
    $iniUrl = "https://raw.githubusercontent.com/sebaxakerhtc/rdpwrap.ini/master/rdpwrap.ini"
    $iniPath = "$tempDir\rdpwrap.ini"
    
    Write-Host "[*] 正在從 sebaxakerhtc 抓取最新的 rdpwrap.ini..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $iniUrl -OutFile $iniPath

    # 4. 執行安裝工具 (RDPWInst.exe -i)
    $rdpWInstExe = "$tempDir\RDPWInst.exe"
    if (Test-Path $rdpWInstExe) {
        Write-Host "[*] 正在執行 RDP Wrapper 核心安裝程式..." -ForegroundColor Yellow
        Start-Process -FilePath $rdpWInstExe -ArgumentList "-i" -Wait -NoNewWindow
    } else {
        throw "找不到安裝執行檔 RDPWInst.exe"
    }

    # 5. 確認安裝路徑並覆蓋最新的 rdpwrap.ini
    $targetDir = "$env:ProgramFiles\RDP Wrapper"
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    Write-Host "[*] 正在將最新的 rdpwrap.ini 覆蓋至安裝目錄..." -ForegroundColor Yellow
    Copy-Item -Path $iniPath -Destination "$targetDir\rdpwrap.ini" -Force

    # 6. 重新啟動遠端桌面服務 (TermService) 以套用設定
    Write-Host "[*] 正在重新啟動 TermService 服務..." -ForegroundColor Yellow
    Restart-Service -Name TermService -Force

    Write-Host "[+] RDP Wrapper 安裝與最新 INI 更新成功完成！" -ForegroundColor Green

} catch {
    Write-Host "[!] 安裝過程中發生錯誤: $_" -ForegroundColor Red
} finally {
    # 7. 清理暫存目錄
    if (Test-Path $tempDir) {
        Remove-Item $tempDir -Recurse -Force
    }
}
