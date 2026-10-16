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


DOTFILES_DIR="$HOME/dotfiles"
REPO_URL="https://github.com/pascal-lcc/dotfiles.git"

echo "[>] 正在下載 dotfiles (含子模組)..."

# 1. 如果目錄已存在先備份或清空
if [ -d "$DOTFILES_DIR" ]; then
    rm -rf "$DOTFILES_DIR"
fi

# 2. 使用 --depth 1 快速複製主專案與子模組（省去龐大的歷史紀錄）
git clone --depth 1 --recurse-submodules "$REPO_URL" "$DOTFILES_DIR"

echo "[>] 正在清除所有 .git 紀錄，轉換為純淨資料夾..."

# 3. 關鍵步驟：遞迴尋找並刪除所有的 .git 檔案與資料夾
find "$DOTFILES_DIR" -name ".git" -type d -exec rm -rf {} +
find "$DOTFILES_DIR" -name ".gitmodules" -type f -exec rm -f {} +
# find "$DOTFILES_DIR" -name ".gitattributes" -type f -exec rm -f {} +
# find "$DOTFILES_DIR" -name ".gitignore" -type f -exec rm -f {} +

echo "[√] 已成功移除所有 Git 相關追蹤檔！"

# 4. 自動執行內部的 deploy.sh
if [ -f "$DOTFILES_DIR/scripts/deploy.sh" ]; then
    echo "[>] 正在執行部署腳本..."
    bash "$DOTFILES_DIR/scripts/deploy.sh"
else
    echo "[-] 找不到 deploy.sh，請手動執行。"
fi
