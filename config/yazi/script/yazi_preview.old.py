#!/usr/bin/python3
import sys, subprocess, os, re, select, time, termios

def get_terminal_size():
    # 模仿原 Bash 的尺寸計算邏輯
    try:
        cols, lines = os.get_terminal_size()
    except:
        cols, lines = 80, 24
    
    max_w = cols - 8 if cols > 8 else 8
    req_w = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else max_w
    w = min(req_w if req_w >= 8 else max_w, max_w)
    
    max_h = lines - 8 if lines > 8 else 8
    req_h = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].isdigit() else max_h
    h = min(req_h if req_h >= 8 else max_h, max_h)
    return w, h

def detect_terminal():
    is_tmux = "TMUX" in os.environ
    def wrap(seq):
        return f"\x1bPtmux;\x1b{seq}\x1b\\" if is_tmux else seq

    res_str = ""
    fd = sys.stdin.fileno()
    if not os.isatty(fd): return "putty"

    # --- 核心修正：抑制 Echo 以防偵測文字噴出 ---
    old_settings = termios.tcgetattr(fd)
    try:
        new_settings = termios.tcgetattr(fd)
        new_settings[3] = new_settings[3] & ~termios.ECHO & ~termios.ICANON
        termios.tcsetattr(fd, termios.TCSADRAIN, new_settings)

        # 發送查詢指令
        sys.stdout.write(wrap("\x1b[c"))   # DA1
        sys.stdout.write(wrap("\x1b[>q"))  # Name
        sys.stdout.flush()

        # SSH 友善讀取：最多等待 0.3 秒，循環消耗所有數據
        start_time = time.time()
        while time.time() - start_time < 0.3:
            r, _, _ = select.select([sys.stdin], [], [], 0.05)
            if r:
                res_str += sys.stdin.read(1)
                # 如果拿到完整標籤則提早準備結束
                if "WezTerm" in res_str and ";4;" in res_str:
                    time.sleep(0.02) # 讀乾淨剩餘字元
            else:
                if res_str: break 
    finally:
        # 強力清空緩衝區，並恢復設定
        termios.tcflush(fd, termios.TCIFLUSH)
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
    
    if "WezTerm" in res_str:
        return "wezterm-sixel" if ";4;" in res_str else "wezterm"
    
    # --- 加入這段：識別 Windows Terminal ---
    # Winterm 通常會回報 ;4; (Sixel) 以及 ;15; 或 ;16;
    if ";4;" in res_str or ";15;" in res_str or ";16;" in res_str:
        return "winterm"
    

    return "sixel-compat" if ";4;" in res_str else "putty"

def run():
    if len(sys.argv) < 2: return
    file_path = sys.argv[1]
    is_tmux = "TMUX" in os.environ
    
    env = detect_terminal()
    w, h = get_terminal_size()

    # WezTerm 在 SSH 下的比例修正
    if "wezterm" in env:
        scale = 0.38 if is_tmux else 0.5
        w, h = int(w * scale), int(h * scale)

    # 決定輸出格式：SSH 且非 Tmux 建議優先用 sixel 以保持穩定
    # if env == "winterm":
    #     fmt = "sixel"
    # else:
    #     fmt = "sixel" if "sixel" in env else "iterm2"

    if is_tmux:
        # 1. 在 Tmux 內不論偵測結果，強行鎖定 sixel，確保穩定
        fmt = "sixel"
        fmt = "iterm2"
        # 2. 手動測試：上拉 5 行（減少傳給 chafa 的高度預算）
        # 這能確保圖片絕對不會撞到 Tmux Status Bar
        h = max(1, h - 5)
        cmd = ["chafa", "-f", fmt, "--size", f"{w}x{h}", file_path]
    else:
        # 非 Tmux 環境下維持原本的偵測邏輯
        if env == "winterm":
            fmt = "sixel"
        else:
            fmt = "sixel" if "sixel" in env else "iterm2"


        # print(f'fmt:{env}'.encode())
        # sys.exit(0)        


        cmd = ["chafa", "-f", fmt, "--size", f"{w}x{h}", file_path]

       
    sys.stderr.write(f"\nDEBUG CMD: {' '.join(cmd)}\n")
    sys.stderr.flush()
    
    try:
        raw_data = subprocess.check_output(cmd)
    except: return

    real_h = h
    if fmt == "iterm2":
        match = re.search(rb"height=(\d+)", raw_data)
        if match: real_h = int(match.group(1).decode())
    elif fmt == "sixel":
        # Sixel 數據中包含像素高度，格式通常為 "q;1;1;寬;高"
        # 我們從數據頭部尋找像素高度標籤        
        match = re.search(rb"\"(?:\d+;\d+;)?(\d+);(\d+)", raw_data[:200])
        if match:
            px_h = int(match.group(2).decode())
            # 假設終端機字體高度約 32 像素 (Windows Terminal 常見值)
            # 這能精確算出圖片佔用了幾列
            real_h = (px_h + 31) // 32


    # 繪圖輸出核心
    tty_out = os.open("/dev/tty", os.O_WRONLY)
    try:
        # 1. 空間準備：清除當前行、推開空間並回跳
        os.write(tty_out, b"\r\x1b[K") # 回行首並清空
        
        offset = 10 if is_tmux else 0
        for _ in range(real_h + offset):
            os.write(tty_out, b"\n")
            
        # 回跳的高度增加 5 行，這會讓圖片起點往上提
        os.write(tty_out, f"\x1b[{real_h + offset}A\r".encode())

        # 2. 噴發圖片
        if is_tmux:
            # Tmux 大包封裝邏輯
            # 不要自己寫 os.write 了，改用 subprocess 配合 sed 來處理穿透
            # 這樣能保證 stream 的穩定性，就像 .sh 版一樣穩
            # with subprocess.Popen(['sed', 's/\x1b/\x1b\x1b/g'], stdin=subprocess.PIPE, stdout=tty_out) as proc:
            #     os.write(tty_out, b"\x1bPtmux;\x1b") # 噴頭
            #     proc.communicate(input=raw_data)    # 噴中間 (自動轉義)
            #     os.write(tty_out, b"\x1b\\")        # 噴尾# 
            
            # payload = raw_data.replace(b"\x1b", b"\x1b\x1b")
            # payload = payload.replace(b"\x1b\x1b[?25l", b"").replace(b"\x1b\x1b[?25h", b"")
            # os.write(tty_out, b"\x1bPtmux;\x1b" + payload + b"\x1b\\")

            payload = raw_data.replace(b"\x1b", b"\x1b\x1b")
            os.write(tty_out, b"\x1bPtmux;\x1b" + payload + b"\x1b\x5c")
        else:
            # 針對 SSH 大圖變形修正：確保在純淨 TTY 執行
            if "wezterm" in env and "sixel" not in env:
                # 使用 subprocess 直接對 TTY 輸出，避免緩衝導致的斷片
                subprocess.run(cmd, stdout=tty_out)
            else:
                os.write(tty_out, raw_data)

        # 3. 游標歸位到圖片底部
        os.write(tty_out, f"\x1b[{real_h}B\r".encode())        
    finally:
        os.close(tty_out)

if __name__ == "__main__":
    run()
