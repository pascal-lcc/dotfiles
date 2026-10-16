# =========================================================
# setup-dotfiles.ps1
# 免 Git 下載並執行 Windows 11 Dotfiles 部署
# =========================================================
$ErrorActionPreference = 'Stop'

$repoZipUrl  = "https://github.com/pascal-lcc/dotfiles/archive/refs/heads/main.zip"
$sessionGuid = [guid]::NewGuid().ToString().Substring(0, 8)
$tempZip     = "$env:TEMP\dotfiles_$sessionGuid.zip"
$tempExtract = "$env:TEMP\dotfiles_extracted_$sessionGuid"

try {
    Write-Host "[*] 正在從 GitHub 抓取最新 dotfiles 打包檔..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $repoZipUrl -OutFile $tempZip

    Write-Host "[*] 正在解壓縮至暫存目錄..." -ForegroundColor Cyan
    Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

    # 找到解壓出來的 dotfiles-main 資料夾
    $extractedFolder = Get-ChildItem -Path $tempExtract | Where-Object { $_.PSIsContainer } | Select-Object -First 1
    $scriptDir = Join-Path $extractedFolder.FullName "scripts"

    Write-Host "[+] 解壓完成！準備執行 deploy.ps1..." -ForegroundColor Green
    Write-Host ""

    # 切換至暫存區的 scripts 目錄，呼叫 deploy.ps1
    Set-Location $scriptDir

    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        pwsh -ExecutionPolicy Bypass -File "deploy.ps1"
    } else {
        powershell -ExecutionPolicy Bypass -File "deploy.ps1"
    }
}
finally {
    # 🧹 切回 User Profile，確保不會因為開著暫存資料夾導致刪不掉
    Set-Location $env:USERPROFILE

    Write-Host "[*] 正在清理下載與解壓之暫存檔案..." -ForegroundColor Yellow
    if (Test-Path $tempZip) { 
        Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue 
    }
    if (Test-Path $tempExtract) { 
        Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue 
    }
    Write-Host "[+] 暫存清理完畢！" -ForegroundColor Green
}
