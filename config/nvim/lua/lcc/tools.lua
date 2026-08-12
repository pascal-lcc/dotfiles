local M = {}

local debug_buf = nil
local debug_win = nil

local function log_to_file(msg, path)
    -- 1. 取得 Neovim 標準資料路徑 (通常是 ~/.local/share/nvim/ 或 Scoop 的 persist 內部)
    -- 0.12 的性能在處理檔案路徑上更優化
    local log_path = (path and vim.fn.expand(path)) or vim.fn.stdpath("data") .. "/custom_debug.log"

    -- 2. 格式化訊息：加上時間戳記，方便追蹤
    local time = os.date("%Y-%m-%d %H:%M:%S")
    local formatted_msg = string.format("[%s] %s", time, tostring(msg))

    -- 3. 以 Append 模式寫入檔案
    -- 'a' 代表附加，不會蓋掉舊內容
    local f = io.open(log_path, "a")
    if f then
        f:write(formatted_msg .. "\n")
        f:close()
    else
        -- 如果檔案打不開，至少在 cmdline 噴個警告
        vim.notify("Failed to write to log file: " .. log_path, vim.log.levels.ERROR)
    end
end

local function log_to_buffer(msg)
    -- 如果 buffer 不存在或被關了，就建一個
    if not debug_buf or not vim.api.nvim_buf_is_valid(debug_buf) then
        debug_buf = vim.api.nvim_create_buf(false, true) -- scratch buffer
    end

    -- 取得內容並轉成 table (以換行分割)
    local lines = vim.split(tostring(msg), "\n")

    -- 在 buffer 末尾寫入內容
    vim.api.nvim_buf_set_lines(debug_buf, -1, -1, false, lines)

    -- 如果視窗沒開，就開一個橫切視窗在下方
    if not debug_win or not vim.api.nvim_win_is_valid(debug_win) then
        vim.cmd("botright 10split") -- 在最下方開 10 行高度的視窗
        debug_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(debug_win, debug_buf)
        -- 回到原本的視窗，不干擾操作
        vim.cmd("wincmd p")
    end

    -- 自動捲動到底部
    local last_line = vim.api.nvim_buf_line_count(debug_buf)
    vim.api.nvim_win_set_cursor(debug_win, { last_line, 0 })
end

-- 你的 dump_table 稍作修改以便調用
local function dump_table(obj, indent)
    indent = indent or ""
    if type(obj) == "table" then
        local s = "{\n"
        for k, v in pairs(obj) do
            s = s .. indent .. "  [" .. tostring(k) .. "] = " .. dump_table(v, indent .. "  ") .. ",\n"
        end
        return s .. indent .. "}"
    else
        return tostring(obj)
    end
end
local function dump2(obj, path)
    path = path or "~/nvim.log"
    log_to_file(dump_table(obj), path)
end

local function dump(obj)
    log_to_buffer(dump_table(obj))
end

local function log(path)
    return function(msg)
        dump2(msg, path)
    end
end

M.merge_lists = function(t1, t2)
    t1 = t1 or {}
    if not t2 then
        return
    end

    if type(t2) == "table" and #t2 > 0 then
        for _, v in ipairs(t2) do
            table.insert(t1, v)
        end
    else
        for k, v in pairs(t2) do
            t1[k] = v
        end
    end
end

M.merge_tables = function(target, source)
    if not source then
        return
    end
    for k, v in pairs(source) do
        target[k] = v
    end
end

M.benchmark = function(name, func, count)
    count = count or 1 -- 預設跑 1 次，但建議測算時給 1000 次以上
    local start = vim.uv.hrtime()

    for _ = 1, count do
        func()
    end

    local ended = vim.uv.hrtime()
    local total_ms = (ended - start) / 1e6
    local avg_ms = total_ms / count

    return string.format("[%s] 總耗時: %.3f ms | 平均: %.6f ms (跑了 %d 次)", name, total_ms, avg_ms, count)
end

M.dump_table = dump_table
M.dump = dump
M.dump2 = dump2
M.log = log
M.Env = {}
M.dbg = log("~/nvim.log")
M.LeftRelease_handlers = {}
return M
