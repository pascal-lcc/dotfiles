local wezterm = require 'wezterm'

local tools = {}

tools.merge_lists = function (t1, t2)
   t1 = t1 or {}
   if not t2 then return end

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

tools.merge_tables = function (target, source)
    if not source then return end
    for k, v in pairs(source) do
        target[k] = v
    end
end

local log = function(...)
   local args = table.pack(...)
   local msgs = {}
   for i = 1, args.n do
      table.insert(msgs, wezterm.to_string(args[i]))
   end
   wezterm.log_info(table.concat(msgs, " | ")) -- 用分隔線區隔多個參數
end

local logf = function(path, ...)
    local args = table.pack(...)
    local msgs = {}
    for i = 1, args.n do
        table.insert(msgs, wezterm.to_string(args[i]))
    end

    local log_path
    if path and path ~= "" then
        log_path = path
    else
        log_path = wezterm.config_dir .. '/wezterm_debug.log'
    end

    -- 3. 寫入檔案 ("a" 代表 append 追加模式)
    local f = io.open(log_path, "a+b")
    if f then
        local time = os.date("%Y-%m-%d %H:%M:%S")
        local content = table.concat(msgs, " | ")
        local formatted_msg = string.format("[%s] %s", time, content)
        f:write(formatted_msg .. "\n")
        f:flush()
        f:close()
    else
        -- 如果檔案打不開，就在 WezTerm 的 Debug Overlay 噴報錯
        wezterm.log_error("無法寫入 Log 檔案到: " .. log_path)
    end
end

local function is_editor_active(pane)
    local pane_id = tostring(pane:pane_id())
    local val = _G.EDITOR_STATUS and _G.EDITOR_STATUS[pane_id]
    
    -- 判斷邏輯：
    -- 1. val 為 nil (還沒觸發過事件)
    -- 2. val == "" (Tmux 噴了空的變數回來)
    -- 3. val ~= "ON" (變數是別的東西)
    if val == nil or val == "" then
        return false, "EMPTY_OR_NIL"
    elseif val == "ON" then
        return true, "NVIM"
    else
        return false, "OTHER: " .. tostring(val)
    end
end

local function get_current_status(pane)
    -- 1. 先查 _G 全域表
    local id = tostring(pane:pane_id())
    local status = _G.EDITOR_STATUS and _G.EDITOR_STATUS[id]
    
    -- 2. 如果全域表是 nil，直接去問 Pane 本身 (WezTerm 會快取 UserVars)
    if status == nil then
        return pane:get_user_vars().IS_NVIM == "ON"
    end
    
    return status == "ON"
end

tools.log = log
tools.logf = logf
tools.is_editor_active = is_editor_active
tools.get_current_status = get_current_status

return tools;
