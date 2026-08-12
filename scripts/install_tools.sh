#!/bin/bash

# 安裝字體邏輯 (WSL 側觸發)
install_windows_fonts() {
    echo "Installing Nerd Fonts via Scoop..."
    # 這裡呼叫 Windows 的 scoop
    /mnt/c/Windows/System32/cmd.exe /c "scoop bucket add nerd-fonts"
    /mnt/c/Windows/System32/cmd.exe /c "scoop install JetBrainsMono-NF"

    echo "Installing Special Fonts from Dotfiles..."
    # 這裡可以用 PowerShell 把 fonts/*.ttf 複製到 Windows Fonts 目錄
    # 但最簡單的方法還是手動點開 dotfiles/fonts/ 裡面的檔案按安裝
}
