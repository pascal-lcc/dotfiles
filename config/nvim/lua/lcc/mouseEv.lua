local ptool = require("lcc.tools")
local log = ptool.log('~/nvim.log')

local function scroll_jump(mouse, info)
    -- 判定：如果點擊命中螢幕最右側邊界
    if mouse.screencol >= info.max_columns and mouse.winrow > 0 and mouse.winrow <= info.win_height then
        local total_lines = vim.api.nvim_buf_line_count(0)
        local click_ratio = mouse.winrow / info.win_height
        local target_line = math.floor(total_lines * click_ratio)
        
        if target_line < 1 then target_line = 1 end
        if target_line > total_lines then target_line = total_lines end
        
        vim.api.nvim_win_set_cursor(info.main_win, { target_line, 0 })
        vim.fn.win_execute(info.main_win, "normal! zz")
        if info.is_insert then vim.cmd('startinsert') end
        
        return true -- 🎯 已處理，中斷鏈條，後面的人不用做了
    end
    return false -- 🔄 未命中，放行給下一個 handler
end

vim.keymap.set({ 'n', 'i' }, '<C-LeftMouse>', '<Nop>')
vim.keymap.set({ 'n', 'i' }, '<C-LeftDrag>', '<Nop>')

table.insert(ptool.LeftRelease_handlers, 1, scroll_jump)

vim.keymap.set({ 'n', 'i' }, '<LeftRelease>', function()
    local mouse = vim.fn.getmousepos()
    local current_mode = vim.api.nvim_get_mode().mode
    
    -- 預先封裝常用視窗環境資訊，避免每個 handler 重複撈取效能浪費
    local info = {
        main_win    = vim.api.nvim_get_current_win(),
        max_columns = vim.o.columns,
        is_insert   = (current_mode:sub(1, 1) == 'i'),
    }
    info.win_height = vim.api.nvim_win_get_height(info.main_win)
    info.win_width  = vim.api.nvim_win_get_width(info.main_win)

    for _, handler in ipairs(ptool.LeftRelease_handlers) do
        if handler(mouse, info) then
            break
        end
    end
end, { desc = "Chain of Responsibility Mouse Release Manager" })
