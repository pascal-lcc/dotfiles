<#
.SYNOPSIS
    Automated RDP Wrapper installation and latest rdpwrap.ini update script.
#>

# 1. Ensure running as Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] This script requires Administrator privileges. Relaunching..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$ErrorActionPreference = "Stop"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " Installing RDP Wrapper & Updating INI" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$tempDir = "$env:TEMP\RDPWrapInstall"
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    # 2. Download RDPWrap v1.6.2 ZIP
    $zipUrl = "https://github.com/stascorp/rdpwrap/releases/download/v1.6.2/RDPWrap-v1.6.2.zip"
    $zipPath = "$tempDir\RDPWrap.zip"
    
    Write-Host "[*] Downloading RDP Wrapper v1.6.2..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath

    Write-Host "[*] Extracting files..." -ForegroundColor Yellow
    Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force

    # 3. Download latest rdpwrap.ini
    $iniUrl = "https://raw.githubusercontent.com/sebaxakerhtc/rdpwrap.ini/master/rdpwrap.ini"
    $iniPath = "$tempDir\rdpwrap.ini"
    
    Write-Host "[*] Fetching latest rdpwrap.ini..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $iniUrl -OutFile $iniPath

    # 4. Run installer (RDPWInst.exe -i)
    $rdpWInstExe = "$tempDir\RDPWInst.exe"
    if (Test-Path $rdpWInstExe) {
        Write-Host "[*] Running RDP Wrapper installer..." -ForegroundColor Yellow
        Start-Process -FilePath $rdpWInstExe -ArgumentList "-i" -Wait -NoNewWindow
    } else {
        throw "RDPWInst.exe not found in extracted files."
    }

    # 5. Copy rdpwrap.ini to target directory
    $targetDir = "$env:ProgramFiles\RDP Wrapper"
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    Write-Host "[*] Applying latest rdpwrap.ini..." -ForegroundColor Yellow
    Copy-Item -Path $iniPath -Destination "$targetDir\rdpwrap.ini" -Force

    # 6. Restart TermService
    Write-Host "[*] Restarting TermService..." -ForegroundColor Yellow
    Restart-Service -Name TermService -Force

    Write-Host "[+] RDP Wrapper installation completed successfully!" -ForegroundColor Green

} catch {
    Write-Host "[!] Error occurred during installation: $_" -ForegroundColor Red
} finally {
    # 7. Cleanup temp folder
    if (Test-Path $tempDir) {
        Remove-Item $tempDir -Recurse -Force
    }
}
