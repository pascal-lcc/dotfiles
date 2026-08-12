#1. 互動式檢查
case $- in *i*) ;; *) return;; esac

# 2. 基礎權限與通知
umask 022
set -o notify

# 3. 終端機設定 (防止 Ctrl-S 鎖死畫面，支援 UTF-8)
stty iutf8
stty -ixon

# 4. Vi 模式設定 (Zsh 的專業寫法)
bindkey -v
export KEYTIMEOUT=1 # 讓 Esc 切換模式反應更快
export XDG_CONFIG_HOME="$HOME/.config"


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

# 清理暫存變數
unset _CURRENT_FILE _FULL_PATH

#export PATH=$(echo $PATH | tr ':' '\n' | grep -v '/mnt/' | tr '\n' ':' | sed 's/:$//')
## 強制關閉 Bash 嘗試搜尋 PATH 來做補全的行為
#shopt -u progcomp

CURRENT_USER=${USER:-$(id -un)}

setopt AUTO_CD          # 打路徑直接進入目錄，不用打 cd
setopt CORRECT          # 自動更正指令拼字錯誤
setopt EXTENDED_GLOB    # 支援更強大的檔案比對 (像是 **/*.js)
setopt INTERACTIVE_COMMENTS

# 先加載 Zsh 的 Hook 模組
autoload -Uz add-zsh-hook

# 根據 UID 判斷顏色，但只設定一次 PS1
[ -f "$MY_DOTFILES_ROOT/config/shell/common_all.sh" ] && source "$MY_DOTFILES_ROOT/config/shell/common_all.sh"

[ -f "$HOME/.zshrc_local" ] && source "$HOME/.zshrc_local"


zmodload zsh/terminfo

# 定義一個函數來綁定按鍵
function bind_key_if_exists() {
    if [[ -n "$terminfo[$1]" ]]; then
        bindkey "$terminfo[$1]" "$2"
    fi
}

bindkey '^[OH'  beginning-of-line  # 這是直接 SSH 傳給 CT 的碼
bindkey '^[[H'  beginning-of-line  # 這是標準 xterm 碼



# Zsh 版本的傳輸函數
send_to_term() {
    local name=$1
    local value=$2
    local action=${3:-"SetUserVar"}
    
    # 1. 確保 Base64 純淨
    local b64_value=$(echo -n "$value" | base64 | tr -d '\n\r ')
    
    # 2. 構建 Payload
    local payload=""
    if [[ "$action" == "SetUserVar" ]]; then
        payload="SetUserVar=$name=$b64_value"
    elif [[ "$action" == "Copy" ]]; then
        payload="Copy=$b64_value"
    else
        payload="$action=$value"
    fi

    # 3. 直接噴發，不經過中間變數轉手，避免 Zsh 轉義符被吃掉
    if [[ -n "$TMUX" ]]; then
        # 這裡最關鍵：我們直接在 printf 裡面寫死封裝格式
        # \x1b 是 ESC, \x07 是 BEL (即 \a)
        printf "\x1bPtmux;\x1b\x1b]%s\x07\x1b\\" "1337;$payload"
    else
        printf "\x1b]%s\x07" "1337;$payload"
    fi
}

_sync_wezterm_state() {
    # 確保變數有預設值，避免噴出空的控制序列
    local ctx="${__CURRENT_PANE_CTX:-idle}"
    
    # 發送給 WezTerm (UserVar)
    send_to_term "PROG" "$ctx" "SetUserVar"
    
    # 如果在 Tmux 裡，額外發送協定標題供 Tmux 存檔 (@pane_ctx)
    [ -n "$TMUX" ] && send_to_osc "#$ctx" "2"
}

send_to_osc() {
    # 如果沒提供第二個參數，預設序列號為 2
    local msg="$1"
    local seq="${2:-2}"

    # \033 是 ESC, \007 是 BEL
    # 用 printf 格式化輸出並直接寫入 stdout
    printf "\033]%s;%s\007" "$seq" "$msg"
}
# 定義

typeset -g __CURRENT_PANE_CTX="sh"
typeset -g __LAST_PANE_CTX="sh"

_sync_preexec() {
    local raw_cmd="${2%% *}"
    local final_cmd="$raw_cmd"

    if [[ "$raw_cmd" == "fg" ]]; then
        local job_id
        
        # 1. 判定要找哪一個 Job ID
        if [[ "$2" == "fg" ]]; then
            # 如果是空的 fg，我們去 jobstates 裡找那個帶有 '+' 的 key
            # ${(k)jobstates[(r)*+*]} 是 Zsh 的黑魔法：回傳 value 包含 '+' 的那個 key (ID)
            job_id="${(k)jobstates[(r)*+*]}"
        else
            # 處理 fg %1 或 fg 1
            job_id="${2#fg }"
            job_id="${job_id#%}"
        fi

        # 2. 拿到 ID 後，去 jobtexts 查真正的指令名稱
        local full_job_cmd="${jobtexts[$job_id]}"
        
        if [[ -n "$full_job_cmd" ]]; then
            final_cmd="${full_job_cmd%% *}"
        else
            # 真的查不到才 fallback
            final_cmd="fg"
        fi
    fi

    # 3. 處理 Function Wrapper (硬吞)
    if [[ "$final_cmd" == *"_wrapper" ]]; then
        final_cmd="${final_cmd%_wrapper}"
    fi

    [[ "$final_cmd" == "send_to_term" ]] && return

    __CURRENT_PANE_CTX="$final_cmd"
    send_to_term "PROG" "$__CURRENT_PANE_CTX" "SetUserVar"
    [ -n "$TMUX" ] && send_to_osc "#${__CURRENT_PANE_CTX}"
    # if [[ -n "$TMUX" ]]; then
    #     echo "AA Gained at $(date +%T) : $__CURRENT_PANE_CTX" >> /tmp/zsh_focus.log
    #     printf "\033]2;#%s\007" "$__CURRENT_PANE_CTX"
    # fi
}


_sync_precmd() {
    # 當回到提示字元時，狀態重設為 sh
    __LAST_PANE_CTX="$__CURRENT_PANE_CTX" 
    __CURRENT_PANE_CTX="sh"
    send_to_term "PROG" "$__CURRENT_PANE_CTX" "SetUserVar"
    [ -n "$TMUX" ] && send_to_osc "#${__CURRENT_PANE_CTX}"
    # printf '\e[?1004h'
}

_sync_chpwd() {
    send_to_term "" "$PWD" "CurrentDir"
}

add-zsh-hook -d preexec _sync_preexec
add-zsh-hook -d precmd  _sync_precmd
add-zsh-hook -d chpwd   _sync_chpwd
# 註冊
add-zsh-hook preexec _sync_preexec
add-zsh-hook precmd  _sync_precmd
add-zsh-hook chpwd   _sync_chpwd

unset SHELL_SYNC_ACTIVE
export SHELL_SYNC_ACTIVE=1 

# 在 Tmux 環境下，Tmux 宣告自己有沒有 Hook
if [ -n "$TMUX" ]; then
    unset TMUX_HOOK_ACTIVE
    export TMUX_HOOK_ACTIVE=$(tmux show-option -gv @tmux_sync_active)
fi

# 1. 定義你的函數
on_focus_gained() {
    # 直接抓最後一次紀錄的值，不用再 ps，不用再剝洋蔥
    echo "Focus Gained at $(date +%T)" >> /tmp/zsh_focus.log
    send_to_term "pane_ctx" "$__CURRENT_PANE_CTX" "SetUserVar"
    zle .reset-prompt
}

on_focus_lost() {
    # 失去焦點時可以發個訊號，或者不做事
    send_to_term "pane_ctx" "LOST" "SetUserVar"
    zle .reset-prompt
}

# 2. 將函數轉換為 ZLE Widget (這一步就是你問的 zle -N)
# zle -N focus-gained on_focus_gained
# zle -N focus-lost on_focus_lost
#
# bindkey '^[[I' focus-gained
# bindkey '^[[O' focus-lost
#
# bindkey -M main  -r '^[[I'
# bindkey -M viins -r '^[[I'
# bindkey -M emacs -r '^[[I'
# bindkey -M main  '^[[I' focus-gained





# fnm
FNM_PATH="/home/pascual/.local/share/fnm"
if [ -d "$FNM_PATH" ]; then
  export PATH="$FNM_PATH:$PATH"
  eval "$(fnm env --use-on-cd --shell zsh)"
fi
