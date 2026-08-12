#!/bin/bash

# --- 顏色定義 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SUDO_KEEP_ALIVE_PID=""
cleanup() {
    local exit_code=$? # 取得最後一個指令的狀態碼
    local signal=$1    # 取得傳入的信號名稱

    if [ "$signal" = "INT" ]; then
        echo -e "\n${YELLOW}[Interrupt]${NC} 正在清理並手動結束腳本..."
    elif [ "$signal" = "EXIT" ] && [ "$exit_code" -ne 0 ]; then
        # 這是處理腳本中途噴錯（非 0 退出）的情況
        echo -e "\n${RED}[Error]${NC} 腳本異常終止，正在清理..."
    else
        # 正常結束的情況 (EXIT 且 exit_code 為 0)
        echo -e "\n${GREEN}[Done]${NC} 部署完成，清理暫存程序..."

        if [ "$exit_code" -eq 0 ]; then
            if [ "$SOFT_ERROR_COUNT" -gt 0 ]; then
                echo -e "${YELLOW}[Completed with Warnings]${NC} 部署完成，但有 $SOFT_ERROR_COUNT 個非致命錯誤。"
            fi
        fi
    fi

    # 1. 殺掉後台 sudo 續期程序
    if [ -n "$SUDO_KEEP_ALIVE_PID" ]; then
        kill "$SUDO_KEEP_ALIVE_PID" 2>/dev/null
    fi

    # 2. 重置終端機狀態
    stty sane
    
    # 3. 如果是正常結束，通常不需要 sudo -k (除非你希望下次立刻又要密碼)
    # sudo -k 
}

trap 'cleanup EXIT' EXIT
trap 'cleanup INT' INT

set -e

SOFT_ERROR_COUNT=0
try_run() {
    local desc=$1
    shift
    echo "🚀 執行: $desc..."
    
    if ! "$@"; then
        echo -e "${RED}[Soft Error]${NC} $desc 失敗，但我們將嘗試繼續..."
        SOFT_ERROR_COUNT=$((SOFT_ERROR_COUNT + 1))
        sleep 2
    fi
    return 0
}

# --- 0. 權限預檢與背景續期 ---
if [ "$EUID" -ne 0 ]; then
    echo "Requesting sudo privileges for deployment..."
    sudo -v
    # 背景續期
    ( while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done ) 2>/dev/null &
    SUDO_KEEP_ALIVE_PID=$!
    # while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
    # 🌟 關鍵修正：捕捉剛才那個背景程序的 PID
    # SUDO_PID=$!
fi


# ----------------------------------------------------------------
# Function: init_windows_paths
# 描述: 一次性偵測並導出所有關鍵 Windows 路徑
# ----------------------------------------------------------------
# ----------------------------------------------------------------
# Function: init_windows_env
# Description: Detect and export Windows-related paths (Root, PS, Scoop)
# ----------------------------------------------------------------
# 使用顏色代碼 (Color Codes)

init_windows_env() {
    # 1. Detect Windows Drive Base (e.g., /mnt/c)
    # 這裡我們動態找出掛載點，不寫死路徑
    export WIN_DIR_BASE=$(mount | grep -E 'drvfs on /.* \(msdos|fixed|uid=' | awk '{print $3}' | while read -r mnt; do
        [ -d "$mnt/Windows/System32" ] && echo "$mnt/Windows" && break
    done)

    # Fallback (保底機制)
    [ -z "$WIN_DIR_BASE" ] && export WIN_DIR_BASE=$(wslpath -u "C:\Windows" 2>/dev/null)

    if  [ -z "$WIN_DIR_BASE" ]; then
        echo "❌ 找不到 Windows 路徑，中斷此 function。"
        return 0
    fi

    # 2. Define System PowerShell (系統內建的 PS 5.1)
    export SYSTEM_PS="$WIN_DIR_BASE/System32/WindowsPowerShell/v1.0/powershell.exe"

    # 3. Detect Scoop Root (偵測 Scoop 根目錄)
    if [ -x "$SYSTEM_PS" ]; then
        # Ask Windows for its environment variables
        local raw_scoop=$("$SYSTEM_PS" -NoProfile -Command "if (\$env:SCOOP) { echo \$env:SCOOP } else { echo \"\$env:USERPROFILE\scoop\" }" | tr -d '\r')
        export SCOOP_ROOT=$(wslpath -u "$raw_scoop" 2>/dev/null)
    fi

    # 4. Define the Best PowerShell (偵測最強的 PS 版本)
    # Priority: Scoop pwsh > System pwsh > Built-in powershell
    if [ -x "$SCOOP_ROOT/apps/pwsh/current/pwsh.exe" ]; then
        export WIN_PS="$SCOOP_ROOT/apps/pwsh/current/pwsh.exe"
    elif [ -x "$WIN_DIR_BASE/../Program Files/PowerShell/7/pwsh.exe" ]; then
        export WIN_PS="$WIN_DIR_BASE/../Program Files/PowerShell/7/pwsh.exe"
    else
        export WIN_PS="$SYSTEM_PS"
    fi
    export PS_WINPATH=$(wslpath -w "$WIN_PS")

    # Logging results (列印結果)
    echo "--- Windows Environment Initialized ---"
    echo "WIN_DIR_BASE : $WIN_DIR_BASE"
    echo "SCOOP_ROOT   : $SCOOP_ROOT"
    echo "WIN_PS       : $WIN_PS"
    echo "PS_WINPATH       : $PS_WINPATH"
}

GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}[Detecting]${NC} Windows environment..."
init_windows_env


# --- 1. 路徑抓取 ---
# 因為腳本在 script/ 目錄下，所以根目錄是上一層
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DOT_ROOT=$(realpath "$SCRIPT_DIR/..")
USER_HOME=$HOME


WIN_GIT_BIN="$SCOOP_ROOT/apps/git/current/mingw64/bin"
WIN_GIT_CMD="$SCOOP_ROOT/apps/git/current/cmd"

export PATH="$PATH:$WIN_GIT_BIN:$WIN_GIT_CMD"

# --- 2. 環境偵測 ---
IS_WSL=false
# if [ -f /proc/sys/fs/binfmt_misc/WSLInterop ] || grep -qiE "(microsoft|wsl)" /proc/version; then
if [ -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then
    IS_WSL=true
fi



# --- 2. Starship 部署 (含安裝與 rsync) ---
deploy_starship() {
    if ! command -v starship >/dev/null 2>&1; then
        curl -sS https://starship.rs/install.sh | sh -s -- -y
    fi

    local CONFIG_DIR="$USER_HOME/.config"
    mkdir -p "$CONFIG_DIR/starship"

    # Bash 版對應邏輯
    local theme_dir="$DOT_ROOT/config/starship/themes"
    local wsl_config="$theme_dir/starship.toml.wsl"
    local template="$theme_dir/template.toml"

    # 如果沒有 WSL 專用檔，就生一個
    if [ ! -f "$wsl_config" ]; then
        cp "$template" "$wsl_config"
    fi

    safe_link "$wsl_config" "$CONFIG_DIR/starship.toml"


    if [ "$IS_WSL" = true ]; then
        # rsync -au --delete "$DOT_ROOT/config/starship/themes/" "$CONFIG_DIR/starship/themes/"
        safe_link "$DOT_ROOT/config/starship/themes" "$CONFIG_DIR/starship/themes"        
        # [ ! -f "$CONFIG_DIR/starship.toml" ] && safe_link "$s_starship" "$CONFIG_DIR/starship.toml"
        safe_link "$wsl_config" "$CONFIG_DIR/starship.toml"
        # cp -u "$CONFIG_DIR/starship/themes/space.toml" "$CONFIG_DIR/starship.toml"
    else
        safe_link  "$DOT_ROOT/config/starship/themes" "$CONFIG_DIR/starship/themes"        
        safe_link "$wsl_config" "$CONFIG_DIR/starship.toml"
    fi    
}

# --- 3. 核心：WSL Kernel 部署 (你最重視的部分) ---
deploy_kernel() {
    echo "--- Checking Kernel Assets ---"
    mkdir -p "$RUNTIME_DIR"
    local target_ver="6.6.123.2+"
    local bzImage="bzImage-linux-msft-wsl-6.6.123.2"
    local modules_tgz="module-${target_ver}.tgz"
    local KERNEL_VERSION="v6.6.123.2"
    local REPO="pascal-lcc/dotfiles"

    if [ ! -f "$RUNTIME_DIR/$bzImage" ]; then
        echo "Kernel ["$RUNTIME_DIR/$bzImage"] asset not found. Attempting download via gh..."        
        if command -v gh >/dev/null 2>&1; then
            echo "gh release download "$KERNEL_VERSION" --repo "$REPO" --pattern "*" --dir "$RUNTIME_DIR" --clobber"
            # gh release download "$KERNEL_VERSION" --repo "$REPO" --pattern "*" --dir "$RUNTIME_DIR" --clobber
            if ! gh release download "$KERNEL_VERSION" --repo "$REPO" --pattern "*" --dir "$RUNTIME_DIR" --clobber ; then
                echo -e "${RED}[Error]${NC} GitHub CLI 尚未登入或下載失敗。"
                echo "請執行: gh auth login"
                exit 1  # 這裡會觸發你的 trap cleanup
            fi
        else
            echo "Error: gh CLI not found. Please install gh to download kernel."
        fi
    fi
    # 建立 Windows 側連結 (供 .wslconfig 讀取)
    if [ -f "$RUNTIME_DIR/$bzImage" ]; then
        echo "--- Checking Kernel Symlink ---"
        
        # 1. 取得資料夾的 Windows 路徑 (不要直接對檔案跑 wslpath)
        local win_runtime_dir=$(wslpath -w "$RUNTIME_DIR")

        # 2. 手動拼接，確保 link 路徑不被解析 (Resolve)
        local win_kernel_link="${win_runtime_dir}\\current_kernel"
        local win_kernel_real="${win_runtime_dir}\\$bzImage"

        echo "Debug: Check Link Path -> $win_kernel_link"
        echo "Debug: Check Real Path -> $win_kernel_real"
        local ps_cleanup="
            \$targets = @('$win_kernel_link', '$win_kernel_link.lnk');
            foreach (\$t in \$targets) {
                if (Test-Path \$t) { 
                    Write-Host 'Removing old entry: \$t';
                    Remove-Item \$t -Force -Recurse -ErrorAction SilentlyContinue 
                }
            }
        "

        # 3. 讓 PowerShell 進行「非解析」檢查
        # 使用 Get-Item 的屬性，而不是讓 Shell 自動跳轉
        local check_result=$("$WIN_PS" -NoProfile -Command "
            \$item = Get-Item -LiteralPath '$win_kernel_link' -ErrorAction SilentlyContinue;
            if (\$item -and (\$item.Attributes -match 'ReparsePoint')) {
                # 這裡要抓取 Link 的 Target 屬性進行比對
                if (\$item.Target -eq '$win_kernel_real') {
                    echo 'OK'
                } else {
                    echo 'WRONG_TARGET'
                }
            } else {
                echo 'NOT_A_LINK'
            }
        " | tr -d '\r')

        echo "Debug: Final Result -> $check_result"

        if [ "$check_result" == "OK" ]; then
            echo "Success: Kernel link is correct."
        else
            echo "Action: Updating link (Reason: $check_result)"
            # 執行提權建立
            local ps_create="
                if (Test-Path '$win_kernel_link') { Remove-Item '$win_kernel_link' -Force };
                New-Item -Path '$win_kernel_link' -ItemType SymbolicLink -Value '$win_kernel_real' -Force
            "
            "$WIN_PS" -Command "Start-Process $PS_WINPATH -ArgumentList '-NoProfile', '-Command', \"$ps_create\" -Verb RunAs -Wait"
            NEED_RESTART=true
        fi
    fi

    local pkg_ver=$(echo "$modules_tgz" | sed 's/module-//;s/.tgz//')


    if [ -f "$RUNTIME_DIR/$modules_tgz" ]; then
        if [ ! -d "/lib/modules/$pkg_ver" ]; then
            echo "Pre-installing modules for version $pkg_ver..."
            sudo tar -xvzf "$RUNTIME_DIR/$modules_tgz" -C /lib/modules
            
            # 關鍵：即使目前不是這個核心，只要路徑對了，depmod 指令可以指定版本
            sudo depmod -a "$pkg_ver"
            echo "Modules installed. They will be active after WSL restart."
            NEED_RESTART=true
        else
            echo "Modules for $pkg_ver already exist."
        fi
    fi
}

# --- 4. 核心：WSL Config 渲染 ---
render_wslconfig() {

    # 取得硬體規格
    local WIN_CPU=$("$WIN_PS" -NoProfile -Command "[int]\$env:NUMBER_OF_PROCESSORS" | tr -d '\r')
    local WIN_MEM_RAW=$("$WIN_PS" -NoProfile -Command "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory" | tr -d '\r')
    local TOTAL_GB=$(awk "BEGIN {print int($WIN_MEM_RAW / 1024 / 1024 / 1024)}")

    local WSL_CPU=$((WIN_CPU - 2)); [ $WSL_CPU -lt 2 ] && WSL_CPU=2
    local WSL_MEM_GB=$(awk "BEGIN {print int($TOTAL_GB * 0.75)}")
    local ZFS_MAX=$(awk "BEGIN {print int($WSL_MEM_GB * 0.75 * 1024 * 1024 * 1024)}")
    local ZFS_MIN=$(awk "BEGIN {print int($WSL_MEM_GB * 0.25 * 1024 * 1024 * 1024)}")
    local WSL_SWAP_GB=$(awk "BEGIN {print int($TOTAL_GB * 0.2)}")

    local KERNEL_PATH=$(wslpath -w "${RUNTIME_DIR}/current_kernel" | sed -r 's/\\/\\\\\\\\/g')

    sed -e "s/{{MEM}}/$WSL_MEM_GB/g" \
        -e "s/{{CPU}}/$WSL_CPU/g" \
        -e "s/{{SWAP_SIZE}}/$WSL_SWAP_GB/g" \
        -e "s/{{ZFS_MAX}}/$ZFS_MAX/g" \
        -e "s/{{ZFS_MIN}}/$ZFS_MIN/g" \
        -e "s|{{KERNEL_PATH}}|$KERNEL_PATH|g" \
        "$DOT_ROOT/windows/.wslconfig.tmpl" > "$WIN_HOME_PATH/.wslconfig"
    echo "Generated .wslconfig for ${TOTAL_GB}GB RAM system."
    echo "--- Rendering .wslconfig ---"    
}

system_update() {
    echo "🚀 Starting System Upgrade for Proxmox/Debian..."
    # 確保抓到最新清單
    sudo apt-get update -qq
    
    # 執行升級
    # --with-new-pkgs 允許安裝新套件（對 kernel 更新很重要）
    sudo apt-get dist-upgrade -y
    
    # 清理舊的、不需要的包（節省硬碟空間）
    sudo apt-get autoremove -y
    sudo apt-get autoclean
    
    echo "✅ Upgrade finished. If kernel was updated, please consider REBOOTING."
}

# --- 萬用安裝器 ---
PKG_UPDATED=false
install_pkg() {
    local pkg=$1
    echo "Checking/Installing: $pkg"

    # 1. 根據不同的包管理器執行一次性更新
    if [ "$PKG_UPDATED" = false ]; then
        if command -v brew >/dev/null 2>&1; then
            echo "Updating Homebrew..."
            brew update
        elif command -v apt-get >/dev/null 2>&1; then
            echo "Updating apt..."
            sudo apt update
        elif command -v pacman >/dev/null 2>&1; then
            echo "Updating pacman database..."
            sudo pacman -Sy
        elif command -v dnf >/dev/null 2>&1; then
            echo "Updating dnf cache..."
            sudo dnf check-update >/dev/null 2>&1 # dnf 通常會自動處理，但這裡做個心安
        fi
        # 更新完後，將旗標設為 true
        PKG_UPDATED=true
	echo "Apt update finished." # 這行會強迫觸發畫面更新，解決「假死」問題
    fi

    # 2. 執行實際的安裝指令
    if command -v brew >/dev/null 2>&1; then
        brew install "$pkg"
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y "$pkg"
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm "$pkg"
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y "$pkg"
    else
        echo "Error: 無法識別的包管理器，請手動安裝 $pkg"
        return 1
    fi
}
# ----------------------------------------------------------------
# Function: deploy_neovim_appimage
# 描述: 跨架構部署最新版 Neovim，具備冪等性檢查
# ----------------------------------------------------------------
deploy_neovim_stable() {
    echo "--- [Stable] Neovim Versioned Deployment ---"
    # 1. 環境與依賴準備
    local arch=$(uname -m)
    local nvim_arch="x86_64"
    [[ "$arch" == "aarch64" ]] && nvim_arch="arm64"
    
    local fuse_pkg="libfuse2"
    [ -n "$(command -v dnf)" ] && fuse_pkg="fuse-libs"
    [ -n "$(command -v pacman)" ] && fuse_pkg="fuse2"
    install_pkg "$fuse_pkg"
    install_pkg "jq"

    # 2. 定義目錄與路徑 (集中化管理)
    local BASE_DIR="/opt/nvim-releases"
    local LINK_PATH="/usr/local/bin/nvim"
    sudo mkdir -p "$BASE_DIR"

    # 3. 獲取遠端版本
    local remote_tag=$(curl -s "https://api.github.com/repos/neovim/neovim/releases/latest" | jq -r '.tag_name')
    local TARGET_APPIMAGE="$BASE_DIR/nvim-${remote_tag}.appimage"

    # 4. 檢查「該版本」是否已存在
    if [ ! -f "$TARGET_APPIMAGE" ]; then
        echo "🚀 Downloading Neovim $remote_tag..."
        local download_url="https://github.com/neovim/neovim/releases/download/${remote_tag}/nvim-linux-${nvim_arch}.appimage"
        sudo curl -fLo "$TARGET_APPIMAGE" "$download_url"
        sudo chmod +x "$TARGET_APPIMAGE"
    else
        echo "📦 Version $remote_tag already exists in $BASE_DIR."
    fi

    # 5. 更新連結 (Link Switching)
    # 檢查目前 link 指向哪裡，如果不是指向最新版才更新
    local current_link=$(readlink -f "$LINK_PATH" 2>/dev/null)
    if [ "$current_link" != "$TARGET_APPIMAGE" ]; then
        echo "🔗 Switching symlink to $remote_tag"
        sudo ln -sf "$TARGET_APPIMAGE" "$LINK_PATH"
        echo "✅ Neovim is now $remote_tag"
    else
        echo "✨ $LINK_PATH is already pointing to $remote_tag."
    fi
}

deploy_neovim_nightly() {
    deploy_neovim_nightly() {
    echo "--- [Nightly] Neovim 0.12 Versioned ---"

    local arch=$(uname -m)
    local nvim_arch="x86_64"
    [[ "$arch" == "aarch64" ]] && nvim_arch="arm64"
    
    local BASE_DIR="/opt/nvim-releases"
    local LINK_PATH="/usr/local/bin/nvim"
    local DATE_TAG=$(date +%Y%m%d)
    local TARGET_APPIMAGE="$BASE_DIR/nvim-nightly-${DATE_TAG}.appimage"

    # 1. 檢查今日版是否已下載
    if [ ! -f "$TARGET_APPIMAGE" ]; then
        echo "🚀 Downloading today's Nightly (0.12-dev)..."
        local download_url="https://github.com/neovim/neovim/releases/download/nightly/nvim-linux-${nvim_arch}.appimage"
        sudo curl -fLo "$TARGET_APPIMAGE" "$download_url"
        sudo chmod +x "$TARGET_APPIMAGE"
    fi

    # 2. 切換連結
    sudo ln -sf "$TARGET_APPIMAGE" "$LINK_PATH"
    echo "✅ Switched to Nightly ($DATE_TAG)"
}
    echo "--- [Nightly] Neovim 0.12 Versioned ---"

    local arch=$(uname -m)
    local nvim_arch="x86_64"
    [[ "$arch" == "aarch64" ]] && nvim_arch="arm64"
    
    local BASE_DIR="/opt/nvim-releases"
    local LINK_PATH="/usr/local/bin/nvim"
    local DATE_TAG=$(date +%Y%m%d)
    local TARGET_APPIMAGE="$BASE_DIR/nvim-nightly-${DATE_TAG}.appimage"

    # 1. 檢查今日版是否已下載
    if [ ! -f "$TARGET_APPIMAGE" ]; then
        echo "🚀 Downloading today's Nightly (0.12-dev)..."
        local download_url="https://github.com/neovim/neovim/releases/download/nightly/nvim-linux-${nvim_arch}.appimage"
        sudo curl -fLo "$TARGET_APPIMAGE" "$download_url"
        sudo chmod +x "$TARGET_APPIMAGE"
    fi

    # 2. 切換連結
    sudo ln -sf "$TARGET_APPIMAGE" "$LINK_PATH"
    echo "Switched to Nightly ($DATE_TAG)"
}

# 升級版 GitHub Fallback 安裝器
install_from_github() {
    local repo=$1
    local app=$2
    local file_type=$3   # tar.gz, deb, gz
    local method=$4      # binary, dpkg, gz_binary
    
    echo "Package '$app' not found or outdated. Falling back to GitHub ($repo)..."

    # 1. 統一處理架構偵測
    local arch
    arch=$(uname -m)
    if [ "$arch" = "x86_64" ]; then
        [ "$file_type" = "deb" ] && arch="amd64" || arch="x86_64"
        # 針對 tree-sitter 官方命名的微調 (官方用 linux-x64.gz)
        [ "$app" = "tree-sitter" ] && arch="x64" 
    elif [ "$arch" = "aarch64" ] || [ "$arm64" = "arm64" ]; then
        arch="arm64"
    else
        [ "$file_type" = "deb" ] && arch="amd64" || arch="x86_64"
    fi

    # 2. 透過 GitHub API 拿最新的 Tag 名稱
    local version
    version=$(curl -s "https://api.github.com/repos/${repo}/releases/latest" | grep -Po '"tag_name": "\K[^"]*')
    if [ -z "$version" ]; then
        echo "Error: 無法取得 GitHub 最新 $app 版本。"
        return 1
    fi

    # 3. 過濾出下載 URL
    local download_url
    download_url=$(curl -s "https://api.github.com/repos/${repo}/releases/latest" \
        | grep -oP '"browser_download_url": "\K[^"]*' \
        | grep -i "$arch" \
        | grep -i "$file_type" \
        | head -n 1)

    if [ -z "$download_url" ]; then
        echo "Error: 在 GitHub 上找不到適合 ${arch} 的 ${file_type} 安裝檔。"
        return 1
    fi

    echo "Downloading $app ($version) from: $download_url"

    # 4. 根據不同的安裝方式進行安裝
    if [ "$method" = "binary" ]; then
        local temp_tar="temp_${app}.tar.gz"
        curl -sLo "$temp_tar" "$download_url"
        tar -xf "$temp_tar" "$app" 2>/dev/null || tar -xf "$temp_tar" -C ./ 2>/dev/null
        if [ -f "$app" ]; then
            sudo install "$app" /usr/local/bin
            rm -f "$app"
        fi
        rm -f "$temp_tar"
        echo "$app installed successfully!"

    elif [ "$method" = "gz_binary" ]; then
        local temp_gz="temp_${app}.gz"
        curl -sLo "$temp_gz" "$download_url"
        gunzip -f "$temp_gz"
        # 解壓後會得到 temp_app，直接將它 rename 並 install 到 /usr/local/bin
        if [ -f "temp_${app}" ]; then
            sudo install "temp_${app}" "/usr/local/bin/${app}"
            rm -f "temp_${app}"
        fi
        echo "$app (.gz) installed successfully!"

    elif [ "$method" = "dpkg" ]; then
        local temp_deb="temp_${app}.deb"
        curl -sLo "$temp_deb" "$download_url"
        sudo dpkg -i "$temp_deb" >/dev/null 2>&1 || sudo apt-get install -f -y >/dev/null 2>&1
        rm -f "$temp_deb"
        echo "$app (.deb) installed successfully!"
    fi
}

deploy_linux_apps() {
    echo "--- Checking Linux Packages ---"
    local apps=(
        "git" "zoxide" "fzf" "ripgrep" "tmux" "zsh" "fuse3"
        "rsync" "curl" "unzip" "jq" "poppler-utils" 
        "imagemagick" "ffmpeg" "p7zip-full" "fd-find" "gh"
        "chafa" "lazygit" "fastfetch" "gettext"
        "python3" "python3-pip" "python3-venv"
    )

    if [ -f /etc/debian_version ]; then
        if apt-cache show git-delta >/dev/null 2>&1; then
            apps+=("git-delta")
            echo "Found 'git-delta' in apt repository."
        elif apt-cache show delta >/dev/null 2>&1; then
            apps+=("delta")
            echo "Found 'delta' in apt repository."
        else
            echo "Warning: Neither 'delta' nor 'git-delta' found in apt."
            # 如果你真的很需要它，可以考慮用之前提過的手動下載 .deb 邏輯
        fi
    else
        apps+=("git-delta")
    fi

    if [ -f /etc/debian_version ]; then
        # Ubuntu / Debian 叫 tree-sitter-cli
        apps+=("tree-sitter-cli")
    elif command -v brew >/dev/null 2>&1; then
        # macOS Homebrew 叫 tree-sitter
        apps+=("tree-sitter")
    else
        # Arch Linux (pacman) 或 Fedora (dnf) 通常直接叫 tree-sitter
        apps+=("tree-sitter")
    fi

    for app in "${apps[@]}"; do
        # 將 tree-sitter-cli 在內部統一對齊為 tree-sitter 進行檢測
        local check_cmd="$app"
        [ "$app" = "tree-sitter-cli" ] && check_cmd="tree-sitter"

        # 核心防禦：如果指令不存在，或者它是 tree-sitter 但「版本太舊不支援 build」
        if ! command -v "$check_cmd" >/dev/null 2>&1 || \
           { [ "$check_cmd" = "tree-sitter" ] && ! tree-sitter build --help >/dev/null 2>&1; }; then
            
            # 特殊處理 A：fd-find 的指令名稱是 fdfind
            if [ "$app" = "fd-find" ] && command -v fdfind >/dev/null 2>&1; then
                continue
            fi

            # 🛠️ 嘗試用系統包管理器安裝 (如果本來就有舊版，我們跳過此步，直接走 GitHub 升級)
            local apt_success=false
            if [ "$check_cmd" != "tree-sitter" ]; then
                if install_pkg "$app" >/dev/null 2>&1; then
                    apt_success=true
                fi
            fi

            if [ "$apt_success" = "false" ]; then
                
                # 一行指令搞定 Tree-sitter 完美升級/安裝
                if [ "$app" = "tree-sitter" ] || [ "$app" = "tree-sitter-cli" ]; then
                    install_from_github "tree-sitter/tree-sitter" "tree-sitter" "gz" "gz_binary"
                    continue
                fi

                # 一行指令搞定 Lazygit
                if [ "$app" = "lazygit" ]; then
                    install_from_github "jesseduffield/lazygit" "lazygit" "tar.gz" "binary"
                    continue
                fi

                # 一行指令搞定 Fastfetch
                if [ "$app" = "fastfetch" ]; then
                    install_from_github "fastfetch-cli/fastfetch" "fastfetch" "deb" "dpkg"
                    continue
                fi

                echo "Error: $app 安裝失敗。"
            fi
        fi
    done

    # 2. 修正 fd 指令連結 (Yazi 需要指令名為 fd)
    if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
        echo "Creating symlink for fd..."
        safe_link "$(command -v fdfind)" /usr/local/bin/fd
    fi    
    # Yazi 建議手動安裝最新版，此處僅提醒
echo "--- Installing Apps (Yazi) ---"
    if ! command -v yazi >/dev/null 2>&1; then
        echo "Fetching latest Yazi download URL..."
        local yazi_url
        yazi_url=$(curl -s "https://api.github.com/repos/sxyazi/yazi/releases/latest" \
            | grep -oP '"browser_download_url": "\K[^"]*x86_64-unknown-linux-gnu\.zip')

        if [ -n "$yazi_url" ]; then
            echo "Downloading Yazi from: $yazi_url"
            if curl -fLo /tmp/yazi.zip "$yazi_url"; then
                unzip -q -o /tmp/yazi.zip -d /tmp/yazi_out
                sudo mv /tmp/yazi_out/yazi-*/yazi /usr/local/bin/
                sudo mv /tmp/yazi_out/yazi-*/ya /usr/local/bin/
                sudo chmod +x /usr/local/bin/yazi /usr/local/bin/ya
                rm -rf /tmp/yazi.zip /tmp/yazi_out
                echo "Successfully installed Yazi!"
            else
                echo "Error: Yazi download failed!"
            fi
        else
            echo "Error: Could not retrieve Yazi download URL."
        fi
    else
        echo "Yazi is already installed."
    fi

    # 8. 安裝 StyLua (全域預備，從 GitHub API 抓 Linux x86_64 二進位檔)
    if ! command -v stylua >/dev/null 2>&1; then
        echo "Installing StyLua (Lua Formatter)..."
        local stylua_url
        stylua_url=$(curl -s "https://api.github.com/repos/JohnnyMorganz/StyLua/releases/latest" \
            | grep -oP '"browser_download_url": "\K[^"]*linux-x86_64\.zip')

        if [ -n "$stylua_url" ]; then
            if curl -fLo /tmp/stylua.zip "$stylua_url"; then
                unzip -q -o /tmp/stylua.zip -d /tmp/
                sudo mv /tmp/stylua /usr/local/bin/
                sudo chmod +x /usr/local/bin/stylua
                rm -f /tmp/stylua.zip
                echo "Successfully installed StyLua!"
            fi
        fi
    fi

    # 處理名稱怪異的工具
    # fd 在 Ubuntu 叫 fd-find
    # if ! command -v fd >/dev/null 2>&1; then
    #     if command -v apt-get >/dev/null 2>&1; then
    #         echo "Installing fd-find for Ubuntu/Debian..."
    #         install_pkg "fd-find"
            
    #         # 建立軟連結到 /usr/local/bin (這通常在 $PATH 內且優於 /usr/bin)
    #         # 這樣你就可以直接打 'fd' 而不是 'fdfind'
    #         if [ ! -f /usr/local/bin/fd ]; then
    #             sudo ln -sf "$(command -v fdfind)" /usr/local/bin/fd
    #         fi
    #     else
    #         # 其他發行版 (Arch, macOS) 通常直接叫 fd
    #         install_pkg "fd"
    #     fi
    # fi
    if ! command -v bat >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            install_pkg "bat"
            if [ ! -f /usr/local/bin/bat ]; then
                safe_link "$(command -v batcat)" /usr/local/bin/bat
            fi
        fi
    fi


    if ! command -v eza >/dev/null 2>&1; then
        echo "Installing eza (modern ls)..."
        # 這是 Debian/Ubuntu 的官方推薦安裝方式（處理 GPG key 與 repo）
        sudo mkdir -p /etc/apt/keyrings
        wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc | sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
        echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" | sudo tee /etc/apt/sources.list.d/gierens.list
        sudo chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
        sudo apt update
        sudo apt install -y eza
    fi

}

deploy_wsl_conf() {
    [ -f /etc/wsl.conf ] && echo "/etc/wsl.conf exits!" && return
    echo "--- Deploying /etc/wsl.conf ---"
    
    local CURRENT_USER=$(whoami)
    local HOST_NAME="paswsl"
    # 如果以後要變動 boot command，可以在這裡定義
    local BOOT_CMD="/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command \"wsl -d pve --mount --vhd D:/Wsl/disk/wsl-pve.vhdx --bare\""

    # 使用 sed 渲染並寫入臨時文件，再 sudo 搬移
    sed -e "s|{{BOOT_COMMAND}}|$BOOT_CMD|g" \
        -e "s|{{HOSTNAME}}|$HOST_NAME|g" \
        -e "s|{{DEFAULT_USER}}|$CURRENT_USER|g" \
        "$DOT_ROOT/windows/wsl.conf.tmpl" > /tmp/wsl.conf

    # 檢查是否與現有的不同，減少不必要的寫入
    if ! diff /tmp/wsl.conf /etc/wsl.conf > /dev/null 2>&1; then
        echo "Updating /etc/wsl.conf (Root required)..."
        sudo mv /tmp/wsl.conf /etc/wsl.conf
        sudo chown root:root /etc/wsl.conf
        NEED_RESTART=true
    else
        echo "/etc/wsl.conf is already up-to-date."
    fi
}

deploy_bash_config() {
    # 這裡可以用 local 了
    local extra_path="$DOT_ROOT/config/bash/bashrc_extra.sh"
    local loader_line="[ -f $extra_path ] && source $extra_path"
    local bashrc="$HOME/.bashrc"

    echo "--- Configuring .bashrc ---"

    # 檢查是否已經有這一行，避免重複寫入
    if ! grep -qF "/config/bash/bashrc_extra.sh" "$bashrc"; then
        echo -e "\n# Added by dotfiles deploy script\n$loader_line" >> "$bashrc"
        echo "Linked $extra_path to $bashrc"
    else
        echo ".bashrc is already linked to extra config."
    fi    
}


link_config() {
    local name=$1
    local source_path="$DOT_ROOT/config/$name"
    local target_path="$CONFIG_HOME/$name"

    echo "--------------------------------------"
    echo "Processing config for: $name"

    # 1. 檢查來源路徑是否存在，避免連結到空氣
    if [ ! -e "$source_path" ]; then
        echo "❌ Error: Source $source_path does not exist. Skipping."
        return 1
    fi

    safe_link "$source_path" "$target_path" 
    return
    # 2. 處理現有的目標檔案/目錄
    if [ -L "$target_path" ]; then
        # 如果是 Symbolic Link，直接移除
        echo "🔗 Removing existing symbolic link..."
        rm "$target_path"
    elif [ -d "$target_path" ] || [ -f "$target_path" ]; then
        # 如果是真實目錄或檔案，進行備份
        local backup="${target_path}_backup_$(date +%Y%m%d_%H%M%S)"
        echo "📦 Found real directory/file. Backing up to: $backup"
        mv "$target_path" "$backup"
    fi

    # 3. 建立連結
    # 使用 ln -s <來源實體路徑> <目標連結路徑>
    ln -s "$source_path" "$target_path"
    echo "✅ Linked $name to $target_path"
}

# 輔助函式：確保 Link 的冪等性
safe_link() {
    local src="$1"
    local dst="$2"
    
    # 確保 source 存在，否則 link 會壞掉
    if [[ ! -e "$src" ]]; then
        echo "Error: Source $src does not exist."
        return 1
    fi

    # 判斷是否已經正確連結
    if [[ -L "$dst" && "$(readlink -f "$dst")" == "$(readlink -f "$src")" ]]; then
        # 額外檢查：如果是目錄，確保目標確實是目錄
        echo "✅ Linked ($dst -> $src) existing symbolic link..., Skipping"
        return 0
    fi

    echo "Linking $dst -> $src"
    
    # 判斷目標路徑是否需要 sudo (如果目錄不可寫入)
    local target_dir=$(dirname "$dst")
    if [[ -w "$target_dir" ]]; then
        ln -sf "$src" "$dst"
    else
        sudo ln -sf "$src" "$dst"
    fi
}


deploy_git() {
    echo "--- Deploy git ---"
    
    # 1. 處理 Link (不浪費)
    safe_link "$DOT_ROOT/git/.gitconfig" "$USER_HOME/.gitconfig"
    safe_link "$DOT_ROOT/git/.gitconfig.shared" "$USER_HOME/.gitconfig.shared"
    safe_link "$DOT_ROOT/git/.gitignore.global" "$USER_HOME/.gitignore.global"
    safe_link "$DOT_ROOT/git/.gitattributes" "$USER_HOME/.gitattributes"


    # 2. 準備動態內容
    local credential=""
    if command -v git-credential-manager.exe >/dev/null 2>&1; then
        credential="[credential]
    helper = $SCOOP_ROOT/apps/git/current/mingw64/bin/git-credential-manager.exe"
    fi

    if [[ "$IS_WSL" = true && -n "$SCOOP_ROOT" ]] ; then
        # 建立新的內容字串
        local new_content=$(cat <<EOF
[safe]
    directory = $DOT_ROOT
$credential
EOF
)
        
        # 3. 檢查 .gitconfig.local 是否需要更新
        local local_config="$USER_HOME/.gitconfig.local"
        if [[ -f "$local_config" ]]; then
            local old_content=$(cat "$local_config")
            if [[ "$new_content" == "$old_content" ]]; then
                echo ".gitconfig.local is already up-to-date. Skipping."
                return 0
            fi
        fi

        # 內容不同或檔案不存在才寫入
        echo "Updating .gitconfig.local..."
        echo "$new_content" > "$local_config"
    fi    
}


deploy_ssh() {
    echo "--- Deploy SSH config ---"
    local ssh_dir="$USER_HOME/.ssh"
    local target="$ssh_dir/config"
    local socket_dir="$ssh_dir/sockets"
    local source="$DOT_ROOT/config/ssh/config"

    # 確保目錄存在且權限正確 (700)
    if [ ! -d "$ssh_dir" ]; then
        mkdir -p "$ssh_dir"
        chmod 700 "$ssh_dir"
    fi

    if [ ! -d "$socket_dir" ]; then
        echo "Creating sockets directory..."
        mkdir -p "$socket_dir"
        chmod 700 "$socket_dir"
    fi

    # 如果已經存在且不是 symlink，先備份
    if [ -f "$target" ] && [ ! -L "$target" ]; then
        echo "Backing up existing ssh config to $target.bak"
        mv "$target" "$target.bak"
    fi

    # 建立連結
    ln -sf "$source" "$target"
    # SSH Config 檔案權限必須是 600
    chmod 600 "$source"
}

check_and_install_zfs() {
    echo "--- Checking ZFS Support (Built-in or Module) ---"

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local virt_type=$(systemd-detect-virt)
        if [ "$virt_type" = "lxc" ]; then
            echo "🔹 偵測到 LXC Container，跳過 ZFS。"
            return 0
        fi
    fi


    # 1. 檢查核心是否支援 ZFS
    # 方法 A: 檢查 /proc/filesystems 是否有 zfs 註冊
    # 方法 B: 檢查 /sys/module/zfs 目錄是否存在 (內建或已載入模組都會有)
    local has_zfs=0
    if grep -q "zfs" /proc/filesystems || [ -d "/sys/module/zfs" ]; then
        has_zfs=1
    fi

    # 2. 如果核心沒反應，嘗試載入（以防它是模組但還沒載入）
    if [ $has_zfs -eq 0 ]; then
        if modprobe zfs >/dev/null 2>&1; then
            has_zfs=1
        fi
    fi

    # 3. 判斷是否安裝工具
    if [ $has_zfs -eq 1 ]; then
        if ! command -v zpool >/dev/null 2>&1; then
            echo "📦 ZFS kernel support detected, but zpool tools are missing. Installing..."
            install_pkg zfsutils-linux
        else
            echo "✅ ZFS support and tools are both ready."
        fi
    else
        echo "⏭️ ZFS is not supported by this kernel. Skipping installation."
    fi
}

check_fuse_and_install() {
    # 1. 確保工具已安裝 (不管在哪，工具都是必須的)
    # if ! command -v mount.fuse3 >/dev/null 2>&1; then
    #     install_pkg fuse3 libfuse2
    # fi

    # 2. 診斷設備節點 (只有在 CT 或實體機才需要)
    if [ ! -c /dev/fuse ]; then
        echo "❌ FUSE device (/dev/fuse) is missing!"
        if [ "$(systemd-detect-virt)" = "lxc" ]; then
            echo "💡 [Action Required] This is an LXC. Run this on PVE HOST and REBOOT CT:"
            echo "   pct set $CTID -features fuse=1"
        else
            echo "💡 [Action Required] Try: sudo modprobe fuse"
        fi
    else
        echo "✅ FUSE device is ready."
    fi
}

deploy_zsh_config() {
    echo "--- Configuring Zsh ---"
    
    # 1. 確保 zsh 已安裝 (雙重保險)
    if ! command -v zsh >/dev/null 2>&1; then
        install_pkg zsh
    fi
    # 2. 建立 .zshrc 的連結 (參考你 .bashrc 的邏輯)
    # 假設你的 dotfiles 裡也有一個 .zshrc
    [ -f "$USER_HOME/.zshrc" ] && [ ! -L "$USER_HOME/.zshrc" ] && mv "$USER_HOME/.zshrc" "$USER_HOME/.zshrc.bak"
    safe_link "$DOT_ROOT/core/.zshrc" "$USER_HOME/.zshrc"
    local ZSH_TARGET_DIR="$USER_HOME/.local/share/zsh-plugins"
    mkdir -p "$ZSH_TARGET_DIR"

    safe_link "$DOT_ROOT/config/shell/zsh/plugins/zsh-autosuggestions" "$ZSH_TARGET_DIR/"
    safe_link "$DOT_ROOT/config/shell/zsh/plugins/zsh-syntax-highlighting" "$ZSH_TARGET_DIR/"
}

# ----------------------------------------------------------------
# Function: deploy_node_via_fnm
# 描述: 跨平台/WSL 部署最新版 fnm 與 Node.js 穩定版 (免代號無痛版)
# ----------------------------------------------------------------
deploy_node_via_fnm() {
    echo "--- Checking Node.js Environment (via fnm) ---"
    
    set +e

    # 1. 建立通用個人 bin 目錄 (確保 ~/.local/bin 存在)
    mkdir -p "$HOME/.local/bin"

    # 2. 檢查並安裝 fnm
    if [ ! -d "$HOME/.local/share/fnm" ] && ! command -v fnm >/dev/null 2>&1; then
        echo "Installing fnm (Fast Node Manager)..."
        curl -fsSL https://fnm.vercel.app/install | bash
    else
        echo "fnm is already installed."
    fi

    # 3. 匯入 PATH 並初始化 fnm
    export PATH="$HOME/.local/share/fnm:$PATH"
    if command -v fnm >/dev/null 2>&1; then
        eval "$(fnm env --shell bash)"
    else
        echo "Error: fnm 載入失敗，跳過 Node.js 安裝。"
        set -e
        return 0
    fi

    # 4. 安裝 Node.js LTS 並設為預設
    echo "Installing Node.js LTS version via fnm..."
    fnm install --lts
    fnm default lts-latest
    fnm use lts-latest

    # 5. 將 fnm 的當前 node/npm 硬連結到 ~/.local/bin 作為安全防禦 (針對非 interactive shell)
    local fnm_node_path
    fnm_node_path=$(fnm current 2>/dev/null)
    
    if [ -n "$fnm_node_path" ]; then
        echo "Node.js ($fnm_node_path) is now set as default via fnm."
        echo "   node path: $(which node)"
        echo "   npm path:  $(which npm)"
    else
        echo "Warning: fnm 切換失敗。"
    fi

    set -e
}

check_and_install_zfs
deploy_linux_apps
deploy_node_via_fnm
check_fuse_and_install

echo "Checking git submodules..."
try_run "更新 Git 子模組" git submodule update --init --recursive

NVIM_RELEASE_CHANNEL="stable"  # 可選 "stable" 或 "nightly"
if [ "$NVIM_RELEASE_CHANNEL" = "nightly" ]; then
    deploy_neovim_nightly
else
    deploy_neovim_stable
fi


# --- 5. 執行流程 ---
echo "--- Linking Core Configs ---"
[ ! -d "$USER_HOME/.config" ] && mkdir -p "$USER_HOME/.config"

#ln -sf "$DOT_ROOT/core/.bashrc" "$USER_HOME/.bashrc"
[ -f $USER_HOME/.bashrc ] && cp $USER_HOME/.bashrc $USER_HOME/.bashrc.org && rm $USER_HOME/.bashrc
safe_link  "$DOT_ROOT/core/.bashrc" "$USER_HOME/.bashrc"
[ ! -f $USER_HOME/.profile ] && safe_link  "$DOT_ROOT/core/.profile" "$USER_HOME/.profile"

deploy_zsh_config
deploy_ssh
deploy_git

safe_link "$DOT_ROOT/tmux/.tmux.conf" "$USER_HOME/.tmux.conf"


CONFIG_HOME="$USER_HOME/.config"
# 確保 .config 目錄存在
mkdir -p "$CONFIG_HOME"

# 注意：這裡要把整個 yazi 資料夾連進 .config/

configs=("yazi" "nvim" "wezterm" "gh" "lazygit")

for app in "${configs[@]}"; do
    link_config "$app"
done

# TARGET_DIR="$USER_HOME/.config/yazi"
# SOURCE_DIR="$DOT_ROOT/config/yazi"
# # 2. 處理現有的檔案/目錄
# if [ -L "$TARGET_DIR" ]; then
#     # 如果已經是一個 Symbolic Link，直接刪除它，準備換新的
#     rm "$TARGET_DIR"
# elif [ -d "$TARGET_DIR" ]; then
#     # 如果它是一個真實目錄而非 Link，為了安全，先備份
#     mv "$TARGET_DIR" "${TARGET_DIR}_backup_$(date +%Y%m%d)"
# fi

# # 3. 建立連結
# ln -sf "$SOURCE_DIR" "$USER_HOME/.config/"
# echo "Yazi config linked to $TARGET_DIR"


#deploy_bash_config
deploy_starship

# D. WSL / Windows 特有部署

if [ "$IS_WSL" = true ]; then
    # 設定 Windows 路徑變數    
    SCOOP_ETC="$SCOOP_ROOT/etc"
    DOT_ROOT="$SCOOP_ETC/dotfiles"
    CMD="$WIN_DIR_BASE/System32/cmd.exe"
    RUNTIME_DIR="$SCOOP_ETC/wsl_runtime"
    WIN_USERPROFILE_RAW=$($CMD /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r')
    WIN_HOME_PATH=$(wslpath "$WIN_USERPROFILE_RAW")

    echo "Using Windows PS: $WIN_PS"
    deploy_kernel
    render_wslconfig
    deploy_wsl_conf
    
    # 呼叫原生 Windows 部署 (Scoop, Fonts, Win-links)
    "$WIN_PS" -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$DOT_ROOT/scripts/deploy.ps1")"    
    # $CMD /c "powershell -ExecutionPolicy Bypass -File D:\Scoop\etc\dotfiles\scripts\deploy.ps1"
fi


echo "Done! Environment: $( [ "$IS_WSL" = true ] && echo 'WSL' || echo 'Pure Linux' )"

if [ "$NEED_RESTART" = true ]; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "KERNEL UPDATED: Please run 'wsl.exe --shutdown' in Win"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
fi

