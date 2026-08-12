-- 1. 指定下載路徑（為了保證相容性，我們改用最標準的原生 opt 目錄）
local install_path = vim.fn.stdpath("data") .. "/pack/plugins/opt/nvim-scrollbar"

-- 2. 物理檢查：如果沒資料夾，就極速下載
if vim.fn.empty(vim.fn.glob(install_path)) > 0 then
    vim.notify("正在為您原生下載 nvim-scrollbar...", vim.log.levels.INFO)
    vim.fn.system({
        "git",
        "clone",
        "--depth", "1",
        "https://github.com/petertriho/nvim-scrollbar",
        install_path
    })
    vim.notify("nvim-scrollbar 下載完成！", vim.log.levels.INFO)
end

vim.opt.rtp:append(install_path)

-- 4. 落地執行：這時候 require 絕對找得到，而且 100% 觸發
-- 強制給予滑塊一個扎實的灰色/藍色（防全透明隱形）
vim.api.nvim_set_hl(0, "ScrollBarHandle", { bg = "#565f89", ctermbg = "DarkGray" })
require("scrollbar").setup({
    show = true,
    set_winblend = 0,
    
    -- 🎯 大絕招 1：把 folds 設定成一個極大的數字，等同於直接停用折疊計算
    folds = 99999, 
    
    handle = {
        text = " ",
        color = nil,
        blend = 0,
    },
    
    -- 🎯 大絕招 2：把所有可能出現的內建 Marks 文字全塞進去，通通強制換成空格 " "
    marks = {
        Search    = { text = { " ", " " }, priority = 1, color = "#ff9e64" },
        Error     = { text = { " ", " " }, priority = 2, color = "#db4b4b" },
        Warning   = { text = { " ", " " }, priority = 3, color = "#e0af68" },
        Info      = { text = { " ", " " }, priority = 4, color = "#0db9d7" },
        Hint      = { text = { " ", " " }, priority = 5, color = "#1abc9c" },
        Misc      = { text = { " ", " " }, priority = 6, color = "#7aa2f7" },
        Cursor    = { text = " ", priority = 0 }, -- 游標點也換成空，不吃文字
    },
    
    -- 🎯 大絕招 3：徹底關掉所有自動搜集資訊的後台 handlers
    handlers = {
        cursor = false,
        diagnostics = false,
        gitsigns = false,
        search = false,
        ale = false,
    },
    excluded_buftypes = { "terminal", "nofile" },
    excluded_filetypes = { "cmp_menu", "noice", "prompt" },
})

-- vim.keymap.set({ 'n', 'i', 'v' }, '<LeftDrag>', function()
--     local mouse = vim.fn.getmousepos()
--     local max_columns = vim.o.columns
--     local main_win = vim.api.nvim_get_current_win()
--     local win_height = vim.api.nvim_win_get_height(main_win)
--
--     if mouse.screencol >= max_columns and mouse.winrow > 0 and mouse.winrow <= win_height then
--         local total_lines = vim.api.nvim_buf_line_count(0)
--         local click_ratio = mouse.winrow / win_height
--         local target_line = math.floor(total_lines * click_ratio)
--         if target_line < 1 then target_line = 1 end
--         if target_line > total_lines then target_line = total_lines end
--         vim.api.nvim_win_set_cursor(main_win, { target_line, 0 })
--         vim.fn.win_execute(main_win, "normal! zz")
--
--         local mode = vim.api.nvim_get_mode().mode
--         if mode:sub(1, 1) == 'v' or mode:sub(1, 1) == 'V' then
--             vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), 'n', false)
--         end
--         return
--     end
--
--     vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<LeftDrag>", true, false, true), 'n', false)
-- end, { desc = "Scrollbar Safe Drag (No Visual)" })
--
-- vim.keymap.set({ 'n', 'i' }, '<LeftMouse>', function()
--     local mouse = vim.fn.getmousepos()
--     local max_columns = vim.o.columns
--
--     if mouse.screencol >= max_columns then
--         return
--     end
--
--     vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<LeftMouse>", true, false, true), 'm', false)
-- end, { desc = "Scrollbar Safe Click" })


