#!/bin/bash

IS_WSL=false
if [ -f /proc/sys/fs/binfmt_misc/WSLInterop ] || grep -qiE "(microsoft|wsl)" /proc/version; then
    IS_WSL=true
fi


# --- 1. 環境變數 (Environment Variables) ---
export LANG='en_US.UTF-8'
export EDITOR='vi'


# 讓 bat 變成預設的 PAGER


# --- 2. 工具初始化 (Tools Init) ---

# Starship 提示字元
if command -v starship >/dev/null 2>&1; then
    eval "$(starship init bash)"
fi

# Zoxide (取代 cd)
if command -v zoxide >/dev/null 2>&1; then
    eval "$(zoxide init bash)"
fi

# --- 3. FZF 配置 (FZF Setup) ---
# 自動找尋系統路徑中的 fzf 腳本 (適應不同發行版)
# 修改後的 bashrc_extra.sh
# ---------------------------------------
# 只載入快捷鍵 (CTRL+R / CTRL+T / ALT+C)
# [ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && source /usr/share/doc/fzf/examples/key-bindings.bash

# 註解掉下面這行，不要讓它接管 Tab 鍵

# ---------------------------------------

for fzf_script in \
    "/usr/share/doc/fzf/examples/key-bindings.bash" \
    "/usr/share/fzf/key-bindings.bash" \
    "/usr/share/fzf/shell/key-bindings.bash" \
    "/usr/share/doc/fzf/examples/completion.bash" ; do
    if [ -f "$fzf_script" ]; then
        source "$fzf_script"
        # 順便載入補全
        break
    fi
done

if command -v fzf >/dev/null 2>&1; then
    # 模糊搜尋全系統檔案並 cat (支援跨目錄)
    
    fca() {
        # 搜尋起點：目前目錄(.)、家目錄(~)、系統配置(/etc)
        # 你可以根據需要增加路徑，例如 /mnt/d/Scoop
        local search_paths=". ~ /etc"
        
        # 1. 用 fd 搜尋 (排除 .git，隱藏檔也找，忽略權限報錯)
        # 2. fzf 選單：--query="$*" 帶入你的 etc wsl.con
        # 3. --preview: 選到檔案時，右邊自動用 bat (帶顏色) 或 cat 顯示前 100 行
        local file=$(fd . $search_paths --type f --hidden --exclude .git 2>/dev/null | \
            fzf --query="$*" \
                --select-1 \
                --exit-0 \
                --preview 'bat --style=numbers --color=always --line-range :100 {} 2>/dev/null || cat {} | head -n 100')

        if [ -n "$file" ]; then
            echo -e "\033[0;32m[Reading] $file\033[0m"
            # 這裡建議直接用 bat，畫面才漂亮
            if command -v bat >/dev/null; then
                bat "$file"
            else
                cat "$file"
            fi
        fi
    }

    # 同理，你的 fe (Fuzzy Edit) 也可以比照辦理
    fe() {
        # 搜尋起點：目前目錄(.)、家目錄(~)、系統配置(/etc)
        local search_paths=". ~ /etc"
        
        # 1. 用 fd 搜尋所有檔案 (包含隱藏檔，排除 .git)
        # 2. fzf 介面：加上預覽視窗，讓你在進 nvim 前先確認沒找錯檔案
        local file=$(fd . $search_paths --type f --hidden --exclude .git 2>/dev/null | \
            fzf --query="$*" \
                --select-1 \
                --exit-0 \
                --preview 'bat --style=numbers --color=always --line-range :100 {} 2>/dev/null || cat {} | head -n 100')

        # 3. 如果選中了檔案，就用 nvim 開啟
        if [ -n "$file" ]; then
            # 如果是 /etc 下的檔案且目前沒權限，可以考慮自動加 sudo (選配)
            if [[ "$file" == /etc/* ]] && [ ! -w "$file" ]; then
                echo -e "\033[0;33m[Sudo Edit] $file\033[0m"
                sudo nvim "$file"
            else
                echo -e "\033[0;32m[Editing] $file\033[0m"
                nvim "$file"
            fi
        fi        
    }
    # 用法: fh [關鍵字]
    fh() {
        # 搜尋歷史紀錄並執行選中的指令
        local line=$(history | fzf --query="$1" --tac --preview 'echo {}' --preview-window down:3:wrap | sed 's/^[ ]*[0-9]*[ ]*//')
        if [ -n "$line" ]; then
            # 這裡會直接把指令填入你的輸入行（Buffer），按 Enter 才執行
            READLINE_LINE="$line"
            READLINE_POINT=${#line}
        fi
    }
    # 模糊跳轉目錄 (比 z 更直觀)
    fz() {
        local dir=$(fd . $HOME /etc --type d --hidden --exclude .git 2>/dev/null | fzf --query="$*")
        [ -n "$dir" ] && cd "$dir"
    }


    fk() {
        # 顯示 PID, %CPU, %MEM, 和指令內容
        local selected=$(ps -u $USER -o pid,%cpu,%mem,comm --sort=-%cpu | sed 1d | \
            fzf --header "[fk] SELECT PROCESS TO KILL (Sorted by CPU %)" \
                --layout=reverse --query="$*")
        
        if [ -n "$selected" ]; then
            local pid=$(echo $selected | awk '{print $1}')
            local pName=$(echo $selected | awk '{print $4}')
            
            # 詳細確認畫面
            echo -e "\n\033[0;31m!!! TERMINATION WARNING !!!\033[0m"
            echo -e "Process: $pName"
            echo -e "PID:     $pid"
            ps -p $pid -o %cpu,%mem,etime,args
            
            echo -en "\n\033[0;33mAre you sure you want to kill this process? (y/n): \033[0m"
            read -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                kill -9 $pid && echo -e "\033[0;32mDone.\033[0m"
            else
                echo "Aborted."
            fi
        fi
    }
    # 模糊搜尋目錄並 ls，選中後詢問是否 cd

    fls() {
        local search_paths=". ~ /etc"
        local dir=$(fd . $search_paths --type d --hidden --exclude .git 2>/dev/null | \
            fzf --query="$*" \
                --header "[fls] List Directory Contents" \
                --preview 'ls -p --color=always {} | head -n 50')

        if [ -n "$dir" ]; then
            echo -e "\033[0;36m[Listing] $dir\033[0m"
            ls -p -ah --color=always "$dir"
        fi
    }
fi

# FZF 預覽設定 (使用 bat)
if command -v batcat >/dev/null 2>&1 || command -v bat >/dev/null 2>&1; then
    _BAT_BIN=$(command -v batcat || command -v bat)
    alias cat="$_BAT_BIN"
    alias ocat="/bin/cat"
    export FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border --preview '$_BAT_BIN --style=numbers --color=always --line-range :500 {}'"    
    export MANPAGER="sh -c 'col -bx | ${_BAT_BIN} -l man -p'"
    export MANROFFOPT="-c"
    batdiff() {
        git diff --name-only --relative --diff-filter=d -z | xargs -0 $_BAT_BIN --diff
    }
    # export MANPAGER="sh -c 'awk '\''{ gsub(/\x1B\[[0-9;]*m/, \"\", \$0); gsub(/.\x08/, \"\", \$0); print }'\'' | bat -p -lman'"
fi

# --- 4. Aliases (別名) ---

# Eza (取代 ls)
if command -v eza >/dev/null 2>&1; then
    alias ls='eza --icons --group-directories-first'
    alias ll='eza -lh --icons --git --group-directories-first'
    alias la='eza -a --icons --group-directories-first'
    alias lla='eza -alh --icons --group-directories-first'
    alias lt='eza --tree --level=2 --icons'
else
    alias ll='ls -alF'
    alias la='ls -A'
fi

if command -v lazygit >/dev/null 2>&1; then
    alias lg='lazygit'
fi

if command -v yazi >/dev/null 2>&1; then
    function yy() {
        local tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
    : > "$tmp"  # 強制清空該暫存檔

        stty -echo
        TERM=xterm-256color TERM_PROGRAM='MYTERM' yazi "$@" --cwd-file="$tmp"
        stty echo

        # 關鍵在於這裡：只有當 tmp 檔案裡面「真的有內容」時才跳轉
        # 如果你按 q 退出，tmp 會是空的，就不會跳轉
        # 只有當你按 Q (quit --save-cwd) 時，Yazi 才會把路徑寫入 $tmp
        if [ -s "$tmp" ]; then
            local cwd
            cwd="$(cat -- "$tmp")"
            if [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
                cd -- "$cwd"
            fi
        fi

        rm -f -- "$tmp"
        # 5. 強制重設終端機狀態（防止噴字殘留在 Command Line）
        printf "\033[0m" 
    }
fi

# function yy() {
#     local tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
    
#     # 1. 閉回顯，防止 Device Query 噴字
#     stty -echo
    
#     # 2. 執行 Yazi
#     # 強制 TERM 為 xterm-256color 是解決噴字的特效藥
#     # 但如果要圖片，建議在 yazi.toml 裡寫死 image_preview_protocol = "sixel"
#     env -u TERM_PROGRAM \
#         -u WEZTERM_PANE \
#         -u WEZTERM_EXECUTABLE \
#         TERM=xterm-256color \
#         yazi "$@" --cwd-file="$tmp"

#     # 3. 恢復回顯
#     stty echo
    
#     # 4. 處理路徑跳轉
#     if cwd="$(cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
#         builtin cd -- "$cwd"
#     fi
#     rm -f -- "$tmp"
    
#     # 5. 終極保險：清空緩衝區，防止殘留亂碼
#     printf "\033[0m\033[2J\033[H" 
#     # 或者簡單點用 reset，但 reset 較慢
# }

# function yy() {
#     local tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
    
#     # 強制傳入背景顏色與強制終端類型
#     # 這能解決 Log 裡的 "Failed to detect background color"
#     # 並解決 "width: 0" 的問題
#     env TERM=wezterm \
#         COLORFGBG="15;0" \
#         YAZI_ID="wezterm" \
#         YAZI_LOG=debug \
#         yazi "$@" --cwd-file="$tmp"

#     if cwd="$(cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
#         cd -- "$cwd"
#     fi
#     rm -f -- "$tmp"
# }

# --- 5. 自定義捷徑 ---
alias ..='cd ..'
alias ...='cd ../..'
alias .3='cd ../../..'
alias reload='source ~/.bashrc'

full_path=$(readlink -f "${BASH_SOURCE[0]}")

# 2. 使用 Regex 比對，抓取到 "dotfiles" 為止的所有字元
if [[ "$full_path" =~ ^(.*\/dotfiles) ]]; then
    DOTFILES_ROOT="${BASH_REMATCH[1]}"
    RUNTIME_DIR="${DOTFILES_ROOT%/*}"
    alias dot='cd $RUNTIME_DIR/dotfiles'    
fi

if command -v nvim >/dev/null 2>&1;  then
    export EDITOR='nvim'
    #alias nvim='/usr/bin/nvim'
    alias vi='nvim'
    alias vim='nvim'
    # 只有在 Tmux 會話中才啟動這個欺騙機制
    if [ -n "$TMUX" ]; then
        alias nvim='TERM=screen-256color nvim'
    fi
fi

if [ -d "$HOME/.local/share/fnm" ]; then
    export PATH="$HOME/.local/share/fnm:$PATH"
fi

# 確定系統此時踩得到 fnm 指令，才執行 eval 渲染環境
if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --use-on-cd --shell bash)"
fi

# 檢查是否為互動式視窗且 fastfetch 存在
if [[ $- == *i* ]] && command -v fastfetch >/dev/null 2>&1; then
    # 清一下畫面，讓 Logo 出現在最上方（選配）
    # clear
    fastfetch --logo-type small --logo-padding 2 --color-keys cyan --color-title blue
fi

alias gd='git diff'
alias gds='git -c delta.side-by-side=false diff'


# if [[ "$TERM_PROGRAM" == "WezTerm" ]] || [[ -n "$LC_TERM_BRAND" ]]; then
#     # 動態生成 Base64，避免手動轉碼的麻煩
#     # -n 代表不換行，這是 Base64 序列的關鍵
#     _term_val=$(echo -n "WezTerm" | base64)
#     _env_val=$(echo -n "WSL-Dev" | base64)
#
#     printf "\033]1337;SetUserVar=TERM_BRAND=$_term_val\007"
# fi

get_wez_val() {
    # 1. 噴射信號
    # printf "\033]1337;SetUserVar=SYNC_TERM=$(echo -n "go" | base64)\007"
    local val="go"
    local b64_val=$(echo -n "$val" | base64 | tr -d '\n')
    local osc_seq="1337;SetUserVar=SYNC_TERM=$b64_val"

    if [ -n "$TMUX" ]; then
        # 在 tmux 內：需包裹 \ePtmux; 和 \e\\
        # 且內部的 Esc (\033) 要變成雙重 Esc
        printf "\033Ptmux;\033\033]${osc_seq}\007\033\\"
    else
        # 原生終端：直接發送
        printf "\033]${osc_seq}\007"
    fi
    
    # 2. 關鍵：保存狀態並進入「隱形原始模式」
    local old_stty=$(stty -g)
    
    # raw: 原始傳輸
    # -echo: 關閉螢幕回顯 (這樣 WezTerm 噴過來的字就不會顯示在螢幕上)
    # min 0 time 2: 最多等 0.2 秒，沒資料就收工，避免卡死
    stty raw -echo min 0 time 2
    
    # 3. 收割
    # 我們可以讀長一點點沒關係，只要 WezTerm 沒噴換行，就不會觸發指令執行
    local val=$(head -c 20 2>/dev/null)
    
    # 4. 恢復狀態 (必須立刻恢復，否則你的 Prompt 會變得很奇怪)
    stty "$old_stty"
    
    # 5. 清理與套用
    # 移除任何不可見字元
    val=$(echo "$val" | tr -d '\000-\037 ')
    
    if [[ -n "$val" ]]; then
        export TERM_BRAND="$val"
        # Debug 用，確定有抓到但螢幕沒髒掉
        # echo "Sync Success: $TERM_BRAND"
    fi
}

# if [[ -n "$SSH_CONNECTION" ]]; then
#     # 透過父進程判斷 (比較硬核，但這才是事實)
#     if ss -xl | grep -q "pascual@"; then
#         export REAL_CONTROL="TRUE"
#     fi
# fi

if [[ $- == *i* ]]; then
    get_wez_val
fi

