#!/usr/bin/env bash
set -e

if ! command -v git &> /dev/null; then
    echo "[!] 偵測到系統未安裝 git，正在嘗試自動安裝..."
    
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y git
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y git
    elif command -v pacman &> /dev/null; then
        sudo pacman -S --noconfirm git
    else
        echo "[-] 錯誤: 找不到可用的套件管理員 (apt/dnf/pacman)，請手動安裝 git 後再執行。"
        exit 1
    fi
fi

# 1. 互動式選擇 dotfiles 安裝目標目錄
echo "=================================================="
echo " 請選擇 dotfiles 的安裝目標目錄："
echo "   [1] $HOME/.dotfiles (預設隱藏目錄)"
echo "   [2] $HOME/dotfiles (一般目錄)"
echo "   [3] 自訂路徑 (Custom Path)"
echo "=================================================="
read -p "請輸入選項 [1-3] (預設 1): " choice

case "$choice" in
    2)
        DOTFILES_DIR="$HOME/dotfiles"
        ;;
    3)
        read -p "請輸入你想安裝的完整自訂父目錄或路徑: " custom_path
        custom_path=$(eval echo "$custom_path")
        
        # 確保自訂路徑的結尾一定是 dotfiles 或 .dotfiles
        if [[ "$custom_path" != *"/dotfiles" && "$custom_path" != *"/.dotfiles" ]]; then
            echo ""
            echo "請問要在該路徑下建立什麼名稱的資料夾？"
            echo "   [1] .dotfiles (隱藏目錄)"
            echo "   [2] dotfiles (一般目錄)"
            read -p "請選擇 [1-2] (預設 1): " sub_choice
            case "$sub_choice" in
                2)
                    DOTFILES_DIR="$custom_path/dotfiles"
                    ;;
                *)
                    DOTFILES_DIR="$custom_path/.dotfiles"
                    ;;
            esac
        else
            DOTFILES_DIR="$custom_path"
        fi
        ;;
    *)
        DOTFILES_DIR="$HOME/.dotfiles"
        ;;
esac

echo "[+] 目標安裝路徑確認為: $DOTFILES_DIR"
REPO_URL="https://github.com/pascal-lcc/dotfiles.git"

# 2. 檢查目標目錄是否存在，若存在則詢問是否覆蓋
if [ -d "$DOTFILES_DIR" ]; then
    echo ""
    echo "[!] 警告：目標目錄 $DOTFILES_DIR 已經存在！"
    read -p "是否要覆蓋並繼續進行安裝？(y/N): " confirm
    case "$confirm" in
        [yY][eE][sS]|[yY])
            echo "[*] 正在清除現有目錄並繼續安裝..."
            rm -rf "$DOTFILES_DIR"
            ;;
        *)
            echo "[*] 已取消操作，結束離開。"
            exit 0
            ;;
    esac
fi

echo "[>] 正在下載 dotfiles (含子模組)..."

# 3. 使用 --depth 1 快速複製主專案與子模組（省去龐大的歷史紀錄）
git clone --depth 1 --recurse-submodules "$REPO_URL" "$DOTFILES_DIR"

echo "[>] 正在清除所有 .git 紀錄，轉換為純淨資料夾..."

# 4. 關鍵步驟：遞迴尋找並刪除所有的 .git 檔案與資料夾
find "$DOTFILES_DIR" -name ".git" -type d -exec rm -rf {} +
find "$DOTFILES_DIR" -name ".gitmodules" -type f -exec rm -f {} +
# find "$DOTFILES_DIR" -name ".gitattributes" -type f -exec rm -f {} +
# find "$DOTFILES_DIR" -name ".gitignore" -type f -exec rm -f {} +

echo "[√] 已成功移除所有 Git 相關追蹤檔！"

# 5. 自動執行內部的 deploy.sh
if [ -f "$DOTFILES_DIR/scripts/deploy.sh" ]; then
    echo "[>] 正在執行部署腳本..."
    bash "$DOTFILES_DIR/scripts/deploy.sh"
else
    echo "[-] 找不到 deploy.sh，請手動執行。"
fi

