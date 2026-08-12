local ptool = require("lcc.tools")
local M = {}
local has_onemore 
local exclusive = false

local dump_table = ptool.dump_table
local dump = ptool.dump
local dump2 = ptool.dump2
local log = ptool.log('~/nvim.log')
local benchmark = ptool.benchmark
_G.log = log

local function smart_undo_or_suspend()
    local is_win = vim.fn.has('win32') == 1
    local is_gui = vim.fn.has('gui_running') == 1
    -- 偵測是否在 tmux 內 (檢查環境變數)
    local is_tmux = vim.fn.exists('$TMUX') == 1

    -- 如果是 Windows 或 GUI 模式，我們通常想要 Windows 習慣：Undo
    -- 但如果你在 Linux 的 Terminal 裡 (且不是 GUI)，且在 tmux 內，則維持 Suspend
    if (is_win or is_gui) and not is_tmux then
        -- 執行 Undo
        -- 使用 cmd('undo') 比較乾淨，不會受模式影響
        vim.cmd('undo')
    else
        -- 否則執行原生的 C-z (掛起行程)
        -- \16 是 CTRL-Z 的 ASCII 碼
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-z>", true, false, true), 'n', true)
    end
end

local ivstat = { act = false, mode = 'n', cur = {row = -1, col = -1}, stat = 0, row = -1, col = -1}
local pas_group = vim.api.nvim_create_augroup("pasModeTracker", { clear = true })

local mode_str = function(mode) 
    if mode:find("[sS\19]") then
        return 's'
    elseif mode:find("[vV\22]") then
        return 'v'
    end
    return mode
end

local ModeEnable = true

vim.api.nvim_create_autocmd("ModeChanged", {
    group = pas_group, -- 關鍵：指定群組
    -- pattern = "[vV\x16sS\x13]:n",
    -- pattern = string.format("[ivV%ssS%s]:n", 
    --             vim.api.nvim_replace_termcodes("<C-v>", true, false, true),  
    --             vim.api.nvim_replace_termcodes("<C-s>", true, false, true)),
    callback = function()
        if ModeEnable == false then return end
        -- local old_mode = vim.v.event.old_mode
        local new_mode = vim.v.event.new_mode
        if 'n' == new_mode then
            ivstat.act = false
        end
        ivstat.mode = new_mode
    end,
})

local function is_iselect()
    if ivstat.act == true and 's' == mode_str(ivstat.mode) then
        return 2
    else
        return 0
    end
end

local function row_substr(row, s_start, s_end)
    local curpos = vim.fn.getcurpos()
    if row == nil then
        row = curpos[2] - 1
    end
    if s_start == nil then
        s_start = curpos[3] - 1
    else
        s_start = math.max(0, s_start) 
    end

    if s_end == nil then
        s_end = vim.fn.col({row + 1, "$"}) - 1
    else
        s_end = math.max(0, math.min(s_end, vim.fn.col({row + 1, "$"}) - 1))
    end

    if s_start >= s_end then return "" end

    -- 3. 安全擷取：現在進 pcall 是為了防範其他不可預期錯誤 (例如 Buffer 無效)
    local ok, res = pcall(vim.api.nvim_buf_get_text, 0, row, s_start, row, s_end, {})

    if not ok or not res[1] then return "" end
    return res[1]
end

local function iselect_start()    
    ivstat.act = true
    ivstat.stat = 1
    ivstat.cursor = vim.api.nvim_win_get_cursor(0) 
    ivstat.row = ivstat.cursor[1]
    ivstat.col = ivstat.cursor[2]
    ivstat.vcol = vim.fn.virtcol({ivstat.row, ivstat.col}) + 1 
    ivstat.colEnd = (vim.fn.col("$") == vim.fn.col("."))


    -- local xstart = math.max(0, ivstat.col - 4)
    -- local xline = row_substr(ivstat.row - 1, xstart, ivstat.col + 5)
    -- local pos_table = vim.str_utf_pos(xline)
    -- local befwidth, aftwidth = 0, 0
    --
    -- ivstat.befwidth = 0.5
    -- ivstat.aftwidth = 1000000
    --
    -- local xpos = ivstat.col - xstart
    --
    -- for i, pos in ipairs(pos_table) do
    --     if pos > xpos then
    --         if i > 1 then
    --             ivstat.befwidth = pos - pos_table[i - 1]
    --             ivstat.vB = ivstat.vcol - math.min(2, pos - pos_table[i - 1])  
    --         end
    --         if pos_table[i + 1] ~= nil then
    --             ivstat.aftwidth = pos_table[i + 1] - pos
    --             ivstat.vA = ivstat.vcol + math.min(2, pos_table[i + 1] - pos)
    --         end            
    --         break
    --     end
    -- end
end

local function feedkeys(keys, mode)
    mode = mode or 'n'
    -- local old_eventignore = vim.opt.eventignore:get()
    -- vim.opt.eventignore = "all"
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), mode, true)
    -- vim.opt.eventignore = old_eventignore
end

local function move_and_insert(target_row, target_col, inputs)
    -- 1. 強制回歸 Normal Mode (確保移動指令在正確的模式執行)
    -- 使用 stopinsert 比直接 input 更能確保狀態重設
    vim.cmd('noautocmd stopinsert')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true), "n", false)

    inputs = inputs or 'i'
    vim.schedule(function() 
        -- 2. 設定游標位置 {行 (1-indexed), 列 (0-indexed)}
        -- 這裡加個 pcall 是為了防止座標越界導致腳本崩潰
        pcall(vim.api.nvim_win_set_cursor, 0, { target_row, target_col })
        if isend == true then
            vim.api.nvim_input(inputs)
        else
            vim.api.nvim_input(inputs)
        end
    end)
end

local function get_char_end(row, col)
    if row == nil or col == nil then
        local cursor = vim.api.nvim_win_get_cursor(0)
        row = cursor[1] - 1
        col = cursor[2]
    end

    -- 抓取局部內容（抓 6 個 Byte 確保涵蓋如 Emoji 等長字元）
    local ok, text = pcall(vim.api.nvim_buf_get_text, 0, row, col, row, col + 6, {})
    if not ok or #text[1] == 0 then return col, true end

    local bytes = text[1]
    local pos_table = vim.str_utf_pos(bytes) -- 得到的 table 如 {1, 4, 7}
    local byte_len
    if #pos_table >= 2 then
        byte_len = pos_table[2] - 1
    else
        byte_len = #bytes
    end

    return col + byte_len, #pos_table == 1
end

local function unshift_move(dir)
    if is_iselect() == 2 then
        local row, col
        cpos = vim.fn.getpos(".")

        if dir == "<Right>" or dir == "<Down>" then
            if ivstat.row == cpos[2] then
                col = math.max(cpos[3], ivstat.col)                
                row = ivstat.row
            elseif ivstat.row > cpos[2] then
                row = ivstat.row
                col = ivstat.col 
            else
                row = cpos[2]
                col = cpos[3]
            end
            local fcol, isend = get_char_end(row - 1, col - 1)
            -- move_and_insert(row, fcol, isend)
            if dir == "<Down>" then 
                move_and_insert(row, fcol, (isend == true) and "a<Down>" or "i<Down>" )
            else
                move_and_insert(row, fcol, (isend == true) and 'a' or 'i' )
            end
            -- elseif dir == '<Left>' or dir == "<Up>" then
        else
            if ivstat.row == cpos[2] then
                row =  ivstat.row
                col = math.min(cpos[3] - 1, ivstat.col)                
            elseif ivstat.row < cpos[2] then
                row = ivstat.row
                col = ivstat.col 
            else
                row = cpos[2]
                col = cpos[3] - 1
            end
            local fcol, isend = get_char_end(row - 1, col - 1)

            if dir == "<Left>" then
                move_and_insert(row, math.max(0, fcol), "i")
            else
                move_and_insert(row, math.max(0, fcol), "i<Up>")
            end
        end

        return
    end
    feedkeys(dir, 'nx')
end

local function modeEnable()
    vim.schedule(function() 
        ModeEnable = true
    end)
end

local function set_select()
    vim.schedule(function() 
        ivstat.act = true
        ivstat.mode = 's'
    end)
end

local function shift_move(dir)
    -- local is_insert = (mode == 'i')
    -- local is_selecting = mode:find("[vVsS\19\22]") ~= nil
    local iselect = is_iselect()  
    local mode = mode_str(vim.api.nvim_get_mode().mode)
    local is_visual = mode:find("[vs]") ~= nil
    local smode = mode_str(ivstat.mode)
    -- local curpos = vim.fn.getcurpos() 
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1]
    local col = cursor[2]
    local vcol = vim.fn.virtcol({row, col}) + 1

    if 'i' == mode then
        iselect_start({row = row , col = col,})
        iselect = 1
    end

    local function set_vpos(row, col)
        vim.schedule(function() 
            vim.api.nvim_win_set_cursor(0, {row, math.max(0, col)})
            feedkeys("<C-o>o", "nx")
            vim.api.nvim_win_set_cursor(0, {row, math.max(0, col)})
        end)
    end

    local function set_startInsert(st)
        ivstat.act = false
        local key = 'i'
        if st == true then
            key = 'a'
        end
        vim.cmd('noautocmd stopinsert') 
        feedkeys("<Esc>"..key)
        -- vim.cmd('startinsert') 
    end

    local function get_current_char_byte_len(row, col)
        if row == nil or col == nil then
            local cursor = vim.api.nvim_win_get_cursor(0)
            row, col = cursor[1] - 1, cursor[2]
        end

        local line_len = vim.fn.col({row + 1, "$"}) - 1
        -- 2. 邊界守衛：如果已經在行尾或空行，直接回傳 0，不進 pcall
        if col >= line_len then return 0 end

        -- 3. 安全擷取：現在進 pcall 是為了防範其他不可預期錯誤 (例如 Buffer 無效)
        local end_col = math.min(col + 6, line_len)
        local ok, res = pcall(vim.api.nvim_buf_get_text, 0, row, col, row, end_col, {})

        if not ok or not res[1] or #res[1] == 0 then return 0 end

        -- 4. 運算第一個字元的 Byte 長度
        local pos = vim.str_utf_pos(res[1])
        return (#pos >= 2) and (pos[2] - pos[1]) or #res[1]
    end

    if 2 == iselect and smode =='s' then
        -- feedkeys("<C-o>"..dir)

        if ivstat.row == row then
            -- log({
            --     len = benchmark("Line", 
            --         function() 
            --             vim.fn.strpart(vim.api.nvim_get_current_line(), col, 1, true)
            --         end, 10000),
            --     len2 = benchmark("Byte", function() 
            --               get_current_char_byte_len(row - 1, col)
            --            end, 10000) 
            --
            -- })
            -- if dir == '<Right>' and ivstat.col == col + #vim.fn.strpart(vim.api.nvim_get_current_line(), col, 1, true) then
            if dir == '<Right>' and ivstat.col == col + get_current_char_byte_len(row - 1, col) then
                -- set_vpos(row, col + 1)
                -- move_and_insert(row, col + 1)
                set_startInsert(true)
                -- set_vpos(row, col + 1)
                return
            end

            -- if ivstat.col == col and dir == '<Left>' then
            if dir == '<Left>' then
                if exclusive == false and ivstat.col == col then
                    return set_startInsert()
                end

                if exclusive == true and ivstat.col == col - 1 then                    
                                -- if vim.fn.col(".") >= vim.fn.col("$") then return end
                    local key = 'i'

                    if vim.fn.col(".") >= vim.fn.col("$") then
                        key = 'a'
                    end

                    ivstat.act = false                    
                    vim.cmd('noautocmd stopinsert') 
                    return feedkeys("<Esc><Left>"..key)
                end
            end

            if dir == '<Up>' and col >= ivstat.col then                
                -- vim.api.nvim_win_set_cursor(0, {row, math.max(0, ivstat.col - 1)})
                if exclusive == false then
                    return feedkeys("<C-g>o<Left>o<Up><Right><C-g>", "t")
                else
                    return feedkeys("<C-o><Up>", "t")
                end
                -- return vim.schedule(function() 
                    -- vim.api.nvim_win_set_cursor(0, {row - 1, byte_col})
                -- end)
            end
            if dir == '<Down>' and col < ivstat.col then
                -- feedkeys("<C-g>o<Right>o<Down><Left><C-g>", "t")
                if exclusive == false then
                    return feedkeys("<C-g>o<Right>o<Down><Left><C-g>", "t")
                else
                    return feedkeys("<C-o><Down>", "t")
                end
                -- vim.api.nvim_win_set_cursor(0, {row, ivstat.col})
                -- feedkeys("<C-o>o")
                -- return vim.schedule(function() 
                --     vim.api.nvim_win_set_cursor(0, {row + 1, math.max(0, col - 1)})
                -- end)
            end
        elseif ivstat.row == row - 1 and dir == '<Up>'  then
            -- local saved_view = vim.fn.winsaveview()
            -- vim.cmd(string.format("keepjumps normal! ll"))
            -- local next_info = vim.fn.getcurpos() -- 這就是下一行的資訊
            -- vim.fn.winrestview(saved_view) -- 無痕還原
            -- local curpos = vim.fn.getcurpos('.')
            -- local xline = row_substr(curpos[2] - 1, curpos[3] - 1, curpos[3] + 3)
            
            local xline = row_substr(row - 1, col, col + 1 + 7)
            local pos_table = vim.str_utf_pos(xline)
            local curV = 0
            local nextV = 0
            -- local colEnd = ( vim.fn.col({row, "$"}) - 1 <= (col + 1))
            local colEnd =  vim.fn.col({row, "$"}) <= col + 2

            if #pos_table > 2 then
                curV = vcol + math.min(2, pos_table[2] - pos_table[1])
                nextV = curV + math.min(2, pos_table[3] - pos_table[2])
            elseif #pos_table > 1 then
                curV = vcol + math.min(2, pos_table[2] - pos_table[1])
                nextV = curV + math.min(2, #xline - pos_table[1])
            elseif #pos_table == 1 then
                curV = vcol + math.min(2, #xline)
                nextV = curV + 1
            end

            local appendI = nil
            if ivstat.colEnd == true then
                appendI = true
            end

            if ivstat.vcol == curV or (ivstat.vcol <= 2 and col == 0) 
                or (ivstat.vcol > curV and ivstat.vcol < nextV)  
                or (ivstat.colEnd == true and (ivstat.vcol <= curV or colEnd == true))
                or (colEnd == true and ivstat.vcol >= curV)
                then
                vim.api.nvim_win_set_cursor(0, {ivstat.row, ivstat.col})
                return  set_startInsert(appendI)
            end

            if exclusive == true then
                return feedkeys("<C-o>k") 
            end

            if ivstat.vcol < curV then
                vim.api.nvim_win_set_cursor(0, {ivstat.row, ivstat.col})
                local byte_col = vim.fn.virtcol2col(0, ivstat.row, curV - 1)
                vim.schedule(function()                    
                    vim.api.nvim_win_set_cursor(0, {ivstat.row, byte_col - 1})
                end)
                -- return feedkeys("<C-o>k")                
            else                
                local byte_col = vim.fn.virtcol2col(0, ivstat.row, curV)
                vim.api.nvim_win_set_cursor(0, {ivstat.row, ivstat.col - 1})
                feedkeys("<C-o>o")
                vim.schedule(function() 
                    vim.api.nvim_win_set_cursor(0, {ivstat.row, byte_col - 1})
                end)
                return
                -- return feedkeys("<C-g>kloho<C-g>") 
            end
            -- feedkeys("<C-o>o")
            -- vim.schedule(function() 
                -- vim.api.nvim_win_set_cursor(0, {ivstat.row, col})
            -- end)
            -- return
        elseif ivstat.row == row + 1 and dir == '<Down>'  then
            local xline = row_substr(row - 1, col, col + 1 + 7)
            local pos_table = vim.str_utf_pos(xline)
            local curV = 0
            local nextV = 0
            -- local colEnd = ( vim.fn.col({row, "$"}) - 1 <= curpos[3])
            local colEnd =  vim.fn.col({row, "$"}) <= col + 2

            if #pos_table > 2 then
                curV = vcol + math.min(2, pos_table[2] - pos_table[1])
                nextV = curV + math.min(2, pos_table[3] - pos_table[2])
            elseif #pos_table > 1 then
                curV = vcol + math.min(2, pos_table[2] - pos_table[1])
                nextV = curV + math.min(2, #xline - pos_table[1])
            elseif #pos_table == 1 then
                curV = vcol + math.min(2, #xline)
                nextV = curV + 1
            end

            if ivstat.vcol == vcol or (ivstat.vcol <= 2 and col == 0)
                or ( vcol <= ivstat.vcol and curV > ivstat.vcol)
                or ( ivstat.colEnd == true and ivstat.vcol <= vcol)
                then

                local appendI = nil
                if ivstat.colEnd == true then
                    appendI = true
                end

                vim.api.nvim_win_set_cursor(0, {ivstat.row, ivstat.col})
                return set_startInsert(appendI)
            end

            if exclusive == true then
                return feedkeys("<C-o>j") 
            end

            if ivstat.vcol > vcol then
                return feedkeys("<C-o>j")
            else                
                local byte_col = vim.fn.virtcol2col(0, ivstat.row, vcol - 1)
                vim.api.nvim_win_set_cursor(0, {ivstat.row, ivstat.col})
                feedkeys("<C-o>o")
                vim.schedule(function() 
                    vim.api.nvim_win_set_cursor(0, {ivstat.row, byte_col - 1})
                end)
                return
            end
        end
        -- feedkeys("<C-o>"..dir, "nx")
        feedkeys("<C-o>"..dir)
        return
    end

    if 'i' == mode then 
        local keys

        if '<Left>' == dir then
            if 0 == col then return 
                -- return set_startInsert()
            end
            vim.cmd('noautocmd stopinsert') 
            -- pcall(vim.api.nvim_win_set_cursor, 0, { ivstat..row, ivstat.col})
            ModeEnable = false
            ivstat.mode = 's'
            if exclusive == false then
                keys = "v<C-g>"
            else
                keys = "vlo<C-g>"
            end
        elseif "<Right>" == dir then
            if vim.fn.col(".") >= vim.fn.col("$") then return end
            vim.cmd('noautocmd stopinsert') 
            -- pcall(vim.api.nvim_win_set_cursor, 0, { ivstat.row, ivstat.col + 1})
            ModeEnable = false
            ivstat.mode = 's'
            local offkeys = '' 
            if exclusive == true then
                offkeys = 'l'
            end
            if col == 0 then
                keys = "v"..offkeys.."<C-g>"
            else
                keys = "lv"..offkeys.."<C-g>"
            end 
        elseif "<Down>" == dir then
           -- if vim.fn.col(".") > vim.fn.col("$") - 1 then return end
           if vim.fn.col(".") >= vim.fn.col("$") then
                if vim.fn.col(".") == vim.fn.col("$") then
                    ModeEnable = false
                    ivstat.mode = 's'
                    -- vim.cmd([[stopinsert]]) -- 先退出 Insert 模式
                    vim.cmd('noautocmd stopinsert')
                    vim.cmd('noautocmd normal! v')
                    -- feedkeys("<Right><Down><C-g>", "t")
                    feedkeys("<Right><Down><Left><C-g>", "t")
                    modeEnable()
                    return 
                end
                return
            end
            vim.cmd('noautocmd stopinsert') 
            -- pcall(vim.api.nvim_win_set_cursor, 0, { ivstat.row, ivstat.col + 1})
            ModeEnable = false
            ivstat.mode = 's'            
            if col == 0 then
                keys = "v<Down><C-g>"
            else
                if exclusive == true then
                    keys = "lv<Down><C-g>"
                else
                    keys = "lv<Down><Left><C-g>"
                end
            end
            feedkeys(keys, "t")
            return modeEnable()
        elseif '<Up>' == dir then
            vim.cmd('noautocmd stopinsert') 
            -- pcall(vim.api.nvim_win_set_cursor, 0, { ivstat.row, ivstat.col})
            ModeEnable = false
            ivstat.mode = 's'
            if col == 0 then
                keys = "v<Up><C-g>"
            else
                -- keys = "v<Up><C-g><Right>"
                keys = "v<Right><C-g><Up>"
                if exclusive == true then
                    keys = "v<Right><Up>o<Right>o<C-g>"
                end
            end
            -- feedkeys(keys, "n")
            -- modeEnable()
        end
        -- feedkeys(keys, "t")
        feedkeys(keys, "n")
        modeEnable()
        return
    end

    if not is_visual then
        vim.cmd('noautocmd normal! v') 
    end
    feedkeys(dir)
    if iselect > 0 then
        feedkeys("<C-g>")
    end
end


local function smart_home_end(key, select_mode)
    local mode = mode_str(vim.api.nvim_get_mode().mode)
    -- local is_visual = mode:find("[vsVS\19\22]") ~= nil
    local iselect = is_iselect()  
    local smode = mode_str(ivstat.mode)
    local is_visual = mode:find("[vs]") ~= nil
    local start_pos 
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))

    if select_mode and 'i' == mode then
        iselect_start({row = row , col = col})
        iselect = 1
    end

    -- 如果沒按 Shift 但在選取中，先 Esc 退回 Normal
    if not select_mode and 2 == iselect then
        ivstat.act = false
        feedkeys("<Esc>")
        mode = 'i'
        is_visual = false
        iselect = 3
    end

    local target_col
    local first_nonblank
    local endOffset = (exclusive == false) and 1 or 0

    if key == 'Home' then
        first_nonblank = (row_substr(nil, 0, 50):find('%S') or 1) - 1
        if iselect > 0 and row == ivstat.row then
            col = math.min(ivstat.col, col) 
        end
        target_col = (col > first_nonblank) and first_nonblank or 0
    else
        local s_start = 0
        local lend = vim.fn.col("$") 
        if lend > 300 then
            s_start = lend - 50
        end

        local sline = row_substr(nil, s_start, lend + 1)
        local _, last_nonblank = sline:find(".*%S")       

        -- local _, last_nonblank = line:find(".*%S")
        if last_nonblank then
            last_nonblank = last_nonblank + s_start
        else
            last_nonblank = s_start
        end
        -- last_nonblank = last_nonblank or 0
        local line_len = s_start + #sline
        local zcol = col

        if iselect > 0 and row == ivstat.row then            
            col = math.max(ivstat.col, col) 
        end

        local is_at_text_end = false
        if col + 1 > last_nonblank then
            is_at_text_end = true
        elseif col + 1 == last_nonblank then
            if iselect ~=1 and zcol >= col then
                is_at_text_end = true
            end
        end
        if row == ivstat.row and ivstat.col > line_len then
            target_col = ivstat.col
        else
            target_col = (not is_at_text_end) and last_nonblank or line_len
        end
    end 

    local dir = ('Home' == key) and 'Left' or 'Right'
    local onCG = false

    -- visual 模式下的起始點追蹤
    -- 2. 執行動作
    if select_mode then
        -- local keys = vim.api.nvim_replace_termcodes( string.format("<Esc>%d|v%d|<C-g>", col, target_col), true, false, true)
        local CTRL_G = vim.api.nvim_replace_termcodes("<C-g>", true, false, true)
        local safe_col = math.min(target_col, vim.fn.col("$") - 1)

        if 'i' == mode then vim.cmd('noautocmd stopinsert') end
        if not is_visual then vim.cmd('noautocmd normal! v') end
        if row ~= ivstat.row then
            if row > ivstat.row then
                if 'Home' == key then
                    target_col = math.max( 0, target_col - endOffset)
                end
            else

            end
        elseif iselect > 0  and target_col >= 0 then
            onCG = true
            
            vim.schedule(function()
                if 's' == smode then
                    feedkeys("<C-g>", "nx")
                end
                if 'Home' == key then                       
                    vim.api.nvim_win_set_cursor(0, {row, math.max(0, ivstat.col - endOffset)})
                else
                    vim.api.nvim_win_set_cursor(0, {row, math.max(0, ivstat.col)})
                end
                feedkeys("o", "nx")
            end) 
        end

        if 'End' == key then
            target_col = math.max(0, target_col - endOffset)
            if target_col == 0 and vim.fn.col({row, "$"}) == 2 then
                target_col = 1
            end
        end 

        vim.schedule(function()
            vim.api.nvim_win_set_cursor(0, {row, target_col})
            if onCG  and iselect > 0 then
                -- if col > target_col then return feedkeys("l<C-g>", "nx") end
                if target_col == 0 and ivstat.col == 0 then                    
                   return feedkeys("<Esc>i", "t")                    
                end
                return feedkeys("<C-g>", "nx")
            end
            -- vim.cmd('normal! ' .. CTRL_G)
        end)
    elseif is_visual then
        -- 擴展現有的 Visual 選取
        if 'End' == key then
            target_col = math.max(0, target_col - endOffset)
        end
        -- log({ f = "useV", target_col = target_col})
        vim.api.nvim_win_set_cursor(0, { row, target_col })
    else
        -- 純移動 (Normal 或 Insert)        
        if 'End' == key and 'i' ~= mode then target_col = math.max(0, target_col - endOffset) end
        vim.api.nvim_win_set_cursor(0, { row, target_col })
        -- 如果原本是 Insert 模式，移動完後要跳回去
        if iselect > 0 then
            -- vim.cmd("startinsert!")
            vim.cmd("noautocmd startinsert")
        end
    end
end

-- 定義一個輔助函數：縮排並保持游標不動
local function smart_indent(command)
    local view = vim.fn.winsaveview()
    vim.cmd('normal! ' .. command)
    vim.fn.winrestview(view)
end

local function visual_shift(direction)
    local sw = vim.fn.shiftwidth()
    local start_pos_raw = vim.fn.getpos("v")
    local start_col = start_pos_raw[3]
    
    if start_col == 1 then
        -- 模式 A：整行模式維持原樣
        if direction == 'right' then vim.cmd('normal! >gv') else vim.cmd('normal! <gv') end
    else
        -- 模式 B：平移模式
        
        -- 1. 先紀錄移動前的螢幕列位置 (Virtual Column)
        local start_vcol = vim.fn.virtcol("v")
        local end_vcol = vim.fn.virtcol(".")
        
        -- 2. 執行縮排 (含左移防縮水檢查)
        if direction == 'left' then
            local first = math.min(vim.fn.line("v"), vim.fn.line("."))
            local last = math.max(vim.fn.line("v"), vim.fn.line("."))
            for i = first, last do
                if vim.fn.indent(i) == 0 then return end
            end
            vim.cmd('normal! <gv')
        else
            vim.cmd('normal! >gv')
        end

        -- 3. 計算目標虛擬列
        local move = (direction == 'right') and sw or -sw
        local target_start_vcol = math.max(1, start_vcol + move)
        local target_end_vcol = math.max(1, end_vcol + move)

        -- 4. 重新強制設定選取區邊界 (使用 | 指令精確對齊虛擬列)
        -- 先處理「非游標」端
        vim.cmd('normal! o')
        vim.cmd('normal! ' .. target_start_vcol .. '|')
        
        -- 再處理「游標」端
        vim.cmd('normal! o')
        vim.cmd('normal! ' .. target_end_vcol .. '|')
    end
end


function M.setup()
    local map = vim.keymap.set
    vim.opt.selection = "exclusive"
    exclusive = (vim.go.selection == "exclusive")
    -- vim.opt.virtualedit = "onemore"
    vim.opt.virtualedit = "block"
    
    local ve = vim.opt.virtualedit:get()
    has_onemore = vim.tbl_contains(ve, "onemore")
    -- vim.opt.selectmode = "mouse"

        -- 1. 撤銷與重做 (Undo / Redo)
    local saved_selection = nil
    local ns_id = vim.api.nvim_create_namespace("VirtualVisual")
    ---------------------------------------------------------------------------
    -- Sublime: C-u (Undo), C-S-u (Redo)
    map('i', '<C-u>', '<C-o>u', { desc = 'Undo' })
    map('i', '<C-r>', '<C-o><C-r>', { desc = 'Redo' })
    -- map('i', '<C-S-u>', '<Esc><C-r>i', { desc = 'Redo' })
    -- map('i', '<A-[>1;6U', '<C-S-u>', { remap = true, silent = true })

    ---------------------------------------------------------------------------
    -- 2. 縮排控制 (Indent / Unindent)
    ---------------------------------------------------------------------------
    -- Sublime: C-[ (Unindent), C-] (Indent)
    -- 改用 Alt + [ / ] 來縮排，這樣不會撞到 Esc
    map('i', '<M-[>', '<C-o><<', { desc = 'Unindent' })
    map('i', '<M-]>', '<Esc>>>gi', { desc = 'Indent' })
    -- 針對 WezTerm 傳過來的 <S-F13> (也就是你的 C-[)
-- 插入模式：縮排
    map('i', '<S-F3>', '<C-d>', { noremap = true })
    map('i', '<C-]>', '<C-t>', { noremap = true })
    map('n', '<S-F3>', 'i<C-d><Esc>l', { noremap = true, desc = "Sublime-style Unindent" })
    map('n', '<C-]>', 'i<C-t><Esc>l', { noremap = true, desc = "Sublime-style Indent" })


    map('v', '<S-F3>', function() visual_shift('left') end, { noremap = true })
    map('v', '<C-]>', function() visual_shift('right') end, { noremap = true })
    -- 3. 註解功能 (Toggle Comment)
    ---------------------------------------------------------------------------
    -- 注意：終端機中 C-/ 經常被識別為 <C-_>
    map('n', '<C-_>', 'gcc', { remap = true, desc = 'Toggle Comment' })
    map('v', '<C-_>', 'gcgv', { remap = true, desc = 'Toggle Comment' })
    map('i', '<C-_>', '<C-o>gcc', { remap = true, desc = 'Toggle Comment' })
    -- map({'i', 'n'}, '<C-S-/>', '<Esc>gbci', { desc = 'Toggle Block Comment' })

    ---------------------------------------------------------------------------
    -- 4. 行移動 (Move Line Up/Down)
    ---------------------------------------------------------------------------
    map('i', '<C-S-Up>', '<cmd>m .-2<cr>', { desc = 'Move Line Up' })
    map('i', '<C-S-Down>', '<cmd>m .+1<cr>', { desc = 'Move Line Down' })

    -- Normal 模式下：移動整行
    map('n', '<C-S-Up>', '<cmd>m .-2<cr>', { desc = 'Move Line Up' })
    map('n', '<C-S-Down>', '<cmd>m .+1<cr>', { desc = 'Move Line Down' })

    -- Visual 模式下：移動選取區塊 (這個超級好用！)
    -- map('v', '<C-S-Up>', ":m '<-2<cr>gv=gv", { desc = 'Move Selection Up' })
    -- map('v', '<C-S-Down>', ":m '>+1<cr>gv=gv", { desc = 'Move Selection Down' })
    map('v', '<C-S-Up>', ":m '<-2<cr>gv", { desc = 'Move Selection Up' })
    map('v', '<C-S-Down>', ":m '>+1<cr>gv", { desc = 'Move Selection Down' })
    ---------------------------------------------------------------------------
    -- 5. 擴展選取 (Expand Selection)
    ---------------------------------------------------------------------------
    -- Ctrl + Shift + M: 選取括號內容 (Brackets)
    -- 邏輯：跳到最近括號並選取內部
        -- 1. 根據你的實測結果，直接映射這個變形序列
    -- 注意：這裡的 <M-[> 在 Lua 映射字串中可以寫成 <A-[>
    map({ 'n', 'i', 'v' }, '<A-[>1;6M', '<C-S-m>', { remap = true, silent = true })

    -- 用 execute 確保 Esc (\e) 被正確解析
    -- 注意：這裡必須用 nvim_set_keymap 來處理這種原始字串
    vim.keymap.set('i', '<C-S-F1>', function()
        log("ZZZZZF1")
    end,{ nowait = true, silent = true }) 

    vim.keymap.set('i', '\u{F0001}', function()
        log("GOT IT!")
    end)

-- vim.on_key(function(key)
--     local hex = ""
--     for i = 1, #key do
--         hex = hex .. string.format("%02X ", string.byte(key, i))
--     end
--     log("Raw input: " .. hex)
-- end)
    -- 3. 定義你的功能
    map('i', '<C-S-m>', '<C-o>viB<C-g>', { remap = true})
    map('n', '<C-S-m>', 'viB')
    -- map('i', '<C-S-m>', '<Esc>viB<C-g>', { desc = 'Expand selection to Brackets' })

    -- Ctrl + Shift + Space: 選取作用域 (Scope)
    -- 這裡使用 treesitter 的增量選取功能 (如果有的話)，否則用預設段落選取
    map('i', '<C-S-Space>', '<Esc>vap<C-g>', { desc = 'Expand selection to Scope' })
-- 這是 0.12 官方推薦的手法，把 gb 綁定到內建的 block 註解
-- -- Normal Mode: 映射 gbc 為執行 block 註解 (使用內建 expr 映射)
-- -- Normal Mode: 註解目前行
    map('n', 'gbc', 'gc', { remap = true, desc = 'Comment line (block)' })

    -- Visual Mode: 註解選取區塊 (x mode 就是你按 v 選取後)
    map('x', 'gb', 'gc', { remap = true, desc = 'Comment selection (block)' })
    map('s', 'gb', '<C-o>gc', { remap = true, desc = 'Comment selection (block)' })
    map('s', 'gc', '<C-o>gc', { remap = true, desc = 'Comment selection (block)' })
    -- map('s', 'gc', '<cmd>gc<cr>i', { remap = true, desc = 'Comment selection (block)' })

    map({ 'i', 'n', 'v' }, '<Home>', function() smart_home_end('Home', false) end, { silent = true })
    map({ 'i', 'n', 'v' }, '<End>',  function() smart_home_end('End',  false) end, { silent = true })
    -- 選取跳轉
    map({ 'i', 'n', 'v' }, '<S-Home>', function() smart_home_end('Home', true) end, { silent = true })
    map({ 'i', 'n', 'v' }, '<S-End>',  function() smart_home_end('End',  true) end, { silent = true })

    map({ 'i', 'n', 'v' }, '<S-Left>',  function() shift_move("<Left>") end, { silent = true })
    map({ 'i', 'n', 'v' }, '<S-Right>', function() shift_move("<Right>") end, { silent = true })
    map({ 'i', 'n', 'v' }, '<S-Up>',    function() shift_move("<Up>") end, { silent = true })
    map({ 'i', 'n', 'v' }, '<S-Down>',  function() shift_move("<Down>") end, { silent = true })

    map('s', '<Left>',  function() unshift_move("<Left>") end, { silent = true })
    map('s', '<Right>',  function() unshift_move("<Right>") end, { silent = true })
    map('s', '<Up>',  function() unshift_move("<Up>") end, { silent = true })
    map('s', '<Down>',  function() unshift_move("<Down>") end, { silent = true })

    map('i', '<C-Up>', '<C-o><C-y>', { desc = 'Scroll Up' })
    map('i', '<C-Down>', '<C-o><C-e>', { desc = 'Scroll Down' })
    -- 如果你希望 Normal Mode 也有一樣的 Sublime 體驗
    map('n', '<C-Up>', '<C-y>')
    map('n', '<C-Down>', '<C-e>')

    map('i', '<M-Left>', '<S-Left>')
    map('i', '<M-Right>', '<S-Right>')
    map('i', '<M-S-Left>', '<Esc>vB<C-g>')
    map('i', '<M-S-Right>', '<Esc>vw<C-g>')
    
    -- 儲存與選取單字
    map('i', '<C-s>', '<C-o>:w<CR>')
    map('n', '<C-s>', ':w<CR>')
    -- map('i', '<C-d>', '<Esc>viw<C-g>')
    --
    if has_onemore then
        map('n', 'x', function()
            local col = vim.fn.col('.')
            local line_len = #vim.api.nvim_get_current_line()

            -- 執行原本的 x
            vim.cmd('normal! x')

            -- 如果刪除後 col 沒變（代表原本在行尾），且現在位置超過了新行長
            if col > #vim.api.nvim_get_current_line() and #vim.api.nvim_get_current_line() > 0 then
                vim.cmd('normal! h')
            end
        end, { desc = 'Fix x behavior with virtualedit' })
    end

-- 1. Ctrl + c (Copy): 在 Select Mode 下複製到系統剪貼簿
    -- "+y 代表系統剪貼簿。y 完後自動跳回 Insert 模式
    map('s', '<C-c>', '"+y<Esc>a', { desc = 'Sublime: Copy to clipboard' })
    
    local function clear_selection()
        if saved_selection then 
            vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
            saved_selection = nil
        end
    end

    map('s', '<Esc>', function()
        if 2 == is_iselect() then
            move_and_insert(ivstat.row, ivstat.col)
        else
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
        end
        clear_selection()
    end)

    map({'x', 'n', 'i'}, '<Esc>', function()
        -- map('n', '<Esc>', '<cmd>nohlsearch<CR>', { desc = "按 Esc 取消搜尋高亮" })
        vim.cmd.nohlsearch()
        clear_selection()
        -- vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
        return "<Esc>"
    end, { expr = true, replace_keycodes = true })

    -- 2. Ctrl + v (Paste): 在 Insert 或 Select 模式下貼上
    -- Insert 模式下直接貼上系統剪貼簿內容
    -- map('i', '<C-v>', '<C-r><C-p>+', { desc = 'Sublime: Paste from clipboard' })

-- Select 模式下按 Ctrl+v 會「蓋掉」選取的字
-- map('s', '<C-v>', '"+p', { desc = 'Sublime: Paste over selection' })
    -- 目前最笨可用的
    -- vim.keymap.set('i', '<C-v>', function()
    --     local content = vim.fn.getreg('"') 
    --     vim.api.nvim_put(vim.split(content, "\n"), "c", true, true)
    -- end)

    -- map({ 'n', 'i', 'v' }, '<C-z>', smart_undo_or_suspend, { desc = 'Undo or Suspend based on environment' })
    map('i', '<C-z>', '<C-o>u', { desc = 'Undo or Suspend based on environment' })

    -- 3. Ctrl + x (Cut): 在 Select Mode 下剪下
    -- map('s', '<C-x>', '<C-o>"+d', { desc = 'Sublime: Cut to clipboard' })
    -- 4. 解決 Ctrl-v 被佔用的問題 (Visual Block)
    -- 我們可以把原本的 Visual Block 改到 <C-q> (這是 Windows 版 Vim 的習慣)
    -- 或者改到 <C-S-v> (如果你的終端機支援)
    -- map('n', '<C-q>', '<C-v>', { desc = 'Original Visual Block Mode' })
    -- Insert 模式下：移動整行 (比照 Sublime)

    -- Insert 模式下用 Alt + hjkl 移動游標
    map('i', '<M-h>', '<Left>', { desc = 'Move Left' })
    map('i', '<M-j>', '<Down>', { desc = 'Move Down' })
    map('i', '<M-k>', '<Up>', { desc = 'Move Up' })
    map('i', '<M-l>', '<Right>', { desc = 'Move Right' })
    -- Select Mode 下的 Ctrl-x (剪下)
    -- map('s', '<C-x>', function()
    --     local vpos = vim.fn.getpos('v')
    --     local cpos = vim.fn.getpos('.')
    --     -- 強制指定 type 為 'v'，避免 getregion 不認識 's'
    --     local text = vim.fn.getregion(vpos, cpos, { type = 'v' })
    --     -- 將 table 轉為字串並存入剪貼簿
    --     vim.fn.setreg('+', table.concat(text, "\n"))
    --     -- <C-g> 切換回 visual 再按 c 刪除並進入 Insert
    --     -- return "<C-g>c" 
    --     return "<C-g>c" 
    -- end, { expr = true })

    map('x', '<C-x>', 'x')
    map('s', '<C-x>', '<C-o>xi')

    -- 直接刪除並進入 Insert 模式
    -- map('s', '<Del>', '<C-o>di', { remap = true })
    local function deleteVisual()
        local vpos = vim.fn.getpos('v')
        local cpos = vim.fn.getpos('.')
        local is_at_end = false
        -- 找最下面那行是不是有包最後一字最結尾
        if vpos[2] > cpos[2] then
            is_at_end = (vim.fn.virtcol('v') >= vim.fn.virtcol({vpos[2], '$'}) - 1) 
        else
            is_at_end = (vim.fn.virtcol('.') >= vim.fn.virtcol({cpos[2], '$'}) - 1) 
        end

        local insertMode = (is_at_end == true and 'a') or 'i' 
        -- local keys = vim.api.nvim_replace_termcodes("<C-g>\"_da", true, false, true)
        local keys = vim.api.nvim_replace_termcodes("<C-g>\"_d"..insertMode, true, false, true)
        -- vim.api.nvim_feedkeys(keys, 'nx', false)
        vim.api.nvim_feedkeys(keys, 'n', false)
    end

    map('s', '<Del>', deleteVisual, { noremap = true, silent = true })

    --     vim.cmd([[normal! ^G"_d]])
    --     -- return '' 
    -- end, { remap = false, silent = true })
    -- end, { remap = true, expr = true })

    map('s', '<BS>', 'deleteVisual', { remap = false })
    -- map('s', '<C-v>', '<C-o>pa', { remap = true })
    map('s', '<C-v>', '<C-o>Pa' )
    
    -- 复制高亮提示
    vim.api.nvim_create_autocmd("TextYankPost", {
        desc = "highlight copying text",
        group = vim.api.nvim_create_augroup("highlight-yank", { clear = true }),
        callback = function()
            vim.highlight.on_yank({ timeout = 155, priority = 250 })
        end,
    })

    vim.keymap.set('s', '<C-c>', function()
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-g>y", true, false, true), "n", false)
        vim.defer_fn(function()
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("gv<C-g>", true, false, true), "n", false)
            iselect_start()
        end, 150)

    end, { desc = "終極解法：字元長度回推高亮法" })

    vim.keymap.set('x', '<C-c>', function()
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("y", true, false, true), "n", false)
        vim.defer_fn(function()
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("gv", true, false, true), "n", false)
        end, 150)
    end, { desc = "終極解法：字元長度回推高亮法" })
    -- map('s', '<C-c>', function()
    --     local vpos = vim.fn.getpos('v')
    --     local cpos = vim.fn.getpos('.')
    --
    --     -- 抓取內容 (強制用 'v' 避免 E475)
    --     local text = vim.fn.getregion(vpos, cpos, { type = 'v' })
    --     local content = table.concat(text, "\n")
    --     -- 存入剪貼簿
    --     vim.fn.setreg('+', content)
    --     vim.fn.setreg('"', content)
    --     -- 關鍵：回傳空字串或什麼都不回傳，讓 Vim 停留在目前的 Select Mode
    --     return ""
    -- end, { expr = true, desc = "Copy and stay in Select Mode" })
    
    map('n', '<leader>w', ':w<CR>', { 
        remap = false, 
        silent = true, 
        desc = "儲存當前檔案並保持安靜" 
    })

    local mouseI = false
-- vim.keymap.set('i', '<LeftMouse>', function()
--     mouseI = true
--     return [[<LeftMouse>]]
-- end, {expr = true,  silent = true })

    vim.keymap.set({'n','v', 'i'}, '<LeftMouse>', function()
        if vim.api.nvim_get_mode().mode:find('i') then
            mouseI = true
        else
            mouseI = false
        end
        return [[<LeftMouse>]]
    end, {expr = true,  silent = true })

    vim.keymap.set('i', '<2-LeftMouse>', function()
        vim.cmd("stopinsert")
        set_select()
        return [[<2-LeftMouse><C-g>]]
    end, {expr = true,  silent = true })

    vim.keymap.set( 's', '<LeftMouse>', function()    
        mouseI = true
        vim.cmd("startinsert")
        return [[<LeftMouse>]]
    end, {expr = true,  silent = true })

    vim.keymap.set('x', '<LeftRelease>', function()
        if mouseI == true then
            mouseI = false        
            vim.cmd("stopinsert")
            set_select()
            return [[<LeftRelease><C-g>]]
        end
        mouseI = false
        return [[<LeftRelease>]]
    end, { expr = true, silent = true, remap = false })





-- 模擬「釘住」選取區
local function freeze_selection(dir)
    local mode = vim.fn.mode()
    if not mode:find("[svV]") then return end
    -- if mode ~= 'v' and mode ~= 'V' and mode ~= 's' then return end

    -- 記錄位置 (1-indexed)
    local v_pos = vim.fn.getpos("v")
    local cur_pos = vim.fn.getpos(".")
    local end_num = 0
    if dir == 'u' then
        end_num = -1
    end
    
    saved_selection = { start_p = v_pos, end_p = cur_pos, mode = mode }

    -- 加上 Extmark 高亮 (0-indexed)
    vim.api.nvim_buf_set_extmark(0, ns_id, v_pos[2]-1, v_pos[3]-1, {
        end_row = cur_pos[2]-1,
        end_col = cur_pos[3] + end_num,
        hl_group = "Visual", -- 使用原本的選取高亮色
    })

    -- 退出 Visual 模式，讓游標自由滾動
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
end

-- 恢復選取區
local function thaw_selection()
    if not saved_selection then return end
    
    -- 1. 清除高亮
    vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)

    
    -- 2. 取得要還原的座標
    local sp = saved_selection.start_p
    local ep = saved_selection.end_p

    log({
        sp = sp,
        ep = ep,
    })

    if true then return end

    -- 檢查座標是否存在且合法 (防止 E474)
    if not sp or not ep or type(sp) ~= "table" or type(ep) ~= "table" then
        saved_selection = nil
        return
    end

    -- 3. 強制切換回 Normal Mode
    if vim.api.nvim_get_mode().mode ~= 'n' then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    end

    -- 4. 使用 schedule 確保在模式切換完成後執行
    vim.schedule(function()
        -- 核心修正：明確傳入座標 List
        -- pos 格式為 {bufnum, lnum, col, off}
        vim.fn.setpos("v", sp)
        vim.fn.setpos(".", ep)

        -- 恢復選取
        -- 如果你是從 Select Mode 來的，這裡要用 gv 或是額外處理
        local mode_cmd = saved_selection.mode == 's' and "gv" or "gv"
        
        -- 用 pcall 包起來，防止在極端情況下（如行被刪除）噴錯
        local ok, err = pcall(vim.cmd, "normal! " .. mode_cmd)
        if not ok then
            print("還原選取失敗: " .. err)
        end

        saved_selection = nil
    end)
end

vim.keymap.set('n', '<Leader>v', thaw_selection, { desc = "恢復選取並跳回原處" })
-- 映射到你捲動的快捷鍵上 (範例)
-- vim.keymap.set('v', '<C-d>', function()
--     -- 這裡可以加入判斷：如果快撞到邊緣才 freeze
--     freeze_selection('d')
--     -- 執行捲動
--     vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-d>", true, false, true), "n", false)
-- end)

vim.keymap.set('v', '<PageUp>', function()
    -- 這裡可以加入判斷：如果快撞到邊緣才 freeze
    freeze_selection('u')
    -- 執行捲動
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<PageUp>", true, false, true), "n", false)
end)

vim.keymap.set('v', '<PageDown>', function()
    freeze_selection('u')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<PageDown>", true, false, true), "n", false)
end)

-- vim.keymap.set('v', '<C-u>', function()
--     -- 這裡可以加入判斷：如果快撞到邊緣才 freeze
--     freeze_selection('u')
--     -- 執行捲動
--     vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-u>", true, false, true), "n", false)
-- end)
_G.test = thaw_selection

-- vim.pack.add({
--     {src = 'https://github.com/folke/tokyonight.nvim.git'},
-- })

-- vim.cmd("colorscheme tokyonight")
-- 如果想要 night 版本（極深藍黑底，最像現代 Sublime）
-- vim.cmd("colorscheme tokyonight-night")

-- 如果想要 storm 版本（帶有一點風暴藍灰底，稍微柔和）
-- vim.cmd("colorscheme tokyonight-storm")

-- 如果想要 moon 版本（介於兩者之間）
-- vim.cmd("colorscheme tokyonight-moon")

-- vim.pack.add({
	-- { src = "https://github.com/morhetz/gruvbox" }, -- 主题
	-- { src = "https://github.com/nvim-treesitter/nvim-treesitter" }, -- 语法高亮和折叠
-- })
-- vim.g.gruvbox_contrast_dark = 'hard' -- 讓底色變極黑，這點最像 Sublime
-- vim.cmd("colorscheme gruvbox")

--
end

return M

