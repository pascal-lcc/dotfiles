#!/bin/bash
PATH_TO_IMG="$1"

# 1. 偵測環境並設定寬高比例
if [ -n "$TMUX" ]; then
    # Tmux 環境：保守一點，設為 80% 避免換行崩潰
    RATIO_W=50
    RATIO_H=50
    W=$(tmux display -p '#{pane_width}' 2>/dev/null || echo 80)
    H=$(tmux display -p '#{pane_height}' 2>/dev/null || echo 24)
else
    # 非 Tmux 環境 (WezTerm 直接連 SSH)：可以開到 95%
    RATIO_W=80
    RATIO_H=80
    W=$(tput cols 2>/dev/null || echo 80)
    H=$(tput lines 2>/dev/null || echo 24)
fi

MAX_W=$((W * RATIO_W / 100))
MAX_H=$((H * RATIO_H / 100))

# 2. 準備畫面
stty -echo
clear
printf "\033[H" # 座標歸零

# 3. 繪圖邏輯
if [ -n "$TMUX" ]; then
    # --- Tmux 高清穿透模式 ---
    printf "\033Ptmux;"
    chafa -f sixel --size "${MAX_W}x${MAX_H}" --scale 1.0 "${PATH_TO_IMG}" | sed 's/\x1b/\x1b\x1b/g'
    printf "\033\\"
else
    # --- 原生環境模式 (不需雙重轉義) ---
    chafa -f sixel --size "${MAX_W}x${MAX_H}" --scale 1.0 "${PATH_TO_IMG}"
fi

# 4. 保持畫面，按任意鍵退出
read -n1
stty echo

# 如果是 Tmux，退出後重新整理一下避免殘影
[ -n "$TMUX" ] && tmux refresh-client
