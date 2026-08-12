-- require("full-preview"):setup()

-- 在 init.lua 裡
-- 我們定義一個全域的狀態轉發器

-- local function inspect(value, depth)
--     depth = depth or 0
--     local spacing = string.rep("  ", depth)
--     if type(value) == "table" then
--         local str = "{\n"
--         for k, v in pairs(value) do
--             str = str .. spacing .. "  [" .. tostring(k) .. "] = " .. inspect(v, depth + 1) .. ",\n"
--         end
--         return str .. spacing .. "}"
--     elseif type(value) == "string" then
--         return '"' .. value .. '"'
--     else
--         return tostring(value)
--     end
-- end

function Status:name()
    local h = cx.active.current.hovered
    if not h then
        return ui.Span("")
    end
    local linked = ""
    if h.link_to ~= nil then
        linked = " -> " .. tostring(h.link_to)
    end

    return ui.Span(" " .. h.name .. linked)
end

Status:children_add(function()
    local h = cx.active.current.hovered
    if h == nil or ya.target_family() ~= "unix" then
        return ui.Line({})
    end

    return ui.Line({
        ui.Span(ya.user_name(h.cha.uid) or tostring(h.cha.uid)):fg("#6495ED"),
        ui.Span(":"):fg("#87CEFA"),
        ui.Span(ya.group_name(h.cha.gid) or tostring(h.cha.gid)):fg("#6495ED"),
        ui.Span(" "),
    })
end, 500, Status.RIGHT)

Header:children_add(function()
    if ya.target_family() ~= "unix" then
        return ui.Line({})
    end
    return ui.Span(ya.user_name() .. "@" .. ya.host_name() .. ":"):fg("#87CEFA")
end, 500, Header.LEFT)

require("full-border"):setup({
    -- Available values: ui.Border.PLAIN, ui.Border.ROUNDED
    type = ui.Border.ROUNDED,
})
-- DuckDB plugin configuration
-- require("duckdb"):setup()