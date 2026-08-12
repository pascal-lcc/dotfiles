# 設定編碼為 UTF-8，這對顯示特殊符號很重要
[console]::InputEncoding = [console]::OutputEncoding = [System.Text.Encoding]::UTF8


# 1. 啟用歷史紀錄預測 (像 Google 搜尋一樣出現灰色影子)
Set-PSReadLineOption -PredictionSource History

# 2. 啟用清單顯示模式 (按 F2 可以切換模式)
Set-PSReadLineOption -PredictionViewStyle ListView

Set-PSReadLineOption -Colors @{ InlinePrediction = "$([char]27)[38;5;238m" }
# 按 Tab 不再是一個一個跳，而是出一個選單讓你選

# --- 額外加碼：快速編輯設定檔的小縮寫 ---
function edit-profile { nvim $PROFILE }
function reload-profile { . $PROFILE }


# 1. 模式設定
#Set-PSReadLineOption -EditMode Vi
Set-PSReadLineOption -PredictionViewStyle ListView
Set-PSReadLineOption -PredictionSource History

# 2. 讓 Tab 啟動選單
Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete

# 啟用預測功能 (需要 PSReadLine 2.2.2+)
# if (Get-Module -ListAvailable PSReadLine) {
#     Set-PSReadLineOption -PredictionSource History
#     Set-PSReadLineOption -PredictionViewStyle ListView # 或者 InlineView
# }


Set-PSReadLineKeyHandler -Chord 'Alt+j' -ScriptBlock { [Microsoft.PowerShell.PSConsoleReadLine]::NextHistory() }
Set-PSReadLineKeyHandler -Chord 'Alt+k' -ScriptBlock { [Microsoft.PowerShell.PSConsoleReadLine]::PreviousHistory() }
Set-PSReadLineKeyHandler -Chord 'Alt+h' -ScriptBlock { [Microsoft.PowerShell.PSConsoleReadLine]::BackwardChar() }
Set-PSReadLineKeyHandler -Chord 'Alt+l' -ScriptBlock { [Microsoft.PowerShell.PSConsoleReadLine]::ForwardChar() }

if ($env:SCOOP) {
    # 優先使用現有的環境變數
    $GLOBAL:TARGET_SCOOP = $env:SCOOP
} elseif (Test-Path "D:\Scoop") {
    # 如果變數不在，但 D 槽有東西，主動抓取
    $GLOBAL:TARGET_SCOOP = "D:\Scoop"
} elseif (Test-Path "C:\Scoop") {
    # 如果變數不在，但 D 槽有東西，主動抓取
    $GLOBAL:TARGET_SCOOP = "C:\Scoop"
} elseif (Test-Path "$env:USERPROFILE\scoop") {
    # 回退到預設路徑 (C 槽)
    $GLOBAL:TARGET_SCOOP = "$env:USERPROFILE\scoop"
} else {
    # 如果真的找不到，設為 null 或給個警告
    $GLOBAL:TARGET_SCOOP = $null
}

if ($GLOBAL:TARGET_SCOOP) {
    $env:SCOOP = $GLOBAL:TARGET_SCOOP
}

# --- Starship (Prompt) ---
if (Get-Command starship -ErrorAction SilentlyContinue) {
    # 這裡建議指向你 dotfiles 裡的路徑，或者維持預設
    $env:STARSHIP_CONFIG = "$HOME\.config\starship.toml"
    Invoke-Expression (&starship init powershell)

# 放在 Invoke-Expression (&starship init pwsh) 之後
    function VT-Starship-Transient {
        # 這是 Starship 官方提供的瞬態觸發指令
        Invoke-Expression (&starship module character)
    }

    Enable-TransientPrompt
}

# --- Zoxide (Better cd) ---
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    # Out-String 是確保多行腳本能被 Invoke-Expression 正確執行的關鍵
    zoxide init powershell | Out-String | Invoke-Expression
}

# --- Eza (Modern ls) ---
if (Get-Command eza -ErrorAction SilentlyContinue) {
    # 1. 宣告你的 eza 增強功能
    function Invoke-EzaLs { eza --icons --group-directories-first $args }
    function ll { eza -l --icons --git --group-directories-first $args }
    function la { eza -a --icons --group-directories-first $args }
    function lla { eza -la --icons --git --group-directories-first $args }
    function lt { eza --tree --level 2 --icons $args }

    # 2. 🎯 強制拔除內建的 ls 別名，並重新綁定到你的 eza function 上
    Remove-Item alias:ls -ErrorAction SilentlyContinue
    Set-Alias -Name ls -Value Invoke-EzaLs
}

# --- FZF (模糊搜尋) ---
# 既然 --powershell 不能用，我們直接手動加載 Scoop 安裝的插件
$fzfPath = "$env:USERPROFILE\scoop\apps\fzf\current\shell"
if (Test-Path "$fzfPath\key-bindings.ps1") {
    . "$fzfPath\key-bindings.ps1"
    . "$fzfPath\completion.ps1"
}

# --- Bat (Syntax Highlighting cat) ---
# 雖然 bat 不需要 init，但我們可以設 alias 讓他更好打
if (Get-Command bat -ErrorAction SilentlyContinue) {
    Set-Alias cat bat
}

if (Get-Command nvim -ErrorAction SilentlyContinue) {
    Set-Alias vi nvim
}

# --- FD (Simple Find) ---
# fd 主要是給 fzf 或其他工具用的，通常不需要特別設 alias

if (Get-Command fzf -ErrorAction SilentlyContinue) {
    # # 按下 Ctrl+R 啟動歷史搜尋    
    Set-PSReadLineKeyHandler -Key "Ctrl+r" -ScriptBlock { fh }
    # 按下 FZF 風格的選單 (需先用 scoop install fzf)
    # 這裡推薦使用官方建議的 fzf-powershell 模組
    # --- Fuzzy Cat (fca) ---
    function fca {
        param([string]$query = "")
        # 搜尋範圍：當前、User目錄、Scoop根目錄
        $searchPaths = ".", $env:USERPROFILE, $global:TARGET_SCOOP
        
        $file = fd . $searchPaths --type f --hidden --exclude .git 2>$null | 
                fzf --query="$query" --select-1 --exit-0 `
                    --preview 'bat --style=numbers --color=always --line-range :100 {} 2>$null || file -b {} 2>$null || echo "Binary File"'

                    # --preview 'bat --style=numbers --color=always --line-range :100 {} 2>$null || Get-Content -Head 100 {}'
        if ($file) {
            Write-Host "[Reading] $file" -ForegroundColor Green
            if (Get-Command bat -ErrorAction SilentlyContinue) {
                bat $file
            } else {
                Get-Content $file
            }
        }
    }

    # --- Fuzzy Edit (fe) ---
    function fe {
        param([string]$query = "")
        $searchPaths = ".", $env:USERPROFILE, $global:TARGET_SCOOP
        
        $file = fd . $searchPaths --type f --hidden --exclude .git 2>$null | 
                fzf --query="$query" --select-1 --exit-0 `
                    --preview 'bat --style=numbers --color=always --line-range :100 {} 2>$null || Get-Content -Head 100 {}'

        if ($file) {
            Write-Host "[Editing] $file" -ForegroundColor Green
            # 這裡建議 Windows 也裝個 nvim (scoop install neovim)
            nvim $file
        }
    }

    # --- Fuzzy History (fh) ---
    function fh {
        param([string]$query = "")
        # 取得 PSReadLine 的歷史紀錄
        $history = [Microsoft.PowerShell.PSConsoleReadLine]::GetHistoryItems() | 
                   Select-Object -ExpandProperty CommandLine -Unique | 
                   Sort-Object -Descending # 最新的排上面
        
        $line = $history | fzf --query="$query" --height 40% --layout reverse --border
        
        if ($line) {
            # 這是關鍵：把選中的指令直接填入當前提示字元後方
            [Microsoft.PowerShell.PSConsoleReadLine]::DeleteLine()
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert($line)
        }
    }

    # --- Fuzzy Jump (fz) ---
    function fz {
        param([string]$query = "")
        $dir = fd . $env:USERPROFILE $global:TARGET_SCOOP --type d --hidden --exclude .git 2>$null | 
               fzf --query="$query" --select-1 --exit-0
        if ($dir) { Set-Location $dir }
    }

    function fls {
        param([string]$query = "")
        $searchPaths = ".", $env:USERPROFILE, $global:TARGET_SCOOP
        $dir = fd . $searchPaths --type d --hidden --exclude .git 2>$null | 
               fzf --query="$query" --header "[fls] List Directory Contents" `
                   --preview 'ls -Name {}'

        if ($dir) {
            Write-Host "`n[Listing] $dir" -ForegroundColor Cyan
            Get-ChildItem $dir
        }
    }
}

if (Get-Command git -ErrorAction SilentlyContinue) {
    # 基礎 diff (繼承你的 .gitconfig 設定，如 delta 左右對照)
    function gd { git diff $args }

    # 強制單欄式 diff (當你需要複製代碼時，這招超好用！)
    # -c 是 git 的旗標，代表「本次執行使用此臨時設定」
    function gds { git -c delta.side-by-side=false diff $args }
    # 既然都有 gd 了，要不要順便加個常用組合？
    function ga { git add $args }
    function gc { git commit -m $args }
    function gp { git push $args }
}

# --- Yazi (Terminal File Manager) ---
# 這是你提到的 yy (退出時自動切換目錄)
if (Get-Command yazi -ErrorAction SilentlyContinue) {
    $TARGET_SCOOP = $env:SCOOP

    function yy {
        # 1. 局部注入路徑（這是你成功的關鍵）
        $oldPath = $env:PATH
        $env:PATH = "$TARGET_SCOOP\apps\git\current\usr\bin;" + $env:PATH
        
        # 2. 準備跳轉用的暫存檔
        $tmp = [System.IO.Path]::GetTempFileName()
        
        try {
            # 3. 執行 Yazi
            # 使用 --cwd-file 讓 Yazi 紀錄最後離開的位置
            yazi $args --cwd-file="$tmp"
            
            # 4. 讀取並跳轉
            if (Test-Path $tmp) {
                $lastDir = Get-Content $tmp
                if ($lastDir -and $lastDir -ne $PWD.Path -and (Test-Path $lastDir)) {
                    Set-Location $lastDir
                }
            }
        }
        finally {
            # 5. 清理：還原 PATH 並刪除暫存檔
            $env:PATH = $oldPath
            if (Test-Path $tmp) { Remove-Item $tmp -ErrorAction SilentlyContinue }
        }
    }
}

# Set-Location "$env:SCOOP\etc\dotfiles"
Set-Location $HOME
function Set-CommandAlias ($Name, $Target) {
    # 1. 檢查目標執行檔是否存在
    $cmd = Get-Command $Target -ErrorAction SilentlyContinue
    if ($cmd) {
        # 2. 直接使用內建的 Set-Alias，並指定作用域為 Global
        # Option: -Value 可以直接給執行檔名稱或完整路徑 $cmd.Source
        Set-Alias -Name $Name -Value $cmd.Source -Scope Global -Force
        Write-Host "  [√] Alias: $Name -> $Target" -ForegroundColor Gray
    } else {
        Write-Host "  [x] $Target not found, skipping $Name" -ForegroundColor Red
    }
}

# 使用方式
Set-CommandAlias "lg" "lazygit"
Set-CommandAlias "fca" "fastfetch"
Set-Alias v nvim -Scope Global -Force

function dot {
    cd "$env:SCOOP\etc\dotfiles"
}

function Switch-Neovim {
    param(
        [Parameter(Mandatory=$false, Position=0)]
        [ValidateSet("nightly", "stable")]
        [string]$Channel = "stable" # 預設為 stable
    )

    # 1. 決定目標 App 名稱
    $targetApp = if ($Channel -eq "nightly") { "neovim-nightly" } else { "neovim" }
    
    # 2. 檢查目前 nvim 指令指向哪一個 Scoop App (偵測當前版本)
    $currentNvim = Get-Command nvim -ErrorAction SilentlyContinue
    $currentApp = ""
    if ($currentNvim) {
        # 從路徑判斷目前是哪一個 app 在掌管 shim
        if ($currentNvim.Source -like "*\neovim-nightly\*") { $currentApp = "neovim-nightly" }
        elseif ($currentNvim.Source -like "*\neovim\*") { $currentApp = "neovim" }
    }

    # 3. 如果當前版本已經是目標版本，直接跳過
    if ($currentApp -eq $targetApp) {
        Write-Host "[-] Neovim is already on the $Channel channel ($targetApp)." -ForegroundColor Gray
        return
    }

    Write-Host "--- Switching Neovim to $Channel channel ---" -ForegroundColor Cyan

    # 4. 確保必要的 Bucket 存在
    if ($Channel -eq "nightly" -and !(scoop bucket list | Select-String "versions")) {
        Write-Host "[+] Adding 'versions' bucket..." -ForegroundColor Yellow
        scoop bucket add versions
    }

    # 5. 執行安裝或切換 (使用 scoop reset 來達成類似 ln -sf 的效果)
    # 如果沒裝過才 install，裝過了就 reset
    if (!(scoop list | Select-String "^$targetApp\s")) {
        Write-Host "[+] Installing $targetApp..." -ForegroundColor Yellow
        scoop install $targetApp
    } else {
        Write-Host "[>] Resetting $targetApp as active..." -ForegroundColor Yellow
        scoop reset $targetApp
    }

    Write-Host "[√] Neovim successfully switched to $Channel!" -ForegroundColor Green
    nvim --version | head -n 1
}

# 放在 Switch-Neovim 函式定義之後
Register-ArgumentCompleter -CommandName Switch-Neovim -ParameterName Channel -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    @("stable", "nightly") | Where-Object { $_ -like "$wordToComplete*" }
}

# FNM (Fast Node Manager) 初始化 (PowerShell 版)
if (Get-Command fnm -ErrorAction SilentlyContinue) {
    fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression
}

if (Get-Command fastfetch -ErrorAction SilentlyContinue) {
    Clear-Host  # 先清空畫面，讓 Logo 出現在最上方
    fastfetch
    Write-Host "🚀 Welcome back, $($env:USERNAME)! Environment is ready." -ForegroundColor Cyan
}

# =========================================================================
# WezTerm 行程狀態同步機制 (微軟標準直通管道版 - 絕不秒蓋)
# =========================================================================

# 1. 使用微軟官方規範的專屬不阻塞管道發送 Base64 給 WezTerm
function Send-WezTermUserVar {
    param (
        [string]$Name,
        [string]$Value
    )
    if ([string]::IsNullOrEmpty($Name) -or [string]::IsNullOrEmpty($Value)) { return }
    
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $base64 = [Convert]::ToBase64String($bytes)
    
    $osc = "$([char]27)]1337;SetUserVar=$Name=$base64$([char]7)"
    Write-Host -NoNewline $osc
}

# 清理歷史殘留
$ExecutionContext.InvokeCommand.PreCommandLookupAction = $null
if (Test-Path Function:\prompt) {
    Rename-Item Function:\prompt OrigPrompt -ErrorAction SilentlyContinue
}

# 2. 【PreCmd 階段】當且僅當行程「徹底結束」、回到提示字元時才發送 sh
function prompt {
    Send-WezTermUserVar -Name "PROG" -Value "sh"
    
    if (Test-Path Function:\OrigPrompt) { OrigPrompt } else { "PS $($executionContext.SessionState.Path.CurrentLocation)> " }
}

# =========================================================================
# 3. 【PreExec 階段】（完整安全替換版：自帶無限迴圈防禦鎖）
# =========================================================================
$ExecutionContext.InvokeCommand.PreCommandLookupAction = {
    param($CommandName, $CommandLookupEventArgs)
    
    # 🛡️ 終極防禦鎖：一進門先過濾。如果是發送序列或系統內部小動作，直接秒退，絕對不往下走！
    if ($CommandName -match "Write-Host|out-lineoutput|Send-WezTermUserVar|prompt|OrigPrompt") {
        return
    }
    
    # 🎯 嚴格白名單：只有匹配到這些 Windows 本地阻塞行程，才允許發送訊號
    if ($CommandName -match "^(tail|vi|vim|nvim|fzf|ping|fget)(\.exe)?$") {
        
        $clean_cmd = [System.IO.Path]::GetFileNameWithoutExtension($CommandName)
        $final_prog = $clean_cmd.ToUpper()
        
        # 精準送出
        Send-WezTermUserVar -Name "PROG" -Value $final_prog
    }
}

if (Get-Command tail -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Alias' }) {
    Remove-Item Alias:\tail -ErrorAction SilentlyContinue
}

# 建立一個真正的 Linux 魂 tail 函數
function tail {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    # 🎯 核心邏輯：如果你輸入了 -f 參數，我們直接無縫換成微軟最強的實時滾動引擎
    if ($Arguments -contains "-f") {
        # 抓出參數中排除掉 "-f" 的那個檔案路徑
        $FilePath = $Arguments | Where-Object { $_ -ne "-f" }
        
        if ([string]::IsNullOrEmpty($FilePath)) {
            Write-Error "請指定要監控的 Log 檔案路徑！例如: tail -f app.log"
            return
        }

        # ✨ 用微軟嫡系 API：-Wait 負責即時監聽變更，-Tail 10 負責先吐最後10行
        # 這完全繞過 Windows 檔案鎖地雷，新資料 100% 邊看邊噴出來！
        Get-Content -Path $FilePath -Wait -Tail 10
    }
    else {
        # 如果你只是單純想看檔案末尾（沒加 -f），就呼叫舊有的 tail 執行檔處理
        # 這裡用 Get-Command 找出原本實體 tail.exe 的路徑，防止無限遞迴
        $RealTail = (Get-Command tail.exe -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch "PowerShell_profile" })[0]
        if ($RealTail) {
            & $RealTail.Source @Arguments
        } else {
            # 如果系統根本沒 tail.exe，安全降級使用 Get-Content
            Get-Content -Path $Arguments -Tail 10
        }
    }
}
