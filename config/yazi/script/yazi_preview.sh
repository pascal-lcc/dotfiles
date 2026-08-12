#!/bin/bash
FILE="$1"

detect_terminal() {
    # 設置穿透包裝
    if [ -n "$TMUX" ]; then
        Q_NAME=$'\033Ptmux;\033\033[>q\033\\'
        Q_DA1=$'\033Ptmux;\033\033[c\033\\'
    else
        Q_NAME=$'\033[>q'
        Q_DA1=$'\033[c'
    fi

    # 1. 先查 DA1 (Sixel 支援度)
    printf "$Q_DA1" > /dev/tty
    read -s -d 'c' -t 0.2 res_da1 < /dev/tty

    # 2. 再查名稱 (WezTerm)
    printf "$Q_NAME" > /dev/tty
    read -s -d 'k' -t 0.2 res_name < /dev/tty

    # --- 判斷邏輯 ---
    
    # 如果名稱有 WezTerm
    if [[ "$res_name" == *"WezTerm"* ]]; then
        # 如果同時支援 Sixel (wez-ssh 模式)
        if [[ "$res_da1" == *";4;"* ]]; then
            echo "wezterm-sixel"
        else
            echo "wezterm"            
        fi
        return
    fi

    # 如果沒偵測到 WezTerm，但有 Sixel 標籤 (通常是 WinTerm 或 Foot)
    if [[ "$res_da1" == *";4;"* ]] || [[ "$res_da1" == *";15;"* ]] || [[ "$res_da1" == *";16;"* ]]; then
        echo "winterm"
        return
    fi

    echo "putty"
}

ENV=$(detect_terminal)
# ENV=$(./detect.sh)

# 根據寬度高度（如果有的話）設定尺寸
#W=${2:-$(tput cols 2>/dev/null || echo 80)}
#H=${3:-$(tput lines 2>/dev/null || echo 24)}

if [ -n "$WSL_DISTRO_NAME" ]; then
    ENV_TYPE="wsl"
    FIX_H=0  # WSL 通常很準
elif [ -n "$SSH_CONNECTION" ]; then
    ENV_TYPE="ssh"
    FIX_H=2  # SSH 容易爆出，我們手動多扣 2 行
fi

# 1. 先抓取目前視窗寬度作為基準
COLS=$(tput cols 2>/dev/null || echo 80)
MAX_W=$(( COLS > 8 ? COLS - 8 : 8 ))
REQ_W=${2:-$MAX_W}
REQ_W=$(( REQ_W < 8 ? MAX_W : REQ_W ))
W=$(( REQ_W < MAX_W ? REQ_W : MAX_W ))

ROWS=$(tput lines 5>/dev/null || echo 80)
MAX_H=$(( ROWS > 8 ? ROWS - 8 : 8 ))
REQ_H=${3:-$MAX_H}
REQ_H=$(( REQ_H < 8 ? MAX_H : REQ_H ))
H=$(( REQ_H < MAX_H ? REQ_H : MAX_H ))


if [ -n "$TMUX" ] && [ "$ENV" == "putty" ]; then
    ENV="winterm"
fi


case "$ENV" in
"wezterm")

        # if [ -n "$TMUX" ]; then
        #     W=$(($W * 2/5))
        #     H=$(($H * 2/5))

        #     printf "\033Ptmux;\033"
        #     # chafa -f iterm2 --size "${W}x${H}" "$FILE" | \
        #     chafa --size "${W}x${H}" "$FILE" | \
        #         sed 's/\x1b\]/\x1b\x1b\]/g' | \
        #         sed 's/\x1b\[?25l//g' | \
        #         sed 's/\x1b\[?25h//g' | \
        #         dd bs=4000 2>/dev/null
        #     printf "\033[${H};1H" # 移到第 999 行 (底部)
        #     printf "\r"          # 回到行首
        #     exit
        # else
        #     W=$(($W * 1/2))
        #     H=$(($H * 1/2))
        
        #     # 1. 拉高：噴 15 個換行，再跳回 15 行前
        #     for i in $(seq 1 $H); do echo ""; done
        #     printf "\033[${H}A\r"
            
        #     # 2. 畫圖 (此時圖會填入剛才換行產生的空白處)
        #     chafa -f iterm2 --size "${W}x${H}" "$FILE"
            
        #     # 3. 下移：確保游標回到圖下
        #     printf "\033[${H}B\r"        
        # fi  
        
        # 
        # 呼叫內植 Python 邏輯處理繪圖與位移

# 導出環境變數給 Python 內核
        export PREVIEW_FILE="$FILE"        
        export PREVIEW_W=$(($W * 65/100))        
        export PREVIEW_H=$(($H * 65/100))

        # export PREVIEW_W="$W"
        # export PREVIEW_H="$H"
        python3 -c '
import sys, subprocess, os, re

def run():
    f = os.environ.get("PREVIEW_FILE")
    w = os.environ.get("PREVIEW_W")
    h = os.environ.get("PREVIEW_H")
    is_tmux = os.environ.get("TMUX") is not None

    fmt="iterm2"
    fmt="sixel"
    # 1. 取得 chafa 原始數據
    cmd = ["chafa", "-f", fmt, "--size", f"{w}x{h}", f]
    try:
        raw_data = subprocess.check_output(cmd)
    except: return

    sys.stderr.write("\nDEBUG CMD: {}\n".format(" ".join(cmd)))

    # 2. 精算高度 (從 iTerm2 協議 header 抓取)
    real_h = int(h)
    
    # sys.stderr.write("\nDEBUG RAW: {}\n".format(raw_data[:100].replace(b"\x1b", b"ESC")))

    if fmt == "iterm2":
        match = re.search(rb"height=(\d+)", raw_data)
        real_h = int(match.group(1).decode())
    elif fmt == "sixel":
        match = re.search(rb"\"(?:[0-9]+;[0-9]+;)?([0-9]+);([0-9]+)", raw_data)
        real_h = int(match.group(2).decode())


    # sys.stderr.write("\nDEBUG3: {}\n".format(real_h))
    # real_h = 13

    # 3. 準備輸出 FD
    fd = os.open("/dev/tty", os.O_WRONLY)
    try:
        # A. 空間推開與回跳 (這部分直接發送，Tmux 會處理)
        os.write(fd, b"\r")
        for _ in range(real_h):
            os.write(fd, b"\n")
        os.write(fd, f"\x1b[{real_h}A\r".encode())

        # B. 繪圖核心
        if is_tmux:
            # 針對 Tmux 的「大圖不噴碼」封裝邏輯：
            # 1. 先處理數據轉義 (\x1b -> \x1b\x1b)
            # 2. 移除游標序列
            payload = raw_data.replace(b"\x1b", b"\x1b\x1b")
            payload = payload.replace(b"\x1b\x1b[?25l", b"").replace(b"\x1b\x1b[?25h", b"")
            
            # 3. 【關鍵】一氣呵成封裝：頭 + 全數據 + 尾
            # 不要分段包頭，直接一個大包噴出去
            # os.write(fd, b"\x1bPtmux;\x1b" + payload + b"\x1b\\")
            os.write(fd, b"\x1bPtmux;\x1b" + payload + b"\x1b\x5c")            
        else:
            # 非 Tmux 模式：用你測過最穩的 stdout 轉接 (絕不右飄)
            subprocess.run(cmd, stdout=fd)

        # C. 跳回圖片下方 (Starship 起點)
        os.write(fd, f"\x1b[{real_h}B\r".encode())

    finally:
        os.close(fd)

run()
'
    ;;
    "wezterm-sixel")
        if [ -n "$TMUX" ]; then
            # W=$(($W * 45/100))
            # H=$(($H * 45/100))
            # 
            fmt='sixel'
            fmt='iterm2'

            CMD="chafa -f $fmt --size ${W}x${H} $FILE"
            echo "DEBUG CMD:$CMD"

        export PREVIEW_H=$(($H * 65/100))

            export FMT="$fmt"    

            # printf "\033[s\033[?25l"  #好像不用了
read w h < <( $CMD | python3 -c "
import sys, re, array, fcntl, termios, os

fmt = os.environ.get('FMT')
# with open('/dev/tty', 'wb') as tty:
#     tty.write(f'{fmt}'.encode())
#     tty.flush()
# sys.exit(0)

def get_cell_size():
    buf = array.array('H', [0, 0, 0, 0])
    try:
        fcntl.ioctl(sys.stdout, termios.TIOCGWINSZ, buf)
        rows, cols, px_w, px_h = buf
        return px_w // cols, px_h // rows
    except:
        return 16, 32 # 失敗時的保底值

def get_font_size():
    # 預留 4 個 16-bit 無符號整數的空間 (rows, cols, xpixel, ypixel)
    buf = array.array('H', [0, 0, 0, 0])
    try:
        # 取得視窗大小資訊
        fcntl.ioctl(sys.stdout, termios.TIOCGWINSZ, buf)
        r, c, x, y = buf
        # 如果 x 或 y 是 0，代表終端機沒回報像素，回傳保底值 10x20
        if x == 0 or y == 0: return 10, 20
        return x // c, y // r
    except:
        return 10, 20

def my_print2(out, is_tmux=False):
    # 確保是 bytes
    data = out if isinstance(out, bytes) else str(out).encode()
    if is_tmux:
        # Tmux 穿透處理
        payload = data.replace(b'\x1b', b'\x1b\x1b')        
        final_data = b'\x1bPtmux;\x1b' + payload + b'\x1b\\\\'        
    else:
        final_data = data
    
    # 強制寫入 TTY (這不會被 Bash 的 read 抓到，因為 read 是抓 stdout)
    with open('/dev/tty', 'wb') as tty:
        tty.write(final_data)
        tty.flush()


fw, fh = get_font_size()
font_w, font_h = get_cell_size()


# my_print2(f'fh: {fh}, font_h: {font_h}')
# sys.exit(0)

d = sys.stdin.buffer.read()

# head = d[:500].decode('latin-1', errors='ignore')
head = d[:500]
if fmt == 'iterm2':    
    m = re.search(rb'height=([0-9]+)', head)
    px_h = int(m.group(1))
elif fmt == 'sixel':    
    m = re.search(rb'\"(?:\d+;\d+;)?(\d+);(\d+)', head)
    px_h = int(m.group(2))

if m:
    # 這裡印出的東西會被 Bash 的 read 抓到
    # px_w = int(m.group(1))
    # px_h = int(m.group(2))
    # cell_w = (px_w + (font_w - 1)) // font_w
    cell_h = (px_h + (font_h - 1)) // font_h

    # 2. 空間預留邏輯 (Scrolling Buffer)
    # BUFFER_SPACE 是為了給 Prompt 或 Status bar 留餘地
    dynamic_buffer = int(cell_h / 2)
    BUFFER_SPACE = max(1, min(dynamic_buffer, 15))
    # BUFFER_SPACE = int(cell_h / 2)
    # my_print2(f'BUFFER_SPACE: {BUFFER_SPACE}，cell_h:{cell_h}, px_h: {px_h}, font_h: {font_h}')
    # sys.exit(0)
    TOTAL_MOVE = cell_h + BUFFER_SPACE
    

with open('/dev/tty', 'wb') as tty:
    for _ in range(TOTAL_MOVE):
        tty.write(b'\n')
    
    # B. 游標往回拉到繪圖起點
    # \x1b[{n}A 是 Cursor Up
    tty.write(f'\x1b[{TOTAL_MOVE}A'.encode())
    
    # C. 噴出 Tmux 封裝後的圖片數據
    # 這裡確保每一段 ESC 都有雙重轉義
    escaped_data = d.replace(b'\x1b', b'\x1b\x1b')
    tty.write(b'\x1bPtmux;\x1b' + escaped_data + b'\x1b\x5c')
    
    # D. 將游標移到圖片下方安全區，避免戳破圖層
    # 移到圖片寬度 cell_w 之後，高度 cell_h 之下
    # tty.write(f'\x1b[{cell_h}B\x1b[{cell_w}C'.encode())
    tty.write(f'\x1b[{cell_h + BUFFER_SPACE}B'.encode())
    tty.flush()

    # tty.write(b'\x1bPtmux;\x1b' + d.replace(b'\x1b', b'\x1b\x1b') + b'\x1b\x5c')
    # tty.flush()
# 然後把 d 改為只進入 Vim 內部的「黑洞暫存器」 (這樣 dd 就不會蓋掉 Windows 剪貼簿)    

# if cell_w > 0:
#     print(f'{cell_w} {cell_h}')    
")
        # printf "\033[$((h + 5))B\033[${w}C"
        # printf "\033[5B"
        
        #printf "\033[?25h" #好像不用了
    else
        W=$(($W * 70/100))
        H=$(($H * 70/100))
        CMD="chafa -f sixel --size ${W}x${H} $FILE"
        echo "DEBUG CMD:$CMD"
        $CMD
    #非tmux下wezterm|wez-ssh會自己決定用哪個
        #chafa -f iterm2 --size "${W}x${H}" "$FILE"
    fi
    ;;
    "winterm")
	 if [ -n "$TMUX" ]; then
            W=$(($W * 2/5))
            H=$(($H * 2/5))

            # 1. 先噴出 Tmux 穿透協議的開頭
            printf "\ePtmux;\e"            
            # 2. 執行 chafa，並用 sed 把所有的 ESC (\x1b) 翻倍
            # 這是讓 Sixel 穿過 Tmux 的關鍵步驟
            chafa -f sixel --size "${W}x${H}" "$FILE" | sed 's/\x1b/\x1b\x1b/g'
            
            # 3. 噴出 Tmux 穿透協議的結尾
            printf "\e\\"

        else
            # 非 Tmux 環境，直接噴 Sixel 即可
            chafa -f sixel --size "${W}x${H}" "$FILE"
        fi
        ;;
    *)
        chafa -f symbols --size "${W}x${H}" --colors 256 "$FILE"
        ;;
esac
