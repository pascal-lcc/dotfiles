#!/bin/bash

IS_WSL=false
if [ -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then
    IS_WSL=true
fi

# === 0. 判斷目前 Shell 類型 (相容兩種 Shell 的寫法) ===
if [ -n "$ZSH_VERSION" ]; then
    sh="zsh"
elif [ -n "$BASH_VERSION" ]; then
    sh="bash"
else
    sh=$(echo "$SHELL" | sed -r 's/.+\///')
fi

# === 1. 基礎環境變數 ===
export LANG='en_US.UTF-8'
export EDITOR='nvim'
export SUDO_EDITOR='nvim'
export HISTSIZE=10000
export HISTFILESIZE=20000

if [ "$sh" = "bash" ]; then
    export HISTCONTROL=ignoreboth
    export HISTTIMEFORMAT="%F %T "
    # Bash 特有的歷史同步
    PROMPT_COMMAND="history -a; $PROMPT_COMMAND"
elif [ "$sh" = "zsh" ]; then
    # Zsh 特有的歷史設定
    unsetopt nomatch
    setopt prompt_subst
    HISTFILE=~/.zsh_history
    HISTSIZE=10000
    SAVEHIST=20000
    setopt APPEND_HISTORY
    setopt HIST_IGNORE_DUPS
    unsetopt SHARE_HISTORY
    # setopt SHARE_HISTORY

    PLUGIN_BASE="$HOME/.local/share/zsh-plugins"
        # 功能：像 IDE 一樣灰字提示，按 → 補完
    [[ -f "$PLUGIN_BASE/zsh-autosuggestions/zsh-autosuggestions.zsh" ]] && \
        source "$PLUGIN_BASE/zsh-autosuggestions/zsh-autosuggestions.zsh"

    # 2. 語法高亮 (Syntax Highlighting)
    # 注意：這必須是最後載入的插件，否則會跟別的插件打架
    [[ -f "$PLUGIN_BASE/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]] && \
        source "$PLUGIN_BASE/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
    # ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=6,underline'
fi

if [[ -n "$SSH_CONNECTION" ]]; then
    # 1. 強制修復 TERM，否則 chafa/yazi 甚至不會嘗試噴顏色
    export TERM=xterm-256color
    export COLORTERM=truecolor
    # 2. 既然 env 沒了，我們改用「肉眼」偵測 (也就是我們之前試的)
    # 因為 printf 控制碼不會被 SSH 的 AcceptEnv 擋住
    # 它直接走 PTY 數據流
elif [[ -z "$TERM" || "$TERM" == "dumb" || "$TERM" == "linux" || "$TERM" == "unknown" ]]; then
    # 既然沒帶環境變數，我們手動補上基礎的 256 色支援
    # 這樣 nvim 的 guicursor 和顏色才會嘗試運作
    export TERM=xterm-256color
    export COLORTERM=truecolor
fi

if [ "$TERM_PROGRAM" = "WezTerm" ]; then
    # 這裡是在強迫 Linux 核心去紀錄終端機的尺寸 格式是 stty rows 行數 cols 列數
    stty cols $(tput cols) rows $(tput lines)
fi

if [[ "$WEZTERM_PANE" != "" ]]; then
    stty -echo
    # 這裡是複用模式下的保護邏輯
    export TERM=xterm-256color
    stty echo
fi

# === 2. 基礎別名 (Aliases) ===
alias cp='cp -i'
alias df='/bin/df -h'
alias grep='grep --color=auto'
alias ll='ls -alF'
alias mv='mv -i'
alias rm='/bin/rm -i'
alias sudo='sudo '
alias ..='cd ..'
alias ...='cd ../..'
alias .3='cd ../../..'
alias sn='sudoedit'
alias gd='git diff'
alias gds='git -c delta.side-by-side=false diff'

# 偵測 ls 是否支援 --color (GNU) 或 -G (BusyBox)
if ls --color >/dev/null 2>&1; then
    # 適用於 Ubuntu / Debian / 裝了 coreutils-ls 的 OpenWrt
    alias ls='ls --color=auto'
elif ls -G >/dev/null 2>&1; then
    # 適用於原生 OpenWrt (BusyBox)
    alias ls='ls -G'
fi

if [ "$TERM_PROGRAM" = "WezTerm" ]; then
    # 這裡是在強迫 Linux 核心去紀錄終端機的尺寸 格式是 stty rows 行數 cols 列數
    stty cols $(tput cols) rows $(tput lines)
fi

if [[ "$WEZTERM_PANE" != "" ]]; then
    stty -echo
    # 這裡是複用模式下的保護邏輯
    export TERM=xterm-256color
    stty echo
fi

if [[ -n "$SSH_CONNECTION" ]]; then
    # 1. 強制修復 TERM，否則 chafa/yazi 甚至不會嘗試噴顏色
    export TERM=xterm-256color
    export COLORTERM=truecolor

    # 2. 既然 env 沒了，我們改用「肉眼」偵測 (也就是我們之前試的)
    # 因為 printf 控制碼不會被 SSH 的 AcceptEnv 擋住
    # 它直接走 PTY 數據流
fi

# --- 2. 工具初始化 (Tools Init) ---

# Starship 提示字元
if command -v starship >/dev/null 2>&1; then
    eval "$(starship init $sh)"
    if [ -n "$ZSH_VERSION" ]; then

        # 讓 Zsh 允許在 Prompt 中執行指令 (Starship 必備)
        autoload -Uz add-zsh-hook
        autoload -Uz add-zle-hook-widget

        # 1. 備份那串「動態指令」
        # 這時 _P_SAVED 存的是 $(/usr/local/bin/starship ...) 這串字
        typeset -g _P_SAVED=$PROMPT
        typeset -g _RP_SAVED=$RPROMPT

        # 2. 縮小動作 (History)
        _pascual_shrink() {
            # PROMPT="%F{2} %f "
            PROMPT="%F{6} %f "
            # PROMPT="%K{8}%F{15}  %~ %k %F{8}%f "
            RPROMPT=""
            zle .reset-prompt
        }
        add-zle-hook-widget zle-line-finish _pascual_shrink

        # 3. 還原動作 (New Line)
        # 把公式貼回去，下一行就會重新計算
        _pascual_restore() {
            PROMPT=$_P_SAVED
            RPROMPT=$_RP_SAVED
            # local cols=${COLUMNS:-80}
            # print -P "\n%F{238}${(l:$cols::─:)}%f"
        }

        _pascual_preexec() {
            # [[ -n "$1" ]] && print -P "%F{238}${(l:$COLUMNS::─:)}%f\n"
            [[ -n "$1" ]] && print ""
        }

        add-zsh-hook precmd _pascual_restore
        add-zsh-hook preexec _pascual_preexec

    
        # # 1. 定義縮小後的歷史符號
        # readonly PASCUAL_HIST_PROMPT="╰─ "
        # # 2. 建立縮小函數
        # _pascual_shrink_and_accept() {
        #     # A. 取得當前 Starship 產生的完整 Prompt (存起來備用)
        #     local current_full_prompt="$PROMPT"
        #
        #     # B. 將當前畫面的 Prompt 瞬間換成縮小版
        #     PROMPT="$PASCUAL_HIST_PROMPT"
        #     RPROMPT=""
        #     zle .reset-prompt
        #
        #     # C. 正式送出指令執行
        #     zle .accept-line
        #
        #     # D. 重點：執行完後，立刻把 PROMPT 還原成剛才存起來的完整版
        #     # 這樣下一行出來時，就會是彩色的兩層樓
        #     PROMPT="$current_full_prompt"
        # }
        #
        # # 3. 註冊並綁定 Enter 鍵
        # zle -N pascual-shrink-and-accept _pascual_shrink_and_accept
        # bindkey '^M' pascual-shrink-and-accept
        # bindkey '^J' pascual-shrink-and-accept
    fi
fi

# Zoxide (取代 cd)
if command -v zoxide >/dev/null 2>&1; then
    eval "$(zoxide init $sh)"
fi

# ---------------------------------------
fzf_ext=$sh
[ "$sh" = "zsh" ] && fzf_ext="zsh"

for fzf_script in \
    "/usr/share/doc/fzf/examples/key-bindings.$fzf_ext" \
    "/usr/share/fzf/key-bindings.$fzf_ext" \
    "/usr/share/fzf/shell/key-bindings.$fzf_ext" \
    "/usr/share/doc/fzf/examples/completion.$fzf_ext" ; do
    if [ -f "$fzf_script" ]; then
        source "$fzf_script"
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
            [ "$sh" = "zsh" ] && vared -c file
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
    # [fh] 搜尋歷史紀錄：這是差異最大的地方
    fh() {
        local line
        if [ "$sh" = "zsh" ]; then
            # Zsh 使用 fc 讀取歷史，且支援直接寫入 LBUFFER (輸入行)
            line=$(fc -rl 1 | fzf --query="$1" --select-1 --exit-0 | sed 's/^[ ]*[0-9]*[ ]*//')
            LBUFFER="$line" 
        else
            # Bash 使用 history 指令與 READLINE 變數
            line=$(history | fzf --query="$1" --tac --select-1 --exit-0 | sed 's/^[ ]*[0-9]*[ ]*//')
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
            
            if [ "$sh" = "zsh" ]; then
                # Zsh 的 read -q 會直接讀取一個字元並返回狀態碼
                # "REPLY?..." 語法會處理提示字串
                echo -en "\n\033[0;33mAre you sure you want to kill this process? (y/n): \033[0m"
                read -q REPLY 
            else
                # Bash 的原創語法 
                read -p "$(echo -e "\n\033[0;33mAre you sure you want to kill this process? (y/n): \033[0m")" -n 1 -r
            fi
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
    # alias cat="$_BAT_BIN"
    # alias ocat="/bin/cat"
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

if command -v nvim >/dev/null 2>&1;  then
    # unalias nvim
    unalias nvim 2>/dev/null
    _NVIM_BIN=$(command -v nvim)
    export EDITOR="$_NVIM_BIN"
    export VISUAL="$_NVIM_BIN"
    alias nvim="$_NVIM_BIN"
    alias vi='nvim'
    alias vim='nvim'
    # 封裝一個 alias 來處理顏色欺騙與還原
    nvim_wrapper() {
        # 如果在 Tmux 內，我們進去前先換成通用 TERM
        if [ -n "$TMUX" ]; then
            # 這是為了讓 Tmux 與遠端 Terminfo 穩定
            # 但進入 nvim 後，nvim 會讀取你的 init.lua (set termguicolors)
            # 來重新開啟 TrueColor 支援，這樣就不會破圖
            TERM=screen-256color "$_NVIM_BIN" "$@"
        else
            "$_NVIM_BIN" "$@"
        fi
    }
    alias nvim=nvim_wrapper
fi

if [ -n "$ZSH_VERSION" ]; then
    # Zsh 取得目前被 source 檔案路徑的寫法
    _CURRENT_SCRIPT="${(%):-%N}"
elif [ -n "$BASH_SOURCE" ]; then
    # Bash 取得目前被 source 檔案路徑的寫法
    _CURRENT_SCRIPT="${BASH_SOURCE[0]}"
else
    # 保底方案
    _CURRENT_SCRIPT="$0"
fi

_FULL_PATH=$(readlink -f "$_CURRENT_SCRIPT" 2>/dev/null || realpath "$_CURRENT_SCRIPT" 2>/dev/null)
if [[ "$_FULL_PATH" == *"/dotfiles"* ]]; then
    # 刪除 "dotfiles" 之後的所有字元，保留到 "dotfiles" 為止
    export MY_DOTFILES_ROOT="${_FULL_PATH%%/dotfiles*}/dotfiles"
    export RUNTIME_DIR="${MY_DOTFILES_ROOT%/*}"
    
    alias dot="cd $MY_DOTFILES_ROOT"
    # 你原本的 alias 是 cd $RUNTIME_DIR/dotfiles，其實就是 DOTFILES_ROOT
fi

# 清理暫存變數，保持環境乾淨
unset _CURRENT_SCRIPT _FULL_PATH


if [[ $- == *i* ]] && command -v fastfetch >/dev/null 2>&1; then
    # 清一下畫面，讓 Logo 出現在最上方（選配）
    # clear
    fastfetch --logo-type small --logo-padding 2 --color-keys cyan --color-title blue
fi

detect_tmux() {
    if [ -z "$TMUX" ]; then
        local term_id=""
        
        # 發送設備屬性查詢 (Device Attributes)
        printf '\e[>c'

        # 根據不同的 Shell 執行不同的 read 語法
        if [ -n "$ZSH_VERSION" ]; then
            # Zsh: -d 指定結束符號，-t 指定秒數 (zsh 的 -t 單位是秒)
            read -s -t 0.1 -d 'c' term_id 2>/dev/null
        elif [ -n "$BASH_VERSION" ]; then
            # Bash: -d 指定結束符號，-t 指定秒數
            read -s -t 0.1 -d 'c' term_id 2>/dev/null
        else
            # 針對純 sh 或 dash (POSIX)
            # POSIX read 不支援 -t 或 -d，通常只能靠 stty 配合
            # 但既然你主要是 zsh/bash，這裡做簡單 fallback
            read term_id 2>/dev/null
        fi

        # 檢查回傳值是否包含 Tmux 的特徵碼 84
        case "$term_id" in
            *">84;"*)
                export TMUX="detected-by-id-84"
                
                # 針對 Zsh 額外綁定按鍵
                if [ -n "$ZSH_VERSION" ]; then
                    bindkey '^[[1~' beginning-of-line
                    bindkey '^[[4~' end-of-line
                # 針對 Bash 額外綁定按鍵
                elif [ -n "$BASH_VERSION" ]; then
                    bind '"\e[1~": beginning-of-line'
                    bind '"\e[4~": end-of-line'
                fi
                ;;
        esac
    fi
}

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
    stty raw -echo min 0 time 2 2>/dev/null
    
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

if [ -d "$HOME/.local/share/fnm" ]; then
    export PATH="$HOME/.local/share/fnm:$PATH"
fi

# 確定系統此時踩得到 fnm 指令，才執行 eval 渲染環境
if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --shell bash)"
fi

if [[ $- == *i* ]]; then
    detect_tmux
    get_wez_val
fi

stty iutf8
stty -ixon

