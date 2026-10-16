-- 1. Normal 模式：保留你原本習慣的原生即時指令
vim.keymap.set("n", "<leader>sr", function()
    local cword = vim.fn.expand("<cword>")
    if cword == "" then
        vim.notify("目前游標下沒有字串！", vim.log.levels.WARN)
        return
    end
    local keys = string.format(":%s/\\<<C-r><C-w>\\>/<C-r><C-w>/gcI<Left><Left><Left><Left>", "%s")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
end, { desc = "Replace word globally (confirm)" })

-- 2. Visual 模式：Sublime 風格對話框
local function open_sublime_replace_dialog()
    local start_pos = vim.fn.getpos("v")
    local end_pos = vim.fn.getpos(".")
    local mode = vim.fn.mode()
    
    local selected_lines = vim.fn.getregion(start_pos, end_pos, { type = mode })
    local default_text = table.concat(selected_lines, "\n")
    default_text = string.gsub(default_text, "\n", "")
    default_text = (type(default_text) == "string") and (default_text:gsub("^%s+", ""):gsub("%s+$", "")) or ""

    if default_text == "" then
        default_text = vim.fn.expand("<cword>")
    end

    local buf = vim.api.nvim_create_buf(false, true)

    local label_len = 9 
    
    local find_line    = "Find:    " .. default_text
    local replace_line = "Replace: "
    local flags_line   = "Flags:   gcI"
    local esc_default  = vim.fn.escape(default_text, [[\/]])
    local cmd_line     = "Cmd:     %s/\\V" .. esc_default .. "//gcI"

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        find_line,
        replace_line,
        flags_line,
        cmd_line,
    })

    local ns_id = vim.api.nvim_create_namespace("sublime_replace_dialog")
    
    -- 設定高亮：前三行只高亮標籤區（0 到 label_len），第四行（Cmd）整行高亮
    local function set_highlights()
        vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
        for i = 0, 3 do
            local line_text = vim.api.nvim_buf_get_lines(buf, i, i + 1, false)[1] or ""
            local end_col = (i == 3) and #line_text or label_len
            
            vim.api.nvim_buf_set_extmark(buf, ns_id, i, 0, {
                end_col = end_col,
                hl_group = "Special",
            })
        end
    end
    set_highlights()

    local width = 65
    local height = 4
    local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 2)
    local col = math.max(0, math.floor((vim.o.columns - width) / 2))

    local opts = {
        style = "minimal",
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        border = "rounded",
        title = " Sublime Find & Replace ",
        title_pos = "center",
        footer = " g: global | c: confirm | i: ignore case ",
        footer_pos = "center",
    }

    local win = vim.api.nvim_open_win(buf, true, opts)
    vim.api.nvim_set_option_value("winhighlight", "Normal:Normal,FloatBorder:Special", { scope = "local", win = win })

    -- 預設讓游標停在第 2 行（Replace）的標籤後面
    vim.api.nvim_win_set_cursor(0, { 2, label_len })
    vim.cmd("startinsert")

    -- 即時更新 Cmd，並立即重刷整行高亮
    local function update_command_line()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local f_str = lines[1] and lines[1]:sub(label_len + 1) or ""
        local r_str = lines[2] and lines[2]:sub(label_len + 1) or ""
        local fl_str = lines[3] and lines[3]:sub(label_len + 1) or "gcI"

        local esc_f = vim.fn.escape(f_str, [[\/]])
        local new_cmd = string.format("Cmd:     %%s/\\V%s/%s/%s", esc_f, r_str, fl_str)
        
        vim.api.nvim_buf_set_lines(buf, 3, 4, false, { new_cmd })
        set_highlights() -- 確保第四行更新文字後依然整行保持藍色
    end

    -- 防護機制：鎖死 4 行，游標不能跑進標籤內
    vim.api.nvim_create_autocmd({ "CursorMovedI", "TextChangedI" }, {
        buffer = buf,
        callback = function()
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            if #lines ~= 4 then
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                    find_line, replace_line, flags_line, cmd_line
                })
                set_highlights()
            end

            update_command_line()

            local cursor = vim.api.nvim_win_get_cursor(0)
            local row_idx = cursor[1]
            local col_idx = cursor[2]
            if col_idx < label_len then
                vim.api.nvim_win_set_cursor(0, { row_idx, label_len })
            end
        end,
    })

    local function execute_replace()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local cmd_str = lines[4] and lines[4]:sub(label_len + 1) or ""

        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
        vim.cmd("stopinsert")

        if cmd_str == "" then
            vim.notify("指令不可為空！", vim.log.levels.WARN)
            return
        end

        local ok, err = pcall(vim.cmd, cmd_str)
        if not ok then
            vim.notify("取代失敗: " .. err, vim.log.levels.ERROR)
        end
    end

    local map_opts = { buffer = buf, silent = true }
    vim.keymap.set("i", "<CR>", function() vim.cmd("stopinsert"); execute_replace() end, map_opts)
    vim.keymap.set("n", "<CR>", execute_replace, map_opts)
    vim.keymap.set("n", "q", function() if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end; vim.cmd("stopinsert") end, map_opts)
    vim.keymap.set("i", "<Esc>", function() if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end; vim.cmd("stopinsert") end, map_opts)
end

-- Visual 模式綁定
vim.keymap.set("x", "<leader>sH", open_sublime_replace_dialog, { desc = "Sublime Replace visual selection" })
