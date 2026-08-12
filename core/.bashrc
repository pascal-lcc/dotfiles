# 若非互動式則退出 (這行很重要，維持原樣)
case $- in *i*) ;; *) return;; esac

umask 022 
set -o notify 
shopt -s execfail
set -o vi

stty iutf8
stty -ixon

# 1. 取得目前腳本的絕對路徑 (相容 Bash & Zsh)
if [ -n "$ZSH_VERSION" ]; then
    _CURRENT_FILE="${(%):-%N}"
else
    _CURRENT_FILE="${BASH_SOURCE[0]}"
fi

# 使用 readlink 取得完整路徑 (realpath 作為保底)
_FULL_PATH=$(readlink -f "$_CURRENT_FILE" 2>/dev/null || realpath "$_CURRENT_FILE" 2>/dev/null)

# 2. 抓取到 "dotfiles" 為止的所有字元 (不使用 Regex 陣列)
# 邏輯：利用 %% (從右邊開始刪除最長匹配)，砍掉 /dotfiles 之後的所有東西
if [[ "$_FULL_PATH" == *"/dotfiles"* ]]; then
    export MY_DOTFILES_ROOT="${_FULL_PATH%%/dotfiles*}/dotfiles"
    
    # 順便連 RUNTIME_DIR 都有了 (dotfiles 的上一層)
    export RUNTIME_DIR="${MY_DOTFILES_ROOT%/*}"
    
    # 建立快捷 Alias
    alias dot="cd $MY_DOTFILES_ROOT"
fi

export XDG_CONFIG_HOME="$HOME/.config"
# 清理暫存變數
unset _CURRENT_FILE _FULL_PATH

#export PATH=$(echo $PATH | tr ':' '\n' | grep -v '/mnt/' | tr '\n' ':' | sed 's/:$//')
## 強制關閉 Bash 嘗試搜尋 PATH 來做補全的行為
#shopt -u progcomp

CURRENT_USER=${USER:-$(id -un)}


# 根據 UID 判斷顏色，但只設定一次 PS1
if [ "$CURRENT_USER" = "root" ]; then
    COLOR_USER="1;31" # 紅色
else
    COLOR_USER="1;32" # 綠色
fi

# 最終版 PS1 (簡潔且包含換行)
#  = \uf2bd,  = \uf07c
PS1='\n\[\e[${COLOR_USER};48;5;236m\]  \u@\h \[\e[0;37;48;5;24m\]  \w \[\e[0m\] \[\e[0;37m\] \t \[\e[0m\]\n\$ '

# 2. 強制設定模式顯示與游標 (用 bind 確保無視 .inputrc)
if [[ $- == *i* ]]; then
    bind 'set show-mode-in-prompt on'
    # 建議：將圖示放在最前面，並確保後方有一個空格
    # \1\e[...m\2 是告知 Readline 這是不可見的控制碼（計算長度時排除）
    
    # 插入模式：亮綠色
    bind 'set vi-ins-mode-string "\1\e[1;32m\2󰏫 (I)\1\e[0m\2 "'
    
    # 一般模式：淡紫色
    bind 'set vi-cmd-mode-string "\1\e[1;35m\2󰌌 (N)\1\e[0m\2 "'

    # 靈敏度設定 (重要：10ms 才是真正的 vi 體感)
    bind 'set keyseq-timeout 10'
    
    # === 2. 精緻色塊 PS1 (Nerd Font 版) ===
    # 格式：[時間] 使用者@主機 (色塊) 路徑 (色塊)

    # bind 'set show-mode-in-prompt on'
    # bind 'set vi-ins-mode-string "\1\e[0;30;42m\2 I \1\e[0m \2"'
    # bind 'set vi-cmd-mode-string "\1\e[0;30;47m\2 N \1\e[0m \2"'
    # 讓按 ESC 切換模式更靈敏 (預設 400ms 改為 10ms)
    bind 'set keyseq-timeout 10'
fi

[ -f "$MY_DOTFILES_ROOT/config/shell/common_all.sh" ] && source "$MY_DOTFILES_ROOT/config/shell/common_all.sh"


[ -f "$HOME/.bashrc_local" ] && source "$HOME/.bashrc_local"


