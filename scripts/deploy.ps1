# 取得根目錄 (script/ 的上一層)
$SCRIPT_DIR = $PSScriptRoot
$DOT_ROOT = Split-Path -Parent $SCRIPT_DIR
$WIN_HOME = $env:USERPROFILE


function Initialize-ScoopPath {
    <#
    .SYNOPSIS
        Detect existing Scoop installation or define a new target path.
        (偵測現有的 Scoop 安裝，或定義新的目標路徑)
    #>
    
    # 1. 優先權 A: 檢查目前 Session 是否已有 $env:SCOOP
    if ($env:SCOOP -and (Test-Path $env:SCOOP)) {
        $global:TARGET_SCOOP = $env:SCOOP
        Write-Host "[√] Detected Scoop from current Session: $global:TARGET_SCOOP" -ForegroundColor Green
        return
    }

    # 2. 優先權 B: 檢查系統環境變數 (User/Machine Scope)
    $sysScoop = [Environment]::GetEnvironmentVariable("SCOOP", "User")
    if (!$sysScoop) { $sysScoop = [Environment]::GetEnvironmentVariable("SCOOP", "Machine") }
    
    if ($sysScoop -and (Test-Path $sysScoop)) {
        $global:TARGET_SCOOP = $sysScoop
        $env:SCOOP = $sysScoop # 同步到當前 Session
        Write-Host "[√] Detected Scoop from System Environment: $global:TARGET_SCOOP" -ForegroundColor Green
        return
    }

    # 3. 優先權 C: 檢查常見的預設路徑 (Default Paths)
    $commonPaths = @(
        "$env:USERPROFILE\scoop",
        "D:\Scoop",
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

    # 4. 優先權 D: 全都找不到，才定義新的 (New Installation Target)
    Write-Host "[!] No existing Scoop detected. Defining new target..." -ForegroundColor Yellow
    if (Test-Path "D:") {
        $global:TARGET_SCOOP = "D:\Scoop"
    } else {
        $global:TARGET_SCOOP = "C:\Scoop"
    }
    $env:SCOOP = $global:TARGET_SCOOP
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
if (!(Test-Path "$xdgRoot")) { New-Item -ItemType Directory -Path "$xdgRoot" -Force }
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
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        Write-Host "[√] WSL 已經安裝。" -ForegroundColor Green
        return
    }

    $choice = Read-Host "[!] 偵測到尚未安裝 WSL，是否現在安裝？ [y/N]"
    if ($choice -match 'y|Y') {
        Write-Host "正在啟動 WSL 安裝 (需管理員權限)..." -ForegroundColor Magenta
        Start-Process "wsl" -ArgumentList "--install" -Verb RunAs -Wait
    }
}

function Setup-PowerShellEnvironment {
    param ([string]$ScoopPath)
    Write-Host "`n--- PowerShell 核心環境佈署 ---" -ForegroundColor Cyan

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
        & scoop install pwsh
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
        # 這裡會開一個新的 pwsh 視窗來跑完剩下來的事情
        Start-Process "$scoopPwsh" -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`""    
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


# 1. 如果沒安裝 Scoop 則安裝 (原本的邏輯)
if (!(Get-Command scoop -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Scoop..." -ForegroundColor Yellow
    iwr -useb get.scoop.sh | iex
}

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


Setup-PowerShellEnvironment -ScoopPath $TARGET_SCOOP

Write-Host "`n--- Starting Full Deployment ---" -ForegroundColor Green
Check-And-Install-WSL

Write-Host "Updating Scoop manifests..." -ForegroundColor Cyan
& scoop update

# --- 1. 基礎工具 (沒有它們，後面都動不了) ---
$core_apps = @("git", "7zip")

foreach ($app in $core_apps) {
    if (!(Get-Command $app -ErrorAction SilentlyContinue)) {
        Write-Host "Installing Core Tool: $app..." -ForegroundColor Magenta
        & scoop install $app
    }
}

$required_buckets = @{
    "extras"     = $null
    "nerd-fonts" = $null
    "sarasa-nerd-fonts" = "https://github.com/jonz94/scoop-sarasa-nerd-fonts"
    "fonts"      = "https://github.com/gh0stzk/dotfiles.git"
}

foreach ($bucket in $required_buckets.Keys) {
    if (!(scoop bucket list | Select-String $bucket)) {
        $url = $required_buckets[$bucket]
        if ($url) {
            & scoop bucket add $bucket $url
        } else {
            & scoop bucket add $bucket
        }
    }
}

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

foreach ($app in $apps) {
    if (!(Get-Command $app -ErrorAction SilentlyContinue)) {
        echo "Installing $app via Scoop..."
        scoop install $app
    } else {
        echo "$app is already installed."
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
$templateConfig = "$starshipThemeDir\template.toml"  # 你的預設範本
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

# 4. Sublime Text (使用 New-WinLink 呼叫 mklink)
$sublimeTarget = "$TARGET_SCOOP\persist\sublime-text\Data\Packages\User"
$sublimeSource = "$TARGET_SCOOP\etc\dotfiles\sublime\User"
New-WinLink -target "$sublimeTarget" -source "$sublimeSource"

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
$psProfileSource = "$DOT_ROOT\windows\powershell.ps1"

# 定義目標 (pwsh v7+ 的標準 profile 路徑)
$psProfileDir = "$WIN_HOME\Documents\PowerShell"
$psProfileTarget = "$psProfileDir\Microsoft.PowerShell_profile.ps1"
New-WinLink -target "$psProfileTarget" -source "$psProfileSource"


Write-Host "Windows deployment completed successfully!" -ForegroundColor Green


