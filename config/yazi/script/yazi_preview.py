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

def is_wsl():
    # 1. 檢查你的硬核指標：WSLInterop
    if os.path.exists("/proc/sys/fs/binfmt_misc/WSLInterop"):
        return True
    # 2. 備用方案：檢查自定義 Kernel 是否仍保留微軟特徵
    try:
        with open("/proc/version", "r") as f:
            v = f.read().lower()
            if "microsoft" in v or "wsl" in v:
                return True
    except:
        pass
    return False

def check_actually_ssh(is_tmux):
    # 1. 基本檢查 (非 Tmux 或 幸運的情況)
    if any(k in os.environ for k in ["SSH_TTY", "SSH_CLIENT", "SSH_CONNECTION"]):
        return True
    
    # 2. 如果在 Tmux 裡，環境變數可能失效，直接問 Tmux Server
    if is_tmux:
        try:
            # 查詢當前 attach 這個 session 的所有客戶端資訊
            # 如果客戶端是經由 sshd 進來的，通常會反映在 pid 或 cmd 裡
            # 這裡我們用一個最簡單的判定：看 tmux 的 client_name 或環境
            import subprocess
            # 取得當前 tmux client 的環境變數 (這是動態的，不受 session 固化影響)
            res = subprocess.check_output(["tmux", "show-environment", "SSH_CLIENT"], 
                                          stderr=subprocess.DEVNULL).decode()
            if "SSH_CLIENT" in res:
                return True
        except:
            pass
    return False    

def detect_terminal():
    is_tmux = "TMUX" in os.environ
    wsl_mode = is_wsl()

    def wrap(seq):
        return f"\x1bPtmux;\x1b{seq}\x1b\\" if is_tmux else seq

    res_str = ""
    fd = sys.stdin.fileno()
    if not os.isatty(fd): return "putty", 24

    old_settings = termios.tcgetattr(fd)
    try:
        new_settings = termios.tcgetattr(fd)
        new_settings[3] = new_settings[3] & ~termios.ECHO & ~termios.ICANON
        termios.tcsetattr(fd, termios.TCSADRAIN, new_settings)

        # 發送查詢
        # sys.stdout.write(wrap("\x1b[c"))   # DA1
        # sys.stdout.write(wrap("\x1b[>q"))  # Name
        sys.stdout.write(wrap("\x1b[c\x1b[>q\x1b[16t"))
        sys.stdout.flush()

        # 大塊讀取，對付 SSH 延遲
        start_time = time.time()
        while time.time() - start_time < 0.5:
            r, _, _ = select.select([sys.stdin], [], [], 0.1)
            if r:
                # os.read 比 sys.stdin.read(1) 快且穩
                chunk = os.read(fd, 1024).decode(errors='ignore')
                if chunk:
                    res_str += chunk
                
                    # if "WezTerm" in res_str and not os.environ.get("SSH_TTY"):                        
                    #     time.sleep(0.01) # 給版本號一點抵達時間
                    #     chunk = os.read(fd, 1024).decode(errors='ignore') # 再吞一口
                    #     res_str += chunk
                    #     break
                    if not os.environ.get("SSH_TTY") and "WezTerm" in res_str and "\x1b[6;" in res_str:
                        break                        
            else:
                if res_str: break
    finally:
        termios.tcflush(fd, termios.TCIFLUSH)
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
    
    # 最終判定邏輯

    m_cell = re.search(r'\x1b\[6;(\d+);(\d+)t', res_str)
    cell_h = int(m_cell.group(1)) if m_cell else 24

    sys.stderr.write(f"\n[DEBUG] res_str: {repr(res_str)}\n")
    sys.stderr.flush()
    
  # 2. 判定是否為 SSH (處理 tmux attach 遺失變數的強化版)
    # 我們檢查 SSH_TTY 或是 Tmux 的動態環境
    is_live_ssh = any(k in os.environ for k in ["SSH_TTY", "SSH_CLIENT", "SSH_CONNECTION"])
    if is_tmux and not is_live_ssh:
        try:
            # 問 Tmux 客戶端有沒有 SSH 跡象
            import subprocess
            res = subprocess.check_output(["tmux", "show-environment", "SSH_CLIENT"], 
                                          stderr=subprocess.DEVNULL).decode()
            if "SSH_CLIENT" in res: is_live_ssh = True
        except: pass

    # 3. 環境代號判定 (排除法優先)
    # 即使沒有 "WezTerm" 字串，只要滿足條件，我們就認定它是 WezTerm 的特定模式
    is_wez_pattern = "WezTerm" in res_str or "?61;" in res_str
    # is_wez_pattern = "WezTerm" in res_str in res_str
    if ";4;" in res_str:
        enable_sixel = True
    else:
        enable_sixel = False

    if is_wez_pattern:
        # --- 情況 A：遠端隧道 (Open-SSH) ---
        # 特徵：是 SSH，且沒有 Sixel 宣告 (;4;)
        if is_live_ssh and ";4;" not in res_str:
            return "wezterm-tunnel", cell_h, enable_sixel
        
        # --- 情況 B：遠端標準 SSH ---
        if is_live_ssh and ";4;" in res_str:
            return "wezterm-remote", cell_h, enable_sixel

        # --- 情況 C：本地 WSL (含 Tmux) ---
        # 只要在 WSL 裡，且不是 SSH 進來的，就是本地 WSL
        if wsl_mode:
            return "wezterm-wsl", cell_h, enable_sixel

        # --- 情況 D：本地 Linux ---
        return "wezterm-local", cell_h, enable_sixel

    # --- 非 WezTerm 的保底 ---
    if ";4;" in res_str: return "sixel-compat", cell_h, enable_sixel
    return "putty", 24, enable_sixel

import subprocess
import sys

def send_chafa_iterm2_chunked(img_path, w, h, is_tmux=False):
    """
    img_path: 圖片路徑
    w, h: 目標字元格寬高 (例如 74, 16)
    is_tmux: 是否需要 Tmux 穿透處理
    """
    # 1. 執行 chafa，獲取它產生的 iterm2 序列
    # 我們不加 --size，改用 --width 和 --height 確保精確度
    cmd = ["chafa", "--format", "iterm2", f"--size={w}x{h}", img_path]
    
    try:
        # 抓取 chafa 輸出的完整 Base64 序列
        chafa_output = subprocess.check_output(cmd)
    except subprocess.CalledProcessError:
        return

    # 2. 分塊處理
    # chafa 的輸出已經包含 \x1b]1337;... 和 \x07
    chunk_size = 4000 
    
    if is_tmux:
        # 開始 Tmux 穿透模式
        # 注意：chafa 輸出的 \x1b (ESC) 在 Tmux 穿透裡通常需要 Double ESC
        # 我們將所有的 \x1b 替換成 \x1b\x1b
        payload = chafa_output.replace(b"\x1b", b"\x1b\x1b")
        
        sys.stdout.buffer.write(b"\x1bPtmux;\x1b")
        
        # 分塊寫入 Stdout.buffer (處理 bytes)
        for i in range(0, len(payload), chunk_size):
            sys.stdout.buffer.write(payload[i:i+chunk_size])
            sys.stdout.buffer.flush()
            
        sys.stdout.buffer.write(b"\x1b\\")
    else:
        # 非 Tmux 模式，直接噴發
        sys.stdout.buffer.write(chafa_output)
    
    sys.stdout.buffer.flush()


def run():
    if len(sys.argv) < 2: return
    file_path = sys.argv[1]
    is_tmux = "TMUX" in os.environ
    
    w, h = get_terminal_size()
    env, cell_h, enable_sixel = detect_terminal()

    termios.tcflush(sys.stdin.fileno(), termios.TCIFLUSH)

    print(f'env:{env}, is_tmux:{is_tmux}')


    # if "wezterm" in env:
    #     scale = 0.5 if is_tmux else 0.5
    #     w, h = int(w * scale), int(h * scale)

    # if "wezterm-remote" in env:
    #     if is_tmux:
    #         scale = 0.7
    #         w, h = int(w * scale), int(h * scale)


    if is_tmux:
        # 1. 在 Tmux 內不論偵測結果，強行鎖定 sixel，確保穩定        
        fmt = "iterm2"
        if env == "winterm" or env == "sixel-compat":
            fmt = "sixel"
        # 2. 手動測試：上拉 5 行（減少傳給 chafa 的高度預算）
        # 這能確保圖片絕對不會撞到 Tmux Status Bar
        if enable_sixel:
            fmt = "sixel"
        
        h = max(1, h - 5)        
        cmd = ["chafa", "-f", fmt, "--size", f"{w}x{h}", file_path]
    else:
        # 非 Tmux 環境下維持原本的偵測邏輯
        if env == "winterm":
            fmt = "sixel"
        else:
            fmt = "sixel" if "sixel" in env else "iterm2"

        if enable_sixel:
            fmt = "sixel"

        cmd = ["chafa", "-f", fmt, "--size", f"{w}x{h}", file_path]

       
    sys.stderr.write(f"\nDEBUG CMD: {' '.join(cmd)}\n")
    sys.stderr.flush()
    
    try:
        raw_data = subprocess.check_output(cmd)
    except: return

# 1. 解析像素並計算 cell_h (關鍵：像素轉行數)
    # 根據你的數據，WezTerm 正常縮放下的字體高約為 32
    
    # 預設值，如果抓不到像素就用傳進來的參數
    cell_h = h 
    # sys.stderr.write("\nDEBUG cell_h: {}\n".format(cell_h))
    # sys.stderr.flush()
    if fmt == "iterm2":
        m = re.search(rb"height=([0-9]+)", raw_data)
        if m:
            px_h = int(m.group(1).decode())    
    elif fmt == "sixel":
        m = re.search(rb'\"(?:[0-9]+;[0-9]+;)?([0-9]+);([0-9]+)', raw_data[:500])
        if m:
            px_h = int(m.group(2).decode())

    
    total_move = int(px_h)
    
    # sys.stderr.write("\nDEBUG cell_h: {}，total_move: {}, px_h: {}\n".format(cell_h,total_move,px_h))
    # sys.stderr.flush()

    # 3. 封裝輸出數據
    
    tty_out = os.open("/dev/tty", os.O_WRONLY)
    try:
        output = []
        # A. 推開空間 (向下移動 total_move 行)
        
        if fmt == "iterm2":
            output.append(b"\r\x1b[K") # 回行首並清行
            for _ in range(total_move):
                output.append(b"\n")
            
            output.append(f"\x1b[{total_move}A\r".encode())

        if fmt == "sixel" and is_tmux:
            cell_h = 24
            total_move = (px_h // cell_h) + 3
            print(f'total_move:{total_move}, px_h:{px_h}')
            
            for _ in range(total_move):
                output.append(b"\n")
                
            output.append(f"\x1b[{total_move}A\r".encode())

        # C. 噴圖片 (針對 Tmux 穿透)
        payload = raw_data.replace(b"\x1b", b"\x1b\x1b")
        payload = payload.replace(b"\x1b\x1b[?25l", b"").replace(b"\x1b\x1b[?25h", b"")
        # payload = raw_data
        if is_tmux:
            # B. 回跳到繪圖起點 (向上跳 total_move 行)
            
            output.append(b"\x1bPtmux;\x1b" + payload + b"\x1b\x5c")

        else:
            output.append(payload)
            # output.append(f"\x1b[{cell_h + 1}E\r".encode())
        
        # D. 跳回圖片下方的安全區 (Exactly total_move 行)
        if fmt == "iterm2":
            output.append(f"\x1b[{total_move}B\r".encode())

        if fmt == "sixel" and is_tmux:
            output.append(f"\x1b[{total_move}B\r".encode())
        
        # 一次性噴發，減少 SSH 抖動
        os.write(tty_out, b"".join(output))
    finally:
        os.close(tty_out)

if __name__ == "__main__":
    run()
