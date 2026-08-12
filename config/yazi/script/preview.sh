#!/bin/bash
PATH_TO_IMG="$1"

# 1. 取得視窗/窗格尺寸
if [ -n "$TMUX" ]; then
    # Tmux 環境
    W=$(tmux display -p '#{pane_width}' 2>/dev/null || echo 80)
    H=$(tmux display -p '#{pane_height}' 2>/dev/null || echo 24)
else
    # 純 SSH/終端環境
    W=$(tput cols 2>/dev/null || echo 80)
    H=$(tput lines 2>/dev/null || echo 24)
fi

# 2. 計算 80% 上限
MAX_W=$((W * 8 / 10))
MAX_H=$((H * 8 / 10))

stty -echo && clear

(
    if [ -n "$TMUX" ]; then
        # 1. 先單獨發送座標歸零，這部分也要穿透
        printf "\033Ptmux;\033\033[H\033\\"
        # 2. 開始圖片數據的穿透封裝
        printf "\033Ptmux;\033"
    else
        printf "\033[H"
    fi
    
    # 3. 繪圖核心
    chafa -f iterm2 --size "${MAX_W}x${MAX_H}" --scale 1.0 "${PATH_TO_IMG}" | \
      sed 's/\x1b\]/\x1b\x1b\]/g' | \
      sed 's/\x1b\[?25l//g' | \
      sed 's/\x1b\[?25h//g' | \
      dd bs=4000 2>/dev/null
      
    # 4. 封裝結尾
    if [ -n "$TMUX" ]; then
        printf "\033\\"
    fi
)

# 6. 暫停與清理
read -n1
stty echo
clear

# 如果是 Tmux，最後多補一個重繪
if [ -n "$TMUX" ]; then
    tmux refresh-client
fi
