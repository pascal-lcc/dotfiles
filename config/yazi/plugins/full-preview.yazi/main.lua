local M = {}

-- 定義一個全域變數（在這個 lua 檔內）來存放路徑
M.last_path = ""

local function inspect(value, depth)
    depth = depth or 0
    local spacing = string.rep("  ", depth)
    if type(value) == "table" then
        local str = "{\n"
        for k, v in pairs(value) do
            str = str .. spacing .. "  [" .. tostring(k) .. "] = " .. inspect(v, depth + 1) .. ",\n"
        end
        return str .. spacing .. "}"
    elseif type(value) == "string" then
        return '"' .. value .. '"'
    else
        return tostring(value)
    end
end


function M:setup(self, opts)
    ya.notify({ title = "2026 opts", content = inspect(opts), timeout = 3 })
    -- self.open_multi = opts.open_multi
    ya.notify({ title = "2026 核心同步", content = "路徑追蹤已掛載", timeout = 3 })
end


function M:entry(self)
    ya.notify({ title = "2026 entry", content = inspect(self.args), timeout = 3 })
end

return M