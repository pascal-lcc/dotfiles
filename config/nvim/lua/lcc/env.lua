local ptool = require("lcc.tools")

local path = vim.api.nvim_buf_get_name(0)

-- 1. 使用 Neovim 內建的 SHA256 (回傳字串)
local hash_str = vim.fn.sha256(path)

local Env = {
    -- 1. 判斷 WezTerm (透過環境變數)
    is_wezterm = (os.getenv("TERM_BRAND") or os.getenv("LC_TERM_BRAND") or ""):lower():find("wezterm") ~= nil,
    
    -- 2. 判斷 SSH (透過連線變數)
    is_ssh = os.getenv("SSH_CONNECTION") ~= nil or os.getenv("SSH_CLIENT") ~= nil,
    
    -- 3. 判斷 WSL (採用老司機推薦的精準路徑)
    is_wsl = (function()
        -- 優先檢查 WSLInterop 檔案
        local f = io.open("/proc/sys/fs/binfmt_misc/WSLInterop", "r")
        if f then 
            f:close() 
            return true 
        end
        
        -- 次要檢查 /proc/version 是否含有特定字串
        local fv = io.open("/proc/version", "r")
        if fv then
            local version = fv:read("*a"):lower()
            fv:close()
            if version:find("microsoft") or version:find("wsl") then
                return true
            end
        end
        return false
    end)()

}

ptool.merge_lists(ptool.Env, Env)
