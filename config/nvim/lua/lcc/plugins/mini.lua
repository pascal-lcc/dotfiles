-- sa + 範圍 + 符號 saiw} ,
-- 範圍有i (Inside)：內部, a (Around / An)：包含外圍
-- iw (Inside Word)：當前這一個單字
-- iW (Inside BIG Word)：連續的整串字元（包含底線、號碼等直到遇到空白）
-- is (Inside Sentence)：這一個句子
-- ip (Inside Paragraph)：這整個段落
-- 2. 搭配方向與數量 (Motions)
-- 除了 i，你也可以直接拿 Vim 原生的移動指令當作「範圍」：
-- w / e：從目前位置到單字結尾
-- 2. 搭配方向與數量 (Motions)
-- sd + {} ()
-- sr + 舊符號 + 新符號
-- vi{ 或 va {}
-- vif vaf function
-- vib vab visual block

vim.pack.add({
    { src = "https://github.com/echasnovski/mini.files" },
    { src = "https://github.com/nvim-mini/mini.pick" },
    { src = "https://github.com/echasnovski/mini.surround" },
    { src = "https://github.com/echasnovski/mini.indentscope" },
    { src = "https://github.com/echasnovski/mini.ai" },
    { src = "https://github.com/echasnovski/mini.pairs" },
    { src = "https://github.com/echasnovski/mini.comment" },
    { src = "https://github.com/echasnovski/mini.icons" },
    { src = "https://github.com/echasnovski/mini.operators" },
    { src = "https://github.com/echasnovski/mini.hipatterns" },
    { src = "https://github.com/echasnovski/mini.diff" },
    { src = "https://github.com/echasnovski/mini.statusline" },
    { src = "https://github.com/echasnovski/mini.clue" },
    { src = "https://github.com/echasnovski/mini.jump2d" },
    { src = "https://github.com/echasnovski/mini.bufremove" },
    { src = "https://github.com/echasnovski/mini.move" },
    { src = "https://github.com/echasnovski/mini.sessions" },
    { src = "https://github.com/echasnovski/mini.starter" },
    { src = "https://github.com/echasnovski/mini.extra" },
})

local ok_files, mini_files = pcall(require, "mini.files")
if ok_files then
    local open_in_tab = function()
        local fs_entry = mini_files.get_fs_entry()
        if fs_entry and fs_entry.path then
            if fs_entry.fs_type == "file" then
                mini_files.close()
                vim.cmd("tabedit " .. vim.fn.fnameescape(fs_entry.path))
            else
                mini_files.go_in({})
            end
        end
    end

    mini_files.setup({
        mappings = {
            close = "q",
            go_in = "l",
            go_in_plus = "L",
            go_out = "h",
            go_out_plus = "H",
            reset = "<BS>",
            reveal_cwd = "@",
            show_help = "g?",
            synchronize = "S",
            trim_left = "<",
            trim_right = ">",
        },
    })

    vim.api.nvim_create_autocmd("User", {
        pattern = "MiniFilesBufferCreate",
        callback = function(args)
            local buf_id = args.data.buf_id
            -- 在 mini.files 視窗內，按下 <C-t> 觸發開新 Tab
            vim.keymap.set("n", "<C-t>", open_in_tab, { buffer = buf_id, desc = "Open in New Tab" })
        end,
    })
    -- Keymaps
    vim.keymap.set("n", "<leader>fm", function()
        if not mini_files.close() then
            mini_files.open(vim.api.nvim_buf_get_name(0))
        end
    end, { desc = "Toggle Mini Files" })

    vim.keymap.set("n", "-", function()
        if not mini_files.close() then
            mini_files.open(vim.api.nvim_buf_get_name(0))
        end
    end, { desc = "Open Mini Files in Current Dir" })
end

local ok_pick, mini_pick = pcall(require, "mini.pick")
if ok_pick then
    mini_pick.setup({
        options = { use_cache = true },
        -- window = { config = { border = "double" } },
        window = {
            config = function()
                return {
                    relative = "editor",
                    row = math.floor(0.1 * vim.o.lines),
                    col = math.floor(0.1 * vim.o.columns),
                    width = math.floor(0.8 * vim.o.columns),
                    height = math.floor(0.8 * vim.o.lines),
                    border = "double",
                }
            end,
        },
        -- source = { choose = function(item) return item end, },
        -- mappings = {
        --     choose            = '<CR>',  -- Enter 直接打開
        --     choose_in_tab     = '<C-t>', -- Ctrl+t 分頁打開
        --     choose_in_split   = '<C-x>', -- Ctrl+x 水平分開
        --     choose_in_vsplit  = '<C-v>', -- Ctrl+v 垂直開
        --     move_down         = '<C-n>', -- Ctrl+n 往下選
        --     move_up           = '<C-p>', -- Ctrl+p 往上選
        -- },
    })

    local stdpath = vim.fn.stdpath("cache") -- 放在 Neovim 的快取目錄下
    local rg_app_only = stdpath .. "/rg_app_onlyrc"
    local rg_everything = stdpath .. "/rg_everythingrc"
    -- 寫入「日常乾淨版」控制中心（排除 node_modules 和 .git）
    local f1 = io.open(rg_app_only, "w")
    if f1 then
        f1:write("--glob=!node_modules\n--glob=!.git\n")
        f1:close()
    end

    -- 寫入「全域深挖版」控制中心（什麼都不排除，連隱藏檔都吃）
    local f2 = io.open(rg_everything, "w")
    if f2 then
        f2:write("--no-ignore\n--hidden\n")
        f2:close()
    end

    local pick_tabs = function()
        local tabs = vim.api.nvim_list_tabpages()
        local items = {}

        for i, tabpage in ipairs(tabs) do
            local win = vim.api.nvim_tabpage_get_win(tabpage)
            local buf = vim.api.nvim_win_get_buf(win)
            local buf_name = vim.api.nvim_buf_get_name(buf)
            local name = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":t") or "[No Name]"
            local relative_path = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":~:.") or ""

            table.insert(items, string.format("Tab %d: %s  [%s]", i, name, relative_path))
        end

        mini_pick.start({
            source = {
                items = items,
                name = "Tabs",
                choose = function(item)
                    if type(item) == "string" then
                        local tabnr = item:match("Tab (%d+):")
                        if tabnr then
                            local target_tab = tabs[tonumber(tabnr)]

                            vim.schedule(function()
                                if vim.api.nvim_tabpage_is_valid(target_tab) then
                                    vim.api.nvim_set_current_tabpage(target_tab)
                                end
                            end)
                        end
                    end
                end,
            },
        })
    end

    vim.keymap.set("n", "<leader>ft", pick_tabs, { desc = "Pick Open Tabs" })

    vim.keymap.set("n", "<leader>ff", function()
        vim.env.RIPGREP_CONFIG_PATH = rg_app_only
        mini_pick.builtin.files()
    end, { desc = "Find Files (App Only)" })

    vim.keymap.set("n", "<leader>fg", function()
        -- 內文搜尋也一樣聽控制中心的話
        vim.env.RIPGREP_CONFIG_PATH = rg_app_only
        mini_pick.builtin.grep_live()
    end, { desc = "Find Text (App Only)" })

    vim.keymap.set("n", "<leader>fF", function()
        -- 切換到全域版控制中心，解除封印！
        vim.env.RIPGREP_CONFIG_PATH = rg_everything
        mini_pick.builtin.files()
    end, { desc = "Find Files (EVERYTHING)" })

    vim.keymap.set("n", "<leader>fG", function()
        vim.env.RIPGREP_CONFIG_PATH = rg_everything
        mini_pick.builtin.grep_live()
    end, { desc = "Find Text (EVERYTHING)" })

    vim.keymap.set("n", "<leader>fb", function()
        mini_pick.builtin.buffers()
    end, { desc = "Pick Open Buffers" })

    vim.keymap.set("n", "<leader>fr", function()
        local success, err = pcall(function()
            require("mini.pick").builtin.resume()
        end)
        if not success then
            vim.notify("目前沒有上一次的搜尋紀錄可供回復！", vim.log.levels.INFO)
        end
    end, { desc = "Resume Last Pick" })

    vim.keymap.set("n", "<leader>fo", function()
        MiniExtra.pickers.oldfiles()
    end, { desc = "Find Oldfiles (Recent)" })

    local pick_marks = function()
        -- 取得當前 Buffer 所有有效的 Mark (a-z, A-Z, 0-9 等)
        local marks = vim.fn.getmarklist(vim.api.nvim_get_current_buf())
        local items = {}

        for _, m in ipairs(marks) do
            local mark_name = m.mark:sub(2) -- 去掉前綴的 '
            -- 只抓取英文字母 mark (a-z, A-Z) 或數字 mark
            if mark_name:match("^[a-zA-Z0-9]$") then
                local line_num = m.pos[2]
                local col_num = m.pos[3]
                -- 抓取該行的文字內容
                local line_text = vim.api.nvim_buf_get_lines(0, line_num - 1, line_num, false)[1] or ""
                line_text = vim.trim(line_text)

                local display = string.format("Mark [%s]  Line %d: %s", mark_name, line_num, line_text)
                table.insert(items, display)
            end
        end

        if #items == 0 then
            vim.notify("當前 Buffer 沒有設定任何字母 Mark (a-z)！", vim.log.levels.INFO)
            return
        end

        mini_pick.start({
            source = {
                items = items,
                name = "Marks",
                choose = function(item)
                    if type(item) == "string" then
                        -- 抓出 "Mark [a]" 裡面的 'a'
                        local mark_name = item:match("Mark %[(%w)%]")
                        if mark_name then
                            -- 搭配 vim.schedule 避免視窗生命週期影響
                            vim.schedule(function()
                                vim.cmd("normal! '" .. mark_name)
                            end)
                        end
                    end
                end,
            },
        })
    end

    -- 綁定快捷鍵 <leader>fm
    vim.keymap.set("n", "<leader>fm", pick_marks, { desc = "Find Buffer Marks" })

    vim.keymap.set("n", "<leader>tc", "<cmd>tabclose<cr>", { desc = "Close Current Tab" })
    vim.keymap.set("n", "<leader>tn", "<cmd>tabnew<cr>", { desc = "Open New Tab" })
    vim.keymap.set("i", "<C-t>", "<cmd>tabnew<cr>", { desc = "Open New Tab" })

    vim.keymap.set("n", "H", "<cmd>bprevious<cr>", { desc = "Buffer (左)" })
    vim.keymap.set("n", "L", "<cmd>bnext<cr>", { desc = "Buffer (右)" })
    vim.keymap.set("n", "[t", "<cmd>tabprevious<cr>", { desc = "上一個 Tab" })
    vim.keymap.set("n", "]t", "<cmd>tabnext<cr>", { desc = "下一個 Tab" })
    vim.keymap.set("n", "<leader>bd", "<cmd>bdelete<cr>", { desc = "Delete Buffer" })
    vim.keymap.set("n", "<C-p>", "<cmd>tabprevious<cr>", { desc = "上一個 Tab" })
    vim.keymap.set("n", "<C-n>", "<cmd>tabnext<cr>", { desc = "下一個 Tab" })
    vim.keymap.set("i", "<C-p>", "<C-o><cmd>tabprevious<cr>", { desc = "上一個 Tab" })
    vim.keymap.set("i", "<C-n>", "<C-o><cmd>tabnext<cr>", { desc = "下一個 Tab" })
    -- vim.keymap.set('n', 'H', '<cmd>tabprevious<cr>', { desc = '上一個分頁' })
    -- vim.keymap.set('n', 'L', '<cmd>tabnext<cr>', { desc = '下一個分頁' })
else
    vim.notify("mini.pick 尚未下載完成或路徑未就緒...", vim.log.levels.WARN)
end

-- 2. 初始化 mini.surround
local ok_surround, mini_surround = pcall(require, "mini.surround")
if ok_surround then
    mini_surround.setup({
        -- 這裡維持預設的 Keymaps 即可，已經跟經典 surround 習慣非常接近
        mappings = {
            add = "sa", -- Add surround (例如 saiw" 代表在單字加上雙引號)
            delete = "sd", -- Delete surround (例如 sd" 代表刪除雙引號)
            find = "sf", -- Find surround (尋找下一個 Surround)
            find_left = "sF", -- Find surround left
            highlight = "sh", -- Highlight surround (高亮周圍的括號)
            replace = "sr", -- Replace surround (例如 sr"' 代表把雙引號換成單引號)
            update_n_lines = "sn", -- Update n_lines
        },
    })
end

local ok_indent, mini_indent = pcall(require, "mini.indentscope")
if ok_indent then
    mini_indent.setup({
        symbol = "│",
        options = { try_as_border = true },
    })
end

-- ============================================================================
-- 2. mini.icons (圖示)
-- ============================================================================
local ok_icons, mini_icons = pcall(require, "mini.icons")
if ok_icons then
    mini_icons.setup()
    mini_icons.mock_nvim_web_devicons() -- 讓其他套件也能相容使用這個圖示庫
end

-- ============================================================================
-- 3. mini.ai (智慧 Text Objects)
-- ============================================================================
local ok_ai, mini_ai = pcall(require, "mini.ai")
if ok_ai then
    mini_ai.setup({ n_lines = 500 }) -- 搜尋多達 500 行範圍內的匹配括號/參數
end

-- ============================================================================
-- 4. mini.pairs (自動括號對)
-- ============================================================================
local ok_pairs, mini_pairs = pcall(require, "mini.pairs")
if ok_pairs then
    mini_pairs.setup()
end

-- ============================================================================
-- 5. mini.comment (快速註解)
-- ============================================================================
local ok_comment, mini_comment = pcall(require, "mini.comment")
if ok_comment then
    mini_comment.setup()
end

-- ============================================================================
--  mini.operators (文字對調/排序/計算)
-- ============================================================================
local ok_operators, mini_operators = pcall(require, "mini.operators")
if ok_operators then
    mini_operators.setup()
end

-- ============================================================================
-- mini.hipatterns (色碼與 TODO 高亮)
-- ============================================================================
local ok_hipatterns, mini_hipatterns = pcall(require, "mini.hipatterns")
if ok_hipatterns then
    mini_hipatterns.setup({
        highlighters = {
            -- 高亮 Hex 色碼 (例如 #ff0000)
            hex_color = mini_hipatterns.gen_highlighter.hex_color(),
            -- 高亮 TODO, FIXME, NOTE
            fixme = { pattern = "%f[%w criticism]%f[%W]FIXME%f[%W]", group = "MiniHipatternsFixme" },
            todo = { pattern = "%f[%w criticism]%f[%W]TODO%f[%W]", group = "MiniHipatternsTodo" },
            note = { pattern = "%f[%w criticism]%f[%W]NOTE%f[%W]", group = "MiniHipatternsNote" },
        },
    })
end

-- ============================================================================
--  mini.diff (Git 狀態顯示)
-- ============================================================================
local ok_diff, mini_diff = pcall(require, "mini.diff")
if ok_diff then
    mini_diff.setup({
        view = {
            style = "sign",
            signs = { add = "▎", change = "▎", delete = " " },
        },
    })
end

local ok_statusline, mini_statusline = pcall(require, "mini.statusline")
if ok_statusline then
    mini_statusline.setup({
        use_icons = true, -- 自動使用 mini.icons 的圖示
    })
end

local ok_clue, mini_clue = pcall(require, "mini.clue")
if ok_clue then
    mini_clue.setup({
        triggers = {
            { mode = "n", keys = "<Leader>" }, -- 當按下 <Leader> 鍵時觸發提示
            { mode = "x", keys = "<Leader>" },
            { mode = "n", keys = "g" }, -- 按下 g 時觸發提示
            { mode = "n", keys = "<C-w>" },
            { mode = "n", keys = "z" },
            { mode = "x", keys = "z" },
            { mode = "n", keys = "[" },
            { mode = "n", keys = "]" },
            { mode = "n", keys = "s" },
            { mode = "i", keys = "<C-x>" },
        },
        clues = {
            mini_clue.gen_clues.builtin_completion(),
            mini_clue.gen_clues.g(),
            mini_clue.gen_clues.marks(),
            mini_clue.gen_clues.registers(),
        },
    })
end

-- ============================================================================
-- 3. mini.jump2d (畫面 2D 飛躍)
-- ============================================================================
local ok_jump2d, mini_jump2d = pcall(require, "mini.jump2d")
if ok_jump2d then
    mini_jump2d.setup({
        labels = "abcdefghijklmnopqrstuvwxyz", -- 使用英文字母做跳轉標籤
        mappings = { start_jumping = "<leader>j" }, -- 按 <leader>j 開始跳轉
    })
end

-- ============================================================================
-- 4. mini.bufremove (優雅關閉 Buffer)
-- ============================================================================
local ok_bufremove, mini_bufremove = pcall(require, "mini.bufremove")
if ok_bufremove then
    mini_bufremove.setup()
    -- 綁定快捷鍵 <leader>bd 替代原本的 :bd
    vim.keymap.set("n", "<leader>bd", function()
        mini_bufremove.delete(0, false)
    end, { desc = "Close Buffer without destroying split" })
end

-- ============================================================================
-- mini.move (搭配 Ctrl+Shift+方向鍵)
-- ============================================================================
local ok_move, mini_move = pcall(require, "mini.move")

if ok_move then
    mini_move.setup({
        -- 使用官方預設的 Alt+j / Alt+k / Alt+h / Alt+l
        mappings = {
            left = "<M-h>",
            right = "<M-l>",
            down = "<M-j>",
            up = "<M-k>",
            line_left = "<M-h>",
            line_right = "<M-l>",
            line_down = "<M-j>",
            line_up = "<M-k>",
            selection_left = "<M-h>",
            selection_right = "<M-l>",
            selection_down = "<M-j>",
            selection_up = "<M-k>",
        },
        options = {
            reindent_linewise = true, -- 自動智慧縮排
        },
    })
end

local ok_sessions, mini_sessions = pcall(require, "mini.sessions")
if ok_sessions then
    mini_sessions.setup({
        -- 存放所有 Session 的目錄 (不會污染你的專案目錄)
        directory = vim.fn.stdpath("data") .. "/sessions",
        autoread = true, -- 開啟 Neovim/切換目錄時自動讀取
        autowrite = true, -- 離開 Neovim 時自動儲存狀態
        hooks = {
            -- 在 寫入 (Save) Session 之前，自動關閉所有不該被儲存的 UI
            pre_write = function()
                -- 如果 mini.files 開著，先強制關閉，避免記錄到無效 floating window
                if package.loaded["mini.files"] then
                    pcall(MiniFiles.close)
                end
            end,

            -- 在 載入 (Load) Session 之前，先做一次清理
            pre_read = function()
                -- 強制關閉背景沒用到的隱藏 buffers (非當前視窗)
                for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                    if vim.api.nvim_buf_is_valid(buf) and not vim.api.nvim_buf_get_option(buf, "modified") then
                        local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
                        if buftype == "nofile" or buftype == "terminal" then
                            pcall(vim.api.nvim_buf_delete, buf, { force = true })
                        end
                    end
                end
            end,
        },
    })
end

local ok_starter, mini_starter = pcall(require, "mini.starter")
if ok_starter then
    mini_starter.setup({
        header = "🚀 Welcome back!",
        items = {
            -- 自動帶入最近的 5 個 Sessions
            mini_starter.sections.sessions(5, true),
            -- 自動帶入最近開啟的 5 個檔案
            mini_starter.sections.recent_files(5, false, true),
            -- 內建常用操作
            mini_starter.sections.builtin_actions(),
        },
        content_hooks = {
            mini_starter.gen_hook.adding_bullet("» "),
            mini_starter.gen_hook.indexing("section", { "Sessions", "Files", "Builtin" }),
            mini_starter.gen_hook.padding(3, 2),
        },
    })
end

local map = vim.keymap.set

-- <leader>ss -> 彈出選單挑選 Session
map("n", "<leader>ss", function()
    if MiniSessions then
        MiniSessions.select()
    end
end, { desc = "Select Session" })

map("n", "<leader>sl", function()
    if MiniSessions then
        MiniSessions.read()
    end
end, { desc = "Load Session" })
-- <leader>sw -> 手動命名並儲存 Session
map("n", "<leader>sw", function()
    if MiniSessions then
        local name = vim.fn.input("Session Name: ")
        if name ~= "" then
            MiniSessions.write(name)
        end
    end
end, { desc = "Save Session" })

-- <leader>sd -> 選擇刪除 Session
map("n", "<leader>sd", function()
    if MiniSessions then
        MiniSessions.select("delete")
    end
end, { desc = "Delete Session" })

-- <leader>sh -> 隨時打開 Starter 首頁
-- map("n", "<leader>sh", function()
--     if MiniStarter then
--         MiniStarter.open()
--     end
-- end, { desc = "Open Starter Home" })
vim.keymap.set("n", "sh", function()
    vim.cmd("tabnew")
    MiniStarter.open()
end, { desc = "Open Starter in New Tab" })

local ok_extra, mini_extra = pcall(require, "mini.extra")
if ok_extra then
    mini_extra.setup({})
end

-- 搜尋 Git 修改過的檔案 (使用 "modified")
vim.keymap.set("n", "<leader>fc", function()
    MiniExtra.pickers.git_files({ scope = "modified" })
end, { desc = "Search Git Modified Files" })

map("n", "<leader>fd", function()
    MiniExtra.pickers.diagnostic()
end, { desc = "Find Diagnostics" })

