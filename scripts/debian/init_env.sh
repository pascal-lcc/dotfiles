#!/bin/bash
# --- 顏色定義 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SUDO_KEEP_ALIVE_PID=""
cleanup() {
    echo -e "\n${YELLOW}[Interrupt]${NC} 正在清理並結束腳本..."
    
    # 1. 殺掉背景續期程序
    if [ -n "$SUDO_KEEP_ALIVE_PID" ]; then
        kill "$SUDO_KEEP_ALIVE_PID" 2>/dev/null
    fi
    
    # 2. 恢復終端機標準狀態 (stty sane 是好習慣)
    stty sane 2>/dev/null
    
    # 3. 🌟 關鍵：給予明確的結束狀態，否則腳本可能會繼續往下走
    exit 1
}

# 捕捉 INT (Ctrl+C) 和 TERM 訊號
trap cleanup INT TERM

# --- 0. 權限預檢 ---
if [ "$EUID" -ne 0 ]; then
    echo "Requesting sudo..."
    sudo -v
    # 修正：將背景續期程序的 PID 存起來
    ( while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done ) 2>/dev/null &
    SUDO_KEEP_ALIVE_PID=$!
fi


# --- 1. 語系處理 (Idempotent) ---
setup_locales() {
    local TARGET="en_US.UTF-8"
    if ! dpkg -s locales >/dev/null 2>&1; then
        apt-get update && apt-get install -y locales
    fi
    if ! locale -a | grep -qi "${TARGET//-}"; then
        sed -i "s/^# \(${TARGET} UTF-8\)/\1/" /etc/locale.gen
        locale-gen "$TARGET"
    fi
    if [[ "$LANG" != "$TARGET" ]]; then
        update-locale LANG="$TARGET" LC_ALL="$TARGET"
        export LANG="$TARGET" LC_ALL="$TARGET"
    fi
}

# --- 2. 管理員建立 (Interactive & Idempotent) ---
add_admin_user() {
    # 1. 優先檢查是否有任何使用者在 sudo 群組
    local EXISTING_SUDOER=$(getent group sudo | cut -d: -f4 | tr ',' '\n' | head -n 1)
    
    # 2. 或者檢查 UID 1000 是否存在 (通常是第一個一般用戶)
    local UID_1000_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' | head -n 1)

    # 只要滿足其中一個條件，就代表「這台機器已經有主人了」
    local MASTER_USER="${EXISTING_SUDOER:-$UID_1000_USER}"

    if [ -n "$MASTER_USER" ]; then
        echo -e "${GREEN}[OK]${NC} 偵測到現有管理員: $MASTER_USER，自動跳過建立流程。"
        # 將現有使用者名稱導出給後續腳本使用 (例如設定 dotfiles)
        CURRENT_USER="$MASTER_USER"
        return 0
    fi
    read -p "Enter admin username [pascual]: " UNAME
    UNAME=${UNAME:-pascual}

    # 安裝必要套件
    if ! dpkg -s sudo zsh >/dev/null 2>&1; then
        apt-get update && apt-get install -y sudo zsh
    fi

    # 建立使用者
    if ! id "$UNAME" &>/dev/null; then
        echo -e "${GREEN}[Action]${NC} Creating user $UNAME..."
        # 注意：如果 /home 已經從 PVE 掛載進來，這裡會直接使用它
        useradd -m -s /bin/zsh "$UNAME"
        echo -e "${YELLOW}Please set password for $UNAME:${NC}"
        passwd "$UNAME"
    fi

    # 授權 Sudo (建立獨立 sudoers 檔案避免弄髒主設定)
    if [ ! -f "/etc/sudoers.d/$UNAME" ]; then
        echo "$UNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$UNAME"
        chmod 0440 "/etc/sudoers.d/$UNAME"
    fi
}

setup_sshd() {
    local CONF="/etc/ssh/sshd_config"
    
    # 1. 靜默安裝
    dpkg -s openssh-server &>/dev/null || apt-get install -y openssh-server

    # 2. 使用一個 Sub-shell 來做變更偵測，避免弄髒主環境
    local CHANGED=0
    local TMP=$(mktemp)
    cp "$CONF" "$TMP"

    # 精準取代 (只在必要時變動)
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$TMP"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$TMP"
    
    # 比對，只有不同才執行更新與重載
    if ! diff -q "$CONF" "$TMP" &>/dev/null; then
        if /usr/sbin/sshd -t -f "$TMP"; then
            cat "$TMP" > "$CONF"
            systemctl reload ssh &>/dev/null || service ssh reload &>/dev/null
            echo -e "${GREEN}[Success]${NC} SSHD updated and reloaded."
            CHANGED=1
        fi
    fi
    rm -f "$TMP"
    
    [ "$CHANGED" -eq 0 ] && echo -e "${GREEN}[OK]${NC} SSHD is already optimized."
}


# --- 執行順序 ---
setup_locales
add_admin_user
setup_sshd

echo -e "${GREEN}CT Initial Setup Complete!${NC}"

# 腳本正常結束時，也要清理背景程序
if [ -n "$SUDO_KEEP_ALIVE_PID" ]; then
    kill "$SUDO_KEEP_ALIVE_PID" 2>/dev/null
fi

