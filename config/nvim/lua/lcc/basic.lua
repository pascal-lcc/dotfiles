local map = vim.keymap.set
local opt = vim.opt

if vim.env.TMUX then
    vim.env.TERM = "tmux-256color"
end
opt.termguicolors = true
opt.mouse = "a"
-- opt.selection = "exclusive" -- 這會讓選取更像現代編輯器，不包含游標下的最後一個字元
opt.timeoutlen = 500 -- 等待「多鍵序列」的時間 (例如你設了 `leader + w`)
-- opt.timeoutlen = 300 -- 從 1000ms 縮短到 300ms
opt.ttimeoutlen = 5 -- 等待「終端機轉義碼」的時間 (如 Esc, Alt 鍵)
-- opt.focusevents = true

-- 基礎縮排、搜尋與行號 (保持不變)
opt.tabstop = 4
opt.shiftwidth = 4
opt.expandtab = true
opt.softtabstop = 4
opt.number = true
opt.relativenumber = true
opt.cursorline = true
opt.clipboard = ""
opt.scrolloff = 10
opt.swapfile = false
opt.list = true

opt.backspace = "indent,eol,start"
-- opt.colorcolumn = "100"
-- opt.completeopt = { "menuone", "noselect", "popup" }
opt.pumheight = 15
-- opt.laststatus = 0
opt.undofile = true
-- opt.ignorecase = true
opt.smartcase = true
opt.foldmethod = "indent"
opt.foldlevelstart = 99

-- opt.wrap = false -- 不自動換行
opt.signcolumn = "yes" -- 顯示診斷標計
opt.winborder = "rounded"
opt.ignorecase = true -- 搜索忽略大小寫
opt.smartcase = true -- 當包含大寫字母時，搜尋區分大小寫
-- opt.hlsearch = false -- 搜索匹配不高亮
opt.incsearch = true -- 增量搜索
opt.foldmethod = "expr" -- 折疊方式使用regex
-- opt.foldexpr = "nvim_treesitter#foldexpr()" -- 使用 Treesitter 表達折疊
opt.foldlevel = 99 -- 打開文件預設不折疊

-- vim.opt.guicursor = {
-- "n-c:block-Cursor",          -- Normal/Cmd: 塊狀
-- "i-ci-ve:ver25-CursorI",     -- Insert: 細線
-- "v-r:ver25-CursorV",         -- Visual/Replace: 也是細線，但關聯到 CursorV
--   "n-v-c:block",                -- Normal, Visual, Command 預設是塊狀
--   "i-ci-ve:ver25",              -- Insert 模式是 25% 寬度的細線
--   "r-cr:hor20",                 -- Replace 模式是水平線
--   "o:hor50",                    -- Operator-pending
--   -- "v:ver25",                    -- 【關鍵】將 Visual 模式改為 25% 寬度的細線
--   "a:blinkwait700-blinkoff400-blinkon250-Cursor/lCursor", -- 閃爍設定
-- }
-- 設定對應的顏色
-- 正確的寫法
local set_hl = vim.api.nvim_set_hl

-- vim.opt.guicursor:append("a:blinkwait700-blinkon400-blinkoff250")
-- 停止操作 1 秒後才開始呼吸，亮 400ms，暗 200ms
-- vim.opt.guicursor:append("a:blinkwait1000-blinkon400-blinkoff200")
vim.opt.guicursor:append("a:blinkwait100-blinkon400-blinkoff200")
vim.opt.guicursor:append("v:hor35-CursorV")
vim.opt.guicursor:append("v:ver25-CursorV")
vim.opt.guicursor:append("i-ci-ve:ver35-CursorI-blinkwait100-blinkon400-blinkoff200")

-- 確保當前 Namespace (0) 下設定
set_hl(0, "Cursor", { bg = "#7aa2f7", fg = "#15161e" })
set_hl(0, "CursorI", { bg = "#9ece6a", fg = "#15161e" })
set_hl(0, "CursorV", { bg = "#bb9af7", fg = "#15161e" })
-- set_hl(0, "MatchParen", { underline = true, sp = "#ff9e64" })
-- 讓 MatchParen 不要太搶戲，改用底線
-- set_hl(0, "MatchParen", { underline = true, bold = true, sp = "#ff9e64" })
-- bg: 游標背景色 (橘色)
-- fg: 游標所在的文字顏色 (設為黑色或深色以保持對比)
vim.api.nvim_set_hl(0, "CursorI", { bg = "#ff9e64", fg = "#000000", bold = true })
-- vim.opt.guicursor = "n-v-c:block-Cursor,i-ci-ve:ver35-CursorI-blinkwait100-blinkon500-blinkoff150,r-cr:hor20,o:hor50"

set_hl(0, "MatchParen", {
    underline = true,
    bold = true,
    italic = true,
    sp = "#ff9e64",
    fg = "NONE",
    bg = "#3b4261", -- 給一個極暗的背景，讓它在底層浮現
})

-- 讓選取範圍變成非常明顯的亮紫色或亮藍色
-- vim.api.nvim_set_hl(0, "Visual", { bg = "#3e4452", fg = "NONE" })
-- 如果你想要更閃耀
set_hl(0, "Visual", { bg = "#bb9af7", fg = "#000000" })
-- vim.api.nvim_set_hl(0, "Visual", { bg = "#444444", reverse = false })

-- 在你的 init.lua
local is_root = os.getenv("USER") == "root" or os.getenv("SUDO_USER") ~= nil

if is_root then
    set_hl(0, "Cursor", { bg = "#ff5555", fg = "#ffffff" })
    -- 你甚至可以讓狀態列變色
    set_hl(0, "StatusLine", { bg = "#ff0000", fg = "#ffffff" })
end

-- OSC 52 噴射函數
local function osc52_yank(lines)
    local str = table.concat(lines, "\n")
    if #str > 65536 then
        return
    end
    local b64 = vim.fn.system("base64 | tr -d '\n'", str)
    local osc = "\27]52;c;" .. b64 .. "\7"
    if os.getenv("TMUX") then
        osc = "\27Ptmux;\27" .. osc .. "\27\\"
    end
    vim.fn.chansend(vim.v.stderr, osc)
end

-- 強化的自動命令
vim.api.nvim_create_autocmd("TextYankPost", {
    group = vim.api.nvim_create_augroup("OSC52_Sync", { clear = true }),
    callback = function()
        local event = vim.v.event
        -- 關鍵修正：放寬判斷條件
        -- 只要不是黑洞暫存器 ("_)，就同步到系統剪貼簿
        if event.regname ~= "_" and event.regname ~= "c" then
            osc52_yank(event.regcontents)
        end
    end,
})

-- === 按鍵映射 (Keymaps) ===

-- 1. 處理 x (剪下):
-- 在 Normal Mode: 刪除字元並存入預設暫存器
-- map("n", "x", "x")
-- Normal Mode: 將 x 導向黑洞暫存器 (_)，不污染剪貼簿
map("n", "x", '"_x', { noremap = true })
-- 在 Visual Mode: 強制使用預設暫存器進行刪除 (這會觸發 TextYankPost)
-- 使用 '"d' 確保它不會去撞下面那個 "_d 的映射
map("x", "x", "d")

-- 2. 處理 d (刪除): 全部導向黑洞
map({ "n", "x" }, "d", '"_d')
map("n", "dd", '"_dd')
map("n", "D", '"_D')

map({ "n", "x" }, "c", '"cc', { noremap = true })
map({ "n", "x" }, "C", '"cC', { noremap = true })

-- 3. 貼上與移動優化
map("x", "p", "P")
map("n", "j", [[v:count > 5 ? "m'" . v:count . "j" : "j"]], { expr = true, silent = true })
map("n", "k", [[v:count > 5 ? "m'" . v:count . "k" : "k"]], { expr = true, silent = true })
map("n", "<Esc>", "<cmd>nohlsearch<CR>", { desc = "按 Esc 取消搜尋高亮" })

-- 檢查 leader key 是否已設定，若無則設定為空白鍵 (space)
if not vim.g.mapleader or vim.g.mapleader == "" then
    vim.g.mapleader = " "
end

-- 同理也可以設定 localleader
if not vim.g.maplocalleader or vim.g.maplocalleader == "" then
    vim.g.maplocalleader = "\\"
end

-- 1. 定義通用的智慧退出函式
local function smart_quit(all)
    local command = all and "qa" or "q" -- 決定基本指令 (q 或 qa)
    local save_cmd = all and "waq" or "wq" -- 決定儲存指令 (wq 或 waq)
    local force_cmd = all and "qa!" or "q!" -- 決定強制指令 (q! 或 qa!)

    -- 檢查是否有異動
    local modified = false
    if all then
        -- 遍歷所有載入的 buffer
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_get_option_value("modified", { buf = buf }) then
                modified = true
                break
            end
        end
    else
        -- 僅檢查目前 buffer
        modified = vim.api.nvim_get_option_value("modified", { buf = 0 })
    end

    -- 執行邏輯
    if modified then
        local scope_text = all and "所有視窗" or "目前視窗"
        local choice = vim.fn.confirm(
            "偵測到 [" .. scope_text .. "] 有未儲存變動：",
            "&Save and Quit\n&Just Quit (Discard)\n&Cancel",
            3
        )
        if choice == 1 then
            vim.cmd(save_cmd)
        elseif choice == 2 then
            vim.cmd(force_cmd)
        end
    else
        -- 沒異動則直接執行退出
        -- 用 pcall 包起來防止在最後一個視窗關閉時噴錯（選填）
        pcall(vim.cmd, command)
    end
end

-- ... 上方的 smart_quit 函式內容 ...

-- 小寫 q：智慧關閉目前
vim.keymap.set("n", "<leader>qt", function()
    smart_quit(false)
end, { desc = "Smart Quit Current" })

-- 大寫 Q：智慧關閉全部
vim.keymap.set("n", "<leader>qa", function()
    smart_quit(true)
end, { desc = "Smart Quit All" })

-- Ctrl+q：當你連對話框都懶得看，想直接「炸掉」所有視窗時
vim.keymap.set("n", "<leader>qq", ":qa!<CR>", { desc = "Emergency Force Quit All" })

local map = vim.keymap.set

-- 先刪除舊的衝突映射
map("n", "<A-Up>", "<cmd>resize +3<CR>", { desc = "Increase window height" })
map("n", "<A-Down>", "<cmd>resize -3<CR>", { desc = "Decrease window height" })
map("n", "<A-Left>", "<cmd>vertical resize -3<CR>", { desc = "Decrease window width" })
map("n", "<A-Right>", "<cmd>vertical resize +3<CR>", { desc = "Increase window width" })

map("n", "<leader>w=", "<C-w>=", { desc = "Equalize window sizes" }) -- 所有視窗均分
map("n", "<leader>wo", "<C-w>o", { desc = "Close other windows" }) -- 獨佔，關閉其他視窗
map("n", "<leader>z", "<cmd>tab split<CR>", { desc = "Zoom window into new tab" })
map("n", "<leader>Z", "<cmd>tabclose<CR>", { desc = "Unzoom / Close zoom tab" })
