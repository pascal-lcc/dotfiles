--- @sync entry
-- 1. 獨立的同步抓取函式
local get_paths = ya.sync(function()
    local path_list = {}
    -- 優先抓取選中的檔案
    for _, u in pairs(cx.active.selected) do
        local p = tostring(u):gsub("'", "''") 
        table.insert(path_list, "'" .. p .. "'")
    end
    
    -- 若無選取，則抓取目前游標所在的檔案
    if #path_list == 0 and cx.active.current.hovered then
        local p = tostring(cx.active.current.hovered.url):gsub("'", "''")
        table.insert(path_list, "'" .. p .. "'")
    end
    return path_list
end)

-- 2. 主入口
function entry()
    -- 正確呼叫 get_paths
    local path_list = get_paths()

    if #path_list == 0 then return end

    local formatted_paths = "@(" .. table.concat(path_list, ", ") .. ")"
    local ps_command = "Add-Type -AssemblyName System.Windows.Forms; [Windows.Forms.Clipboard]::SetFileDropList(" 
                       .. formatted_paths .. ")"

    -- 執行 PowerShell 指令
    Command("pwsh")
        :arg("-NoProfile")
        :arg("-Command")
        :arg(ps_command)
        :spawn()

    ya.notify({ 
        title = "系統剪貼簿", 
        content = "已複製 " .. #path_list .. " 個項目", 
        timeout = 2 
    })
end

return { entry = entry }
