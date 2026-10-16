param (
    [switch]$AllUsers
)

# 取得根目錄 (script/ 的上一層)
$SCRIPT_DIR = $PSScriptRoot
$DOT_ROOT = Split-Path -Parent $SCRIPT_DIR
$WIN_HOME = $env:USERPROFILE

# ---------------------------------------------------------------------------
# 0. 權限檢查與自動 UAC 提權 (當指定 -AllUsers 且非 Admin 身份時)
# ---------------------------------------------------------------------------

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$gFlag = if ($AllUsers) { "--global" } else { $null }

if ($AllUsers -and -not$isAdmin) {
    Write-Host "[!] -AllUsers 模式需要系統管理員權限，正在嘗試提升權限 (UAC)..." -ForegroundColor Yellow
    
    $scriptPath =$MyInvocation.MyCommand.Definition
    
    # 加上 -NoExit，讓新開的系統管理員視窗不會自動關閉
    Start-Process powershell -Verb RunAs -ArgumentList "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -AllUsers"
    
    # 結束當前一般使用者的視窗
    exit
}


function Initialize-ScoopPath {
    <#
    .SYNOPSIS
        Detect existing Scoop installation or define a new target path.
    #>
    
    # 1. 如果傳入 $AllUsers，優先檢查與設定 SCOOP_GLOBAL
    if ($AllUsers) {
        $sysGlobal = [Environment]::GetEnvironmentVariable("SCOOP_GLOBAL", "Machine")
        if ($sysGlobal -and (Test-Path $sysGlobal)) {
            $global:TARGET_SCOOP = $sysGlobal
            $env:SCOOP_GLOBAL = $sysGlobal
            Write-Host "[√] Detected SCOOP_GLOBAL from Machine Environment: $global:TARGET_SCOOP" -ForegroundColor Green
            return
        }
    }

    # 2. 優先權 A: 檢查目前 Session 是否已有 $env:SCOOP 或 $env:SCOOP_GLOBAL
    if ($env:SCOOP_GLOBAL -and (Test-Path $env:SCOOP_GLOBAL)) {
        $global:TARGET_SCOOP = $env:SCOOP_GLOBAL
        Write-Host "[√] Detected Scoop (Global) from Session: $global:TARGET_SCOOP" -ForegroundColor Green
        return
    }

    if ($env:SCOOP -and (Test-Path $env:SCOOP)) {
        $global:TARGET_SCOOP = $env:SCOOP
        Write-Host "[√] Detected Scoop from current Session: $global:TARGET_SCOOP" -ForegroundColor Green
        return
    }

    # 3. 優先權 B: 檢查系統環境變數 (User/Machine Scope)
    $sysScoop = [Environment]::GetEnvironmentVariable("SCOOP", "User")
    if (!$sysScoop) { 
        $sysScoop = [Environment]::GetEnvironmentVariable("SCOOP_GLOBAL", "Machine") 
    }
    if (!$sysScoop) { 
        $sysScoop = [Environment]::GetEnvironmentVariable("SCOOP", "Machine") 
    }
    
    if ($sysScoop -and (Test-Path $sysScoop)) {
        $global:TARGET_SCOOP = $sysScoop
        $env:SCOOP = $sysScoop
        Write-Host "[√] Detected Scoop from System Environment: $global:TARGET_SCOOP" -ForegroundColor Green
        return
    }

    # 4. 優先權 C: 檢查常見的預設路徑
    $commonPaths = @(
        "D:\Scoop",
        "$env:USERPROFILE\scoop",
        "C:\Scoop"
    )
    foreach ($path in $commonPaths) {
        if (Test-Path "$path\shims\scoop.cmd") {
            $global:TARGET_SCOOP = $path
            $env:SCOOP = $path
            Write-Host "[√] Detected Scoop at common location: $global:TARGET_SCOOP" -ForegroundColor Green
            return
        }
    }

    # 5. 優先權 D: 全都找不到，定義預設目標路徑
    Write-Host "[!] No existing Scoop detected. Defining new target..." -ForegroundColor Yellow
    if (Test-Path "D:") {
        $global:TARGET_SCOOP = "D:\Scoop"
    } else {
        $global:TARGET_SCOOP = "C:\Scoop"
    }
    
    if ($AllUsers) {
        $env:SCOOP_GLOBAL = $global:TARGET_SCOOP
    } else {
        $env:SCOOP = $global:TARGET_SCOOP
    }
    Write-Host "[>] New Scoop target set to: $global:TARGET_SCOOP" -ForegroundColor Cyan
}


function Set-EnvIfChanged {
    param (
        [string]$Name,
        [string]$Value,
        [string]$Scope = "User"
    )
    # 取得目前的系統值 (不是當前 Session 的，是持久化的)
    $currentValue = [Environment]::GetEnvironmentVariable($Name, $Scope)
    
    if ($currentValue -ne $Value) {
        [Environment]::SetEnvironmentVariable($Name, $Value, $Scope)
        Write-Host "[+] Updated $Name -> $Value ($Scope)" -ForegroundColor Cyan
    } else {
        # 如果值已經一樣，就跳過，保持安靜
        Write-Host "[-] $Name is already correct." -ForegroundColor Gray
    }
    
    # 同步更新當前 Session 的環境變數，確保後續指令能立刻吃到
    $ExecutionContext.SessionState.Path.SetLocation($PWD) | Out-Null # 刷新路徑小技巧
    Set-Item -Path "Env:\$Name" -Value $Value
}

function Deploy-SSH {
    Write-Host "--- Deploy SSH config (Windows) ---" -ForegroundColor Cyan
    
    $sshDir = "$WIN_HOME\.ssh"
    $target = "$sshDir\config"
    $socketDir = "$sshDir\sockets"
    $source = "$DOT_ROOT\config\ssh\config"

    # 1. 確保 .ssh 目錄存在
    $addedDir = $false
    if (!(Test-Path $sshDir)) {
        Write-Host "Creating $sshDir..."
        New-Item -ItemType Directory -Path $sshDir
        $addedDir = $false
    }

    # 2. 確保 sockets 目錄存在 (ControlMaster 用)
    if (!(Test-Path $socketDir)) {
        Write-Host "Creating $socketDir..." -ForegroundColor Gray
        New-Item -ItemType Directory -Path $socketDir | Out-Null
        $addedDir = $true
    }
    # 3. 檢查目標是否已存在且不是 Link，如果是的話先備份
    if (Test-Path $target) {
        $item = Get-Item $target
        if ($item.Attributes -notlike "*ReparsePoint*") { # 判斷是否為 Link
            Write-Host "Backing up existing ssh config to config.bak" -ForegroundColor Yellow
            Move-Item $target "$target.bak" -Force
        }
    }

    # 4. 使用我們定義好的 New-WinLink 建立連結
    # 假設 New-WinLink 接受 (target, source) 參數

    $sourceAbs = (Get-Item $source).FullName
    New-WinLink -target $target -source $sourceAbs

    # 如果目錄是剛建的，或是你覺得保險起見想跑一次
    if ($addedDir) {
        Write-Host "Locking down SSH permissions..." -ForegroundColor Yellow
        $currentUser = "$env:COMPUTERNAME\$env:USERNAME"
        
        # 針對 sockets 目錄切斷繼承並給予完整權限
        icacls $sshDir /inheritance:r /grant "${currentUser}:(OI)(CI)F" | Out-Null
        Write-Host "✅ Permissions secured." -ForegroundColor Green
    } else {
        Write-Host "✨ Everything looks good." -ForegroundColor DarkGray
    }

}

# ==========================================================
# 🚀 系統環境優化函數 (Functions)
# ==========================================================

function Remove-MicrosoftPythonToxin {
    <#
    .SYNOPSIS
        自動清理 Windows 內建 Microsoft Store Python 假別名（毒瘤）。
    .DESCRIPTION
        此函數會物理移除 WindowsApps 底下的假 python 捷徑，並修改註冊表將其永遠關閉，
        確保系統 PATH 優先級完全回歸 Scoop 安裝的實體 Python。
    #>
    Write-Host "[*] 正在檢查並清理 Windows 內建 Python 假別名..." -ForegroundColor Yellow

    # 元凶檔案的隱藏路徑
    $aliasPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps"
    $fakePython = Join-Path $aliasPath "python.exe"
    $fakePython3 = Join-Path $aliasPath "python3.exe"

    # 1. 物理移除假捷徑
    if (Test-Path $fakePython) {
        Remove-Item $fakePython -Force -ErrorAction SilentlyContinue
        Write-Host "[√] 已物理移除假 python.exe 捷徑" -ForegroundColor Green
    }
    if (Test-Path $fakePython3) {
        Remove-Item $fakePython3 -Force -ErrorAction SilentlyContinue
        Write-Host "[√] 已物理移除假 python3.exe 捷徑" -ForegroundColor Green
    }

    # 2. 註冊表絕育 (State = 0 代表強制關閉開關)
    $executionAliasesPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\AppExecutionAlias"
    if (Test-Path $executionAliasesPath) {
        Get-ChildItem $executionAliasesPath -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -match "python" } | 
            ForEach-Object {
                Set-ItemProperty -Path $_.PSPath -Name "State" -Value 0 -ErrorAction SilentlyContinue
            }
    }
    
    Write-Host "[√] 微軟假別名環境清理完備。" -ForegroundColor Green
    Write-Host "--------------------------------------------------" -ForegroundColor Gray
}

# --- 1. 環境偵測 (Environment Detection) ---
Initialize-ScoopPath

# --- 2. 確保環境變數寫入 (Persist Variables) ---
# 只有在系統變數不對時才更新，減少對登錄表 (Registry) 的操作

# if ([Environment]::GetEnvironmentVariable('SCOOP', 'User') -ne $global:TARGET_SCOOP) {
#     Write-Host "Updating SCOOP environment variable to $TARGET_SCOOP" -ForegroundColor Cyan
#     [Environment]::SetEnvironmentVariable("SCOOP", $global:TARGET_SCOOP, "User")
# }

Write-Host "--- Windows Native Deployment ---" -ForegroundColor Cyan

# 2. 確保「當前視窗」立即吃到這個路徑 (最重要)


# 2. 統一寫入 (冪等性處理)
$CFG = "$DOT_ROOT\config"
$XDG_DATA  = "$global:TARGET_SCOOP\persist\xdg\data"
$XDG_CACHE = "$global:TARGET_SCOOP\persist\xdg\cache"


# 設定 Data 與 Cache 到 Scoop 的持久化目錄
$xdgRoot = "$TARGET_SCOOP\persist\xdg"

Set-EnvIfChanged -Name "SCOOP"           -Value $global:TARGET_SCOOP
Set-EnvIfChanged -Name "XDG_CONFIG_HOME" -Value $CFG
Set-EnvIfChanged -Name "XDG_DATA_HOME"   -Value $XDG_DATA
Set-EnvIfChanged -Name "XDG_CACHE_HOME"  -Value $XDG_CACHE

# 3. 同步當前環境
$env:XDG_CONFIG_HOME = $CFG
$env:XDG_DATA_HOME   = $XDG_DATA
$env:XDG_CACHE_HOME  = $XDG_CACHE

# [Environment]::SetEnvironmentVariable("XDG_DATA_HOME", $env:XDG_DATA_HOME, "User")
# [Environment]::SetEnvironmentVariable("XDG_CACHE_HOME", $env:XDG_CACHE_HOME, "User")



# --- 函式定義區 ---
# 
function Check-And-Install-WSL {
    Write-Host "`n--- WSL 檢查與安裝 ---" -ForegroundColor Cyan

    $wslInstalled =$false
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        $wslOutput = wsl --status 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -and$wslOutput -notmatch "REGDB_E_CLASSNOTREG") {
            $wslInstalled =$true
        }
    }

    if ($wslInstalled) {
        Write-Host "[√] WSL 已經安裝且功能正常。" -ForegroundColor Green
        return
    }

    $choice = Read-Host "[!] 偵測到尚未完全啟用 WSL，是否現在進行自動清理與安裝？ [y/N]"
    if ($choice -match 'y|Y') {
        # 動態取得當前執行的 PowerShell 完整路徑 (pwsh.exe)
        $currentPsPath = (Get-Process -Id $PID).Path

        Write-Host "[>] 正在清理可能衝突的舊版 AppX 封包並安裝 WSL (需管理員權限)..." -ForegroundColor Magenta
        
        # 1. 預先清除壞掉的 AppX 套件，確保 wsl --install 不會跳出 REGDB_E_CLASSNOTREG
        # 2. 直接執行現代化 wsl --install
        $installScript = '
            Get-AppxPackage -AllUsers MicrosoftCorporationII.WindowsSubsystemForLinux | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue;
            wsl.exe --install --no-launch;
        '

        Start-Process $currentPsPath -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$installScript`"" -Verb RunAs -Wait

        Write-Host "`n==================================================================" -ForegroundColor Yellow
        Write-Host "[!] WSL 指令已順利執行完成！" -ForegroundColor Yellow
        Write-Host "▸ 若為首次啟用系統虛擬化，請『重新啟動電腦』以完成載入。" -ForegroundColor Red
        Write-Host "▸ 重開機後，再次執行 deploy.ps1 即可通過 WSL 檢查。" -ForegroundColor Yellow
        Write-Host "==================================================================`n" -ForegroundColor Yellow
    }
}

function Setup-PowerShellEnvironment {
    param (
        [string]$ScoopPath,
        [string]$GlobalFlag
    )

    Write-Host "`n--- PowerShell 核心環境佈署 ---" -ForegroundColor Cyan

    # ================= [DEBUG] 檢查環境變數與旗標 =================
    Write-Host "========== [DEBUG] Setup-PowerShellEnv ==========" -ForegroundColor Yellow
    Write-Host "ScoopPath (傳入)   : $ScoopPath" -ForegroundColor Cyan
    Write-Host "GlobalFlag (傳入)  : '$GlobalFlag'" -ForegroundColor Cyan
    Write-Host "env:SCOOP          : '$env:SCOOP'" -ForegroundColor Cyan
    Write-Host "env:SCOOP_GLOBAL   : '$env:SCOOP_GLOBAL'" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Yellow
    # ===============================================================


    if ($GlobalFlag) {
        # $env:SCOOP =$null
        # [Environment]::SetEnvironmentVariable("SCOOP", $null, "User")
        # Remove-Item Env:\SCOOP -ErrorAction SilentlyContinue
    }

    
    if (!(scoop bucket list | Select-String "main")) {
        Write-Host "Adding main bucket..."
        & scoop bucket add main
    }
    
    $scoopPwsh = Join-Path $ScoopPath "apps\pwsh\current\pwsh.exe"
    $wingetPwsh = Get-Command pwsh -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -like "*Program Files\PowerShell*" }

    if ($wingetPwsh) {
        Write-Host "[!] 偵測到 Program Files 中的 Winget 版 PowerShell。" -ForegroundColor Yellow
        $choice = Read-Host "是否嘗試以管理員權限移除 Winget 版以統一管理？ [y/N]"
        if ($choice -eq 'y') {
            # 啟動獨立的管理員進程進行卸載，避免鎖定目前腳本
            Write-Host "正在要求管理員權限進行移除..." -ForegroundColor Magenta
            Start-Process winget -ArgumentList "uninstall --id Microsoft.PowerShell --silent" -Verb RunAs -Wait
        }
    }

    if (!(Test-Path $scoopPwsh)) {
        Write-Host "[!] Installing PowerShell 7 via Scoop..." -ForegroundColor Yellow
        # 這裡必須用 powershell，因為這是 scoop install 的正確名稱
        & scoop install pwsh $gFlag
    } else {
        Write-Host "[√] Scoop 版 PowerShell 7 已安裝。" -ForegroundColor Green
        cmd /c "powershell -NoProfile -ExecutionPolicy Bypass -Command `"scoop update pwsh`""
    }

    # 處理 PSReadLine
    if (!(Get-Module -ListAvailable PSReadLine)) {
        Write-Host "正在安裝 PSReadLine..." -ForegroundColor Yellow
        Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Module -Name PSReadLine -Force -AllowClobber -Scope CurrentUser -SkipPublisherCheck
    }

    $terminalSettings = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"

    if (Test-Path $terminalSettings) {
        try {
            # 使用 UTF8 編碼讀取以防亂碼
            $settingsContent = Get-Content $terminalSettings -Raw -Encoding UTF8
            $settings = $settingsContent | ConvertFrom-Json
            
            $targetPath = "$TARGET_SCOOP\apps\pwsh\current\pwsh.exe"
            $modified = $false

            foreach ($profile in $settings.profiles.list) {
                # 針對名稱為 PowerShell 或 pwsh 的 profile 進行處理
                if ($profile.name -eq "PowerShell" -or $profile.name -eq "pwsh") {
                    # 使用 PSObject 來動態處理屬性，避免 "找不到屬性" 的例外
                    if ($null -eq $profile.commandline) {
                        $profile | Add-Member -MemberType NoteProperty -Name "commandline" -Value $targetPath -Force
                    } else {
                        $profile.commandline = $targetPath
                    }
                    $modified = $true
                }
            }

            if ($modified) {
                # 轉回 JSON 並存檔，確保深度夠深以免資料遺失
                $settings | ConvertTo-Json -Depth 10 | Set-Content $terminalSettings -Encoding UTF8
                Write-Host "[√] 已成功更新 Windows Terminal 預設路徑至 $targetPath" -ForegroundColor Green
            }
        } catch {
            Write-Host "[!] 更新 Windows Terminal 設定時發生錯誤: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    # --- 4. 關鍵轉折：如果你還在 5.1，強制切換到 7 ---
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Host "`n[!] Environment ready. Switching to PowerShell 7 for deployment..." -ForegroundColor Green
        
        # 1. 組合要傳遞的 ArgumentList 字串
        $argList = if ($AllUsers) {
            "-NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`" -AllUsers"
        } else {
            "-NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        }

        # 2. Debug 用：印出呼叫路徑與完整參數字串
        Write-Host "================ [DEBUG] Start-Process ==================" -ForegroundColor Yellow
        Write-Host "Target Executable : $scoopPwsh" -ForegroundColor Cyan
        Write-Host "ArgumentList      : $argList" -ForegroundColor Cyan
        Write-Host "=========================================================" -ForegroundColor Yellow

        # 3. 檢查 $scoopPwsh 執行檔是否存在，避免盲目重啟
        if (!(Test-Path $scoopPwsh)) {
            Write-Host "[!] 錯誤：找不到 PowerShell 7 執行檔路徑: $scoopPwsh" -ForegroundColor Red
            return
        }

        # 4. 啟動新進程
        Start-Process "$scoopPwsh" -ArgumentList $argList
        exit
    }
}

function New-WinLink {
    param($target, $source)
    
    # 1. 檢查目標是否已存在
    if (Test-Path $target) { 
        # 如果已經正確連結了，就跳過
        if ((Get-Item $target).LinkType -eq "SymbolicLink" -and (Get-Item $target).Target -eq $source) {
            Write-Host "Link already correct: $target" -ForegroundColor Gray
            return
        }
        Remove-Item $target -Force -ErrorAction SilentlyContinue
    }

    # 2. 確保父目錄存在
    $parent = Split-Path $target
    if (!(Test-Path $parent)) { New-Item -ItemType Directory -Path $parent }

    # 3. 執行 mklink
    # 我們嘗試直接執行，如果失敗則嘗試提權執行
    try {
        $mode = if (Test-Path $source -PathType Container) { "/D" } else { "" }
        cmd /c "mklink $mode `"$target`" `"$source`"" 2>$null
        
        if (!$?) { throw "Standard link failed" }
    } catch {
        Write-Host "Requesting Admin privileges for mklink..." -ForegroundColor Yellow
        # 提權執行 cmd 來跑 mklink
        #Start-Process cmd -ArgumentList "/c mklink $mode `"$target`" `"$source`" & pause" -Verb RunAs -Wait
        Start-Process cmd -ArgumentList "/c mklink $mode `"$target`" `"$source`" " -Verb RunAs -Wait
    }
}

# --- 執行流程 ---


# 定義目標 Scoop 路徑
$TARGET_SHIMS = "$TARGET_SCOOP\shims"

$isFreshScoopInstall =$false

# 1. 如果沒安裝 Scoop 則安裝 (原本的邏輯)
if (!(Get-Command scoop -ErrorAction SilentlyContinue)) {
    Write-Host "[!] 未偵測到 Scoop，準備開始全新安裝..." -ForegroundColor Yellow
    $isFreshScoopInstall = $true

    if ($AllUsers) {
        Write-Host "[>] 以 AllUsers (Global) 模式全域安裝 Scoop 至: $global:TARGET_SCOOP" -ForegroundColor Cyan

        # 1. 設定 Machine 全域環境變數
        [Environment]::SetEnvironmentVariable("SCOOP_GLOBAL", $global:TARGET_SCOOP, "Machine")
        $env:SCOOP_GLOBAL = $global:TARGET_SCOOP

        # 2. 允許 Admin 執行安裝腳本，並指定 -GlobalPath
        $installScript = [scriptblock]::Create((Invoke-RestMethod -Uri 'https://get.scoop.sh'))
        & $installScript -RunAsAdmin -GlobalPath "$env:SCOOP_GLOBAL"

        # 3. 抹除 installer 自動寫入 User 註冊表的 SCOOP 變數 (避免雙重掃描)
        [Environment]::SetEnvironmentVariable("SCOOP", $null, "User")
        Remove-Item Env:\SCOOP -ErrorAction SilentlyContinue
        
    } else {
        Write-Host "[>] 以 User 個人模式安裝 Scoop 至: $global:TARGET_SCOOP" -ForegroundColor Cyan
        $env:SCOOP = $global:TARGET_SCOOP
        
        # 個人模式（非 Admin 執行）：
        iwr -useb get.scoop.sh | iex
    }
} else {    
    Write-Host "[√] 偵測到 Scoop 已存在。" -ForegroundColor Green
}




# ==========================================================
# 雙重路徑 dotfiles 部署與保存檢查邏輯
# ==========================================================

$targetScoopDotfiles = Join-Path $TARGET_SCOOP "etc\dotfiles"
$targetUserDotfiles  = "$env:USERPROFILE\.dotfiles"
$currentDotfilesDir  = (Get-Item $PSScriptRoot).Parent.FullName

# 共用的「複製並重新執行」函數
function Invoke-MigrateAndRestart($destDir) {
    Write-Host "[>] 正在將 dotfiles 複製/同步至 $destDir..." -ForegroundColor Cyan
    
    # 1. 確保目標根目錄本身存在
    if (!(Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    # 2. 如果要清空舊的再覆蓋，注意：不能直接 Remove-Item 整個 $destDir 否則剛建好的會被刪掉
    # 我們改為清空 $destDir 底下的所有檔案與資料夾
    if (Test-Path $destDir) {
        Get-ChildItem -Path $destDir -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 3. 關鍵修正：在來源路徑結尾加上 "\*"，代表「複製該資料夾內的所有內容」
    # 這樣不管來源叫 dotfiles-main 還是 dotfiles-test，內容都會直接平鋪倒進 $destDir 裡面
    $sourceFilesPattern = Join-Path $currentDotfilesDir "*"
    Copy-Item -Path $sourceFilesPattern -Destination $destDir -Recurse -Force

    $newDeployScriptPath = Join-Path $destDir "scripts\deploy.ps1"

    Write-Host "`n==================================================================" -ForegroundColor Green
    Write-Host "[√] dotfiles 已成功部署至: $destDir" -ForegroundColor Green
    Write-Host "==================================================================`n" -ForegroundColor Green

    # 同步環境變數並無縫重啟新路徑下的 deploy.ps1
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"

    $env:SCOOP = [System.Environment]::GetEnvironmentVariable('SCOOP', 'User')
    $env:SCOOP_GLOBAL = [System.Environment]::GetEnvironmentVariable('SCOOP_GLOBAL', 'Machine')

    $newScriptDir = Split-Path -Parent $newDeployScriptPath
                
    Write-Host "[*] 正在無縫切換至新環境並繼續佈署..." -ForegroundColor Cyan

    $argList = @(
        "-NoExit",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$newDeployScriptPath`""
    )

    if ($AllUsers) {$argList += "-AllUsers" }

    $shellCommand = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    
    Start-Process $shellCommand -ArgumentList $argList -WorkingDirectory $newScriptDir -Wait
    exit
}
# ----------------------------------------------------------
# 步驟 1：先檢查 Scoop 目錄 ($TARGET_SCOOP\etc\dotfiles)
# ----------------------------------------------------------
$proceedToUserCheck =$false

if ($currentDotfilesDir -ne $targetScoopDotfiles) {
    if (!(Test-Path $targetScoopDotfiles)) {
        # 不存在：直接 copy 並 run 新的 ps1
        Write-Host "[!] Scoop 目錄下尚未建立 dotfiles，準備自動複製..." -ForegroundColor Yellow
        Invoke-MigrateAndRestart $targetScoopDotfiles
    } else {
        # 存在：問要不要蓋過去
        Write-Host "[!] 偵測到 Scoop 目錄下已存在 dotfiles ($targetScoopDotfiles)。" -ForegroundColor Yellow
        $choice = Read-Host "是否要覆蓋現有的 dotfiles 並從該處執行？ (y/N)"
        if ($choice -match '^[yY]') {
            Invoke-MigrateAndRestart $targetScoopDotfiles
        } else {
            # 選 no，才改查看 $env:USERPROFILE\.dotfiles
            Write-Host "[-] 已選擇略過 Scoop 目錄，改檢查使用者家目錄..." -ForegroundColor Cyan
            $proceedToUserCheck = $true
        }
    }
} else {
    # 如果本來就是從 Scoop 目錄跑進來的，直接往下執行正式部署
    $proceedToUserCheck =$false
}

# ----------------------------------------------------------
# 步驟 2：若 Scoop 檢查選擇 no，改查看 $env:USERPROFILE\.dotfiles
# ----------------------------------------------------------
if ($proceedToUserCheck -and ($currentDotfilesDir -ne $targetUserDotfiles)) {
    if (Test-Path $targetUserDotfiles) {
        # 新目錄存在，提示存在並問要不要蓋過去
        Write-Host "[!] 偵測到使用者目錄下已存在 dotfiles ($targetUserDotfiles)。" -ForegroundColor Yellow
        $choice = Read-Host "是否要覆蓋現有的 dotfiles 並從該處執行？ (y/N)"
        if ($choice -match '^[yY]') {
            Invoke-MigrateAndRestart $targetUserDotfiles
        } else {
            Write-Host "[-] 已取消覆蓋。腳本終止。" -ForegroundColor Red
            exit
        }
    } else {
        # 不存在，提示要不要 copy 過去
        Write-Host "[!] 偵測到使用者目錄尚未建立 dotfiles ($targetUserDotfiles)。" -ForegroundColor Yellow
        $choice = Read-Host "是否要將 dotfiles 複製過去並從該處執行？ (y/N)"
        if ($choice -match '^[yY]') {
            Invoke-MigrateAndRestart $targetUserDotfiles
        } else {
            Write-Host "[-] 已取消。腳本終止。" -ForegroundColor Red
            exit
        }
    }
}


if (!(Test-Path "$xdgRoot")) { New-Item -ItemType Directory -Path "$xdgRoot" -Force }

# 2. 不論是否新安裝，一律檢查並優化 PATH 順序
Write-Host "Checking PATH order for OpenSSH..." -ForegroundColor Cyan

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")

# 檢查 Scoop Shims 是否已經在最前面
if ($userPath.StartsWith("$TARGET_SHIMS;")) {
    Write-Host "[√] Scoop Shims 已經在 PATH 最優先位置。" -ForegroundColor Green
} else {
    Write-Host "Scoop 順序不正確，正在調整..." -ForegroundColor Yellow
    
    # 先把舊的 Scoop 路徑移掉（如果有的話），再把新路徑塞到最前面
    $paths = $userPath.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
    $filteredPaths = $paths | Where-Object { $_ -ne $TARGET_SHIMS }
    $newPath = "$TARGET_SHIMS;" + ($filteredPaths -join ";")
    
    # 寫回環境變數
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    
    # 立即更新當前 Session，這樣不用重新開機也能在腳本後續使用
    $env:PATH = "$TARGET_SHIMS;" + $env:PATH
    
    Write-Host "[√] 已將 Scoop Shims 提升至 PATH 最優先級。" -ForegroundColor Green
    Write-Host "請重新啟動 WezTerm 以確保 ssh 指令指向正確版本。" -ForegroundColor Cyan
}


# # 4. 現在跑安裝，它百分之百會吃到 $env:SCOOP
# if (!(Get-Command scoop -ErrorAction SilentlyContinue)) {
#     Write-Host "Installing Scoop..." -ForegroundColor Yellow
#     iwr -useb get.scoop.sh | iex
#     # 立即更新當前 Session 的 PATH，否則接下來的 scoop 指令會找不到
#     $env:PATH += ";$TARGET_SCOOP\shims"
#     $oldPath = [Environment]::GetEnvironmentVariable("Path", "User")
#     if ($oldPath -notlike "*$TARGET_SCOOP\shims*") {
#         $newPath = "$TARGET_SCOOP\shims;" + $oldPath
#         [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
#         Write-Host "[√] 已將 Scoop Shims 提升至 PATH 最優先級。" -ForegroundColor Green
#     }
# }

# --- 從這裡開始，就是 PowerShell 7 的世界了 ---

if ($AllUsers) {
    # [Environment]::SetEnvironmentVariable("SCOOP_GLOBAL", $global:TARGET_SCOOP, "Machine")
    # [Environment]::SetEnvironmentVariable("SCOOP", $null, "User")

    # # 確保當前 Session 也清掉 $env:SCOOP，強制後續所有 scoop 指令改走 -g / SCOOP_GLOBAL
    # $env:SCOOP = $null
    # Remove-Item Env:\SCOOP -ErrorAction SilentlyContinue
}

Setup-PowerShellEnvironment -ScoopPath $TARGET_SCOOP -GlobalFlag $gFlag

Write-Host "`n--- Starting Full Deployment ---" -ForegroundColor Green
Check-And-Install-WSL


# --- 1. 基礎工具 (沒有它們，後面都動不了) ---
$core_apps = @("git", "7zip")

# 1. 顯示當前 $gFlag 與權限狀態
Write-Host "================ [DEBUG INFO] ================" -ForegroundColor Cyan
Write-Host "AllUsers 模式: $AllUsers" -ForegroundColor Yellow
Write-Host "gFlag 變數值: '$gFlag' (長度: $($gFlag.Length))" -ForegroundColor Yellow
Write-Host "==============================================" -ForegroundColor Cyan


foreach ($app in $core_apps) {
    # 檢查 Get-Command 抓到的實體路徑
    $cmdCheck = Get-Command $app -ErrorAction SilentlyContinue
    
    if ($cmdCheck) {
        Write-Host "[DEBUG] $app 已存在，來源路徑: $($cmdCheck.Source)" -ForegroundColor Gray
    } else {
        Write-Host "[DEBUG] 準備安裝 $app..." -ForegroundColor Magenta
        
        # 2. 印出即將執行的完整指令
        if ($gFlag) {
            Write-Host "[EXEC] 執行指令: scoop install $app $gFlag" -ForegroundColor Green
            & scoop install $app $gFlag
        } else {
            Write-Host "[EXEC] 執行指令: scoop install $app (Single User)" -ForegroundColor Green
            & scoop install $app
        }
        
        # 驗證執行結果
        Write-Host "----------------------------------------------" -ForegroundColor DarkGray
    }
}


$scoopRoot = $env:SCOOP
if ([string]::IsNullOrEmpty($scoopRoot)) {
    $scoopShim = (Get-Command scoop -ErrorAction SilentlyContinue).Source
    if ($scoopShim) {
        # 從 shims 資料夾往上推導兩層找到 Scoop 根目錄
        $scoopRoot = Split-Path -Parent (Split-Path -Parent $scoopShim)
    } else {
        $scoopRoot = "C:\Scoop"
    }
}

$required_buckets = @{
    "extras"             = $null
    "nerd-fonts"         = "https://github.com/matthewjberger/scoop-nerd-fonts"
    "sarasa-nerd-fonts"  = "https://github.com/jonz94/scoop-sarasa-nerd-fonts"
    "fonts"              = "https://github.com/gh0stzk/dotfiles.git"
}

foreach ($bucket in $required_buckets.Keys) {
    # 組合出該 bucket 的正確資料夾路徑
    $bucketDir = Join-Path $scoopRoot "buckets\$bucket"
    
    # 防禦機制：如果資料夾存在但不是合法的 git repository，強制砍掉重建
    if ((Test-Path $bucketDir) -and !(Test-Path (Join-Path $bucketDir ".git"))) {
        Write-Host "[!] 發現損壞的 Bucket ($bucket)，正在清除並重新建立..." -ForegroundColor Yellow
        Remove-Item -Path $bucketDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($installedBuckets -notcontains $bucket -or !(Test-Path (Join-Path $bucketDir ".git"))) {
        Write-Host "[*] 正在新增 Scoop Bucket: $bucket" -ForegroundColor Cyan
        
        $bucketArgs = @('bucket', 'add', $bucket)
        $url = $required_buckets[$bucket]
        if ($url) {
            $bucketArgs += $url
        }
        if ($gFlag) {
            $bucketArgs += $gFlag
        }
        
        & scoop @bucketArgs
    } else {
        Write-Host "[+] Bucket '$bucket' 已存在且正常，跳過。" -ForegroundColor Gray
    }
}

Write-Host "[*] 正在更新 Scoop 本地清單與快取..." -ForegroundColor Cyan
# 關鍵：新增完 bucket 後，強制更新本地 Scoop 清單與快取，確保抓得到新 manifest
scoop cleanup *
& scoop update


# 2. 軟體安裝
$apps = @(
    "openssh", "starship", "zoxide", "fzf", "yazi", 
    "eza", "bat", "fd", "ripgrep", "neovim",
    "ffmpeg", "jq", "poppler", "resvg", "imagemagick",
    "gh", "sublime-text", "wezterm", "JetBrainsMono-NF", 
    "sarasa-nerd-font-ttc", "lazygit", "posh-git", "delta",
    "fastfetch", "fnm", "python", "tree-sitter", "zig",
    "stylua"
)
#"sarasa-gothic"  #這個會小很多

Remove-MicrosoftPythonToxin
$installedApps = scoop list | Out-String

foreach ($app in $apps) {
    # 透過 scoop list 判斷套件是否已安裝，對 Font 和非 CLI 工具同樣有效
    if ($installedApps -notmatch "(?m)^\s*$app\s+") {
        Write-Host "Installing $app via Scoop..." -ForegroundColor Cyan
        scoop install $app $gFlag
    } else {
        Write-Host "$app is already installed." -ForegroundColor Gray
    }
}



if (Get-Command fnm -ErrorAction SilentlyContinue) {
    Write-Host "[*] Configuring fnm and checking Node.js LTS..." -ForegroundColor Yellow
    
    # 臨時讓當前 Session 可以踩到 fnm 環境變數
    & fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression
    
    # 下載並將 LTS 設為全域預設
    & fnm install --lts
    & fnm default lts-latest     # 🎯 關鍵修正：將 lts 改為 lts-latest
    & fnm use default
    Write-Host "[√] Windows Node.js via fnm is ready!" -ForegroundColor Green
}

echo "Checking git submodules..."
git submodule update --init --recursive

# --- 連結建立區 ---

# 1. Git Config
$sourceAbs = (Get-Item "$DOT_ROOT\git\.gitconfig").FullName
New-WinLink -target "$WIN_HOME\.gitconfig" -source $sourceAbs
$sourceAbs = (Get-Item "$DOT_ROOT\git\.gitignore.global").FullName
New-WinLink -target "$WIN_HOME\.gitignore.global" -source $sourceAbs
$sourceAbs = (Get-Item "$DOT_ROOT\git\.gitconfig.shared").FullName
New-WinLink -target "$WIN_HOME\.gitconfig.shared" -source $sourceAbs
$sourceAbs = (Get-Item "$DOT_ROOT\git\.gitattributes").FullName
New-WinLink -target "$WIN_HOME\.gitattributes" -source $sourceAbs

Deploy-SSH

# 在 Windows 的 deploy.ps1 執行
$localFile = "$WIN_HOME\.gitconfig.local"
$currentScoop = $global:TARGET_SCOOP.Replace('\', '/')

$localContent = @"
[safe]
    directory = $currentScoop/etc/dotfiles
[credential]
    helper = manager
"@

# 只有內容不同才寫入
if (!(Test-Path $localFile) -or (Get-Content $localFile -Raw) -ne $localContent) {
    $localContent | Set-Content -Path $localFile -Encoding utf8

}
# 只有內容不同才寫入
# --- 然後維持你原本的 Link 邏輯 ---

# 2. Starship Config (指向 .config 目錄)
# 1. 定義路徑
$starshipThemeDir = "$DOT_ROOT\config\starship\themes"
$winSpecificConfig = "$starshipThemeDir\starship.toml.win"
$templateConfig = "$starshipThemeDir\template-win.toml"  # 你的預設範本
$targetConfig = "$WIN_HOME\.config\starship.toml"

# 2. 如果 Windows 專用檔不存在，從範本拷貝一份 (cp 邏輯)
if (!(Test-Path $winSpecificConfig)) {
    if (Test-Path $templateConfig) {
        Write-Host "Creating Windows specific starship config from template..." -ForegroundColor Cyan
        Copy-Item -Path $templateConfig -Destination $winSpecificConfig
    } else {
        Write-Warning "Template $templateConfig not found!"
    }
}

# 3. 執行 New-WinLink (這會用到你之前寫的那個處理 mklink 的函式)
if (Test-Path $winSpecificConfig) {
    # 取得絕對路徑以確保 New-WinLink 運作正常
    $sourceAbs = (Get-Item $winSpecificConfig).FullName
    New-WinLink -target $targetConfig -source $sourceAbs
}

$sourceAbs = (Get-Item "$DOT_ROOT\config\lazygit\config.yml").FullName
$target = "$env:APPDATA\lazygit\config.yml"

New-WinLink -target "$target" -source $sourceAbs

# 3. Yazi (使用 Junction 跨磁碟)
$yaziTarget = "$env:AppData\yazi\config"
$yaziSource = "$DOT_ROOT\config\yazi"

if (Test-Path $yaziTarget) {
    $item = Get-Item $yaziTarget
    if ($item.LinkType -ne "Junction" -or $item.Target -ne $yaziSource) {
        Remove-Item $yaziTarget -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Junction -Path $yaziTarget -Value $yaziSource | Out-Null
        Write-Host "[√] Yazi junction recreated." -ForegroundColor Green
    } else {
        Write-Host "Yazi junction already correct." -ForegroundColor Gray
    }
} else {
    $parent = Split-Path $yaziTarget
    if (!(Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force }
    New-Item -ItemType Junction -Path $yaziTarget -Value $yaziSource | Out-Null
    Write-Host "[√] Yazi junction created." -ForegroundColor Green
}

# 4. Sublime Text (使用 New-WinLink 呼叫 mklink - 根據 $AllUsers 動態切換路徑)
Write-Host "`n--- 設定 Sublime Text 軟連結與 Package Control ---" -ForegroundColor Cyan

# 根據是否開啟 AllUsers 決定 Target 與 Package Control 的下載路徑
if ($AllUsers) {
    # 多使用者模式：切換至當前使用者的 %APPDATA% 進行隔離
    $sublimeTarget      = "$env:APPDATA\Sublime Text\Packages\User"
    $sublimePackagesDir = Split-Path $sublimeTarget -Parent
    $installedPkgsDir   = "$env:APPDATA\Sublime Text\Installed Packages"
    Write-Host "[>] 檢測到 AllUsers 模式，Sublime Text 將目標設為使用者隔離路徑 (%APPDATA%)..." -ForegroundColor Yellow
} else {
    # 單一使用者模式：維持原本的 Scoop Persist 共享/便攜路徑
    $sublimeTarget      = "$TARGET_SCOOP\persist\sublime-text\Data\Packages\User"
    $sublimePackagesDir = Split-Path $sublimeTarget -Parent
    $installedPkgsDir   = "$TARGET_SCOOP\persist\sublime-text\Data\Installed Packages"
    Write-Host "[>] 檢測到 Single-User 模式，Sublime Text 目標設為 Scoop Persist 路徑..." -ForegroundColor Cyan
}

$sublimeSource = "$DOT_ROOT\sublime\User"
$pcPackagePath = Join-Path $installedPkgsDir "Package Control.sublime-package"

# 1. 確保 Target 父目錄存在並建立 Symlink
if (Test-Path $sublimeSource) {
    if (-not (Test-Path $sublimePackagesDir)) {
        New-Item -ItemType Directory -Path $sublimePackagesDir -Force | Out-Null
    }

    if (Test-Path $sublimeTarget) {
        $item = Get-Item $sublimeTarget
        if (-not ($item.Attributes -match "ReparsePoint")) {
            Remove-Item -Path $sublimeTarget -Recurse -Force
        }
    }

    New-WinLink -target "$sublimeTarget" -source "$sublimeSource"
    Unblock-File -Path $sublimeSource -ErrorAction SilentlyContinue
    Unblock-File -Path $sublimeTarget -ErrorAction SilentlyContinue
    Write-Host "[√] Sublime Text User 設定檔 Symlink 連結完成 ($sublimeTarget)。" -ForegroundColor Green
}

# 2. 自動補上 Package Control 核心檔
$sublimePersistData = Join-Path $env:SCOOP "persist\sublime-text\Data"
$installedPkgsDir = Join-Path $sublimePersistData "Installed Packages"
$pcPackagePath = Join-Path $installedPkgsDir "Package Control.sublime-package"

Write-Host "[>] 正在檢查 Sublime Text Package Control..." -ForegroundColor Cyan
if (!(Test-Path $installedPkgsDir)) {
    New-Item -ItemType Directory -Path $installedPkgsDir -Force | Out-Null
}

if (!(Test-Path $pcPackagePath)) {
    Write-Host "[>] 正在下載 Package Control..." -ForegroundColor Cyan
    $pcUrl = "https://packagecontrol.io/Package%20Control.sublime-package"
    
    Invoke-WebRequest -Uri $pcUrl -OutFile $pcPackagePath -UseBasicParsing
    
    # 針對 Python 3.14 的 semver.py 語法相容性進行自動修復
    # 因為 Package Control 官方包內的 semver.py 在 Python 3.14 會觸發 re.PatternError
    Write-Host "[>] 正在修正 Package Control 與 Python 3.14 的相容性..." -ForegroundColor Cyan
    $pyFixCode = @"
import zipfile, os, tempfile, re

pkg_path = r'$pcPackagePath'
temp_dir = tempfile.mkdtemp()

with zipfile.ZipFile(pkg_path, 'r') as zip_ref:
    zip_ref.extractall(temp_dir)

semver_file = os.path.join(temp_dir, 'package_control', 'semver.py')
if os.path.exists(semver_file):
    with open(semver_file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # 修復 Python 3.14 嚴格的 regex global flags 語法
    # 將(?i)等旗標移到最前面或調整格式
    new_content = re.sub(r'\(\?([iLmsux])\)', r'', content) # 簡單移除或依需求調整
    with open(semver_file, 'w', encoding='utf-8') as f:
        f.write(new_content)

with zipfile.ZipFile(pkg_path, 'w', zipfile.ZIP_DEFLATED) as zip_ref:
    for folder_name, subfolders, filenames in os.walk(temp_dir):
        for filename in filenames:
            file_path = os.path.join(folder_name, filename)
            arcname = os.path.relpath(file_path, temp_dir)
            zip_ref.write(file_path, arcname)
print('Package Control Patched for Python 3.14!')
"@
    python -c $pyFixCode 2>&1 | Out-Null
    Write-Host "[√] Package Control 部署與相容性修復完成！" -ForegroundColor Green
} else {
    Write-Host "[√] Package Control 已存在，跳過下載。" -ForegroundColor Gray
}

# 5. WezTerm (Windows 特供 Link)
$wezSource = "$CFG\wezterm\wezterm.lua"
$wezTarget = "$WIN_HOME\.wezterm.lua"
#New-WinLink -target $wezTarget -source $wezSource
# 替代方案：直接告訴 WezTerm 你的設定檔在哪
# 

# [Environment]::SetEnvironmentVariable("WEZTERM_CONFIG_FILE", "$CFG\wezterm\wezterm.lua", "User")
Set-EnvIfChanged -Name "WEZTERM_CONFIG_FILE" -Value "$CFG\wezterm\wezterm.lua"

# 讓 fzf 使用 fd 來搜尋檔案，這樣會自動過濾掉被 git 忽略的內容
$env:FZF_DEFAULT_COMMAND = 'fd --type f --strip-cwd-prefix --hidden --follow --exclude .git'
# [Environment]::SetEnvironmentVariable("FZF_DEFAULT_COMMAND", $env:FZF_DEFAULT_COMMAND, "User")
Set-EnvIfChanged -Name "FZF_DEFAULT_COMMAND" -Value $env:FZF_DEFAULT_COMMAND


# 4. 呼叫字型安裝
#& "$SCRIPT_DIR\install_fonts.ps1"
# 
# # --- 6. PowerShell Profile Link ---

# 定義來源 (你的 dotfiles 路徑)

# 建議修改方式：加入 -ErrorAction SilentlyContinue 遮蔽這個非必要的覆蓋警告
# 如果是全機模式 ($gFlag 存在或為真)，才去設定 LocalMachine 
if ($gFlag) {
    # Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
}
# 單人模式或全機模式都可以設定 CurrentUser
# Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

$psProfileSource = "$DOT_ROOT\windows\powershell.ps1"

# 定義目標 (pwsh v7+ 的標準 profile 路徑)
$psProfileDir = "$WIN_HOME\Documents\PowerShell"
$psProfileTarget = "$psProfileDir\Microsoft.PowerShell_profile.ps1"

if (-not (Test-Path $psProfileDir)) {
    New-Item -ItemType Directory -Path $psProfileDir -Force | Out-Null
}

New-WinLink -target "$psProfileTarget" -source "$psProfileSource"

Unblock-File -Path $psProfileSource -ErrorAction SilentlyContinue
Unblock-File -Path $psProfileTarget -ErrorAction SilentlyContinue

Write-Host "Windows deployment completed successfully!" -ForegroundColor Green


function Set-WinTerminalDefaultToPwsh {
    Write-Host "`n--- 設定預設終端機頁籤 ---" -ForegroundColor Cyan

    # 1. 檢查系統中是否有安裝 pwsh
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwshCmd) {
        Write-Host "[!] 尚未安裝 pwsh，跳過預設終端機設定。" -ForegroundColor Yellow
        return
    }

    $pwshExecutable = $pwshCmd.Source

    # 2. 檢查 Windows Terminal 設定檔是否存在
    $wtSettings = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    if (-not (Test-Path $wtSettings)) {
        Write-Host "[!] 找不到 Windows Terminal 設定檔，跳過設定。" -ForegroundColor Yellow
        return
    }

    try {
        $json = Get-Content $wtSettings -Raw | ConvertFrom-Json

        # 3. 擴大搜尋條件：比對 commandline、source 或 name (區分 PowerShell 7 與預設的 Windows PowerShell)
        $pwshProfile = $json.profiles.list | Where-Object { 
            ($_.commandline -and $_.commandline -like "*pwsh*") -or 
            ($_.source -and $_.source -like "*PowershellCore*") -or
            ($_.name -eq "PowerShell" -and $_.source -like "*PowershellCore*") -or
            ($_.name -like "*PowerShell 7*") -or
            ($_.name -eq "pwsh")
        } | Select-Object -First 1

        # 4. 若設定檔中完全找不到 pwsh profile，自動新增一組進去
        if (-not $pwshProfile) {
            Write-Host "[>] 在 Windows Terminal 中未找到 pwsh Profile，正在自動新增..." -ForegroundColor Cyan
            $newGuid = "{" + [Guid]::NewGuid().ToString() + "}"
            $pwshProfile = [PSCustomObject]@{
                guid        = $newGuid
                name        = "PowerShell 7 (pwsh)"
                commandline = $pwshExecutable
                hidden      = $false
            }
            
            # 加入 profiles.list
            $json.profiles.list += $pwshProfile
        }

        # 5. 判斷與設定預設 Profile GUID
        if ($json.defaultProfile -eq $pwshProfile.guid) {
            Write-Host "[√] Windows Terminal 預設終端機已是 pwsh，無需修改。" -ForegroundColor Green
        } else {
            $json.defaultProfile = $pwshProfile.guid
            $json | ConvertTo-Json -Depth 32 | Set-Content $wtSettings -Encoding utf8
            Write-Host "[√] 已成功將 Windows Terminal 預設終端機改為 pwsh！" -ForegroundColor Green
        }
    } catch {
        Write-Host "[!] 修改 Windows Terminal 設定時發生例外: $_" -ForegroundColor Red
    }
}

# 在 deploy.ps1 中呼叫
Set-WinTerminalDefaultToPwsh


