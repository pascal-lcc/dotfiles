local ptool = require("lcc.tools")
local log = ptool.log('~/nvim.log')

local M = {}

-- local term_brand = os.getenv("TERM_BRAND") or os.getenv("LC_TERM_BRAND") or ""
local Env = ptool.Env


-- 純 Lua 實作 Base64 Encode (不依賴外部指令)
local function b64_encode(data)
    local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    return ((data:gsub('.', function(x) 
        local r,b='',x:byte()
        for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
        return r;
    end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if (#x < 6) then return '' end
        local c=0
        for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
        return b:sub(c+1,c+1)
    end)..({ '', '==', '=' })[#data%3+1])
end

-- 通用通訊函數
-- @param name: 變數名 (例如 "TERM_CTX")
-- @param value: 原始字串 (函數會自動幫你轉 Base64)
-- @param action: OSC 1337 的子指令，預設為 "SetUserVar"
local function send_to_term(name, value, action)
    local act = action or "SetUserVar"
    local payload = ""
    local safe_value = value or ""

    if act == "SetUserVar" then
        -- WezTerm 規範：SetUserVar=Key=Base64(Value)
        payload = string.format("SetUserVar=%s=%s", name, b64_encode(safe_value))
    elseif act == "Copy" then
        -- Copy 通常也是傳 Base64 內容
        payload = string.format("Copy=%s", b64_encode(safe_value))
    else
        -- 像是 CurrentDir 這種通常直接傳明文
        payload = string.format("%s=%s", act, safe_value)
    end

    local osc = string.format("\27]1337;%s\7", payload)

    -- 如果在 Tmux 裡，必須包一層穿透序列
    if os.getenv("TMUX") then
        osc = "\27Ptmux;\27" .. osc:gsub("\27", "\27\27") .. "\27\\"
    end

    io.stdout:write(osc)
    io.stdout:flush()
end

local function send_to_term2(name, value, action)
    local act = action or "SetUserVar"
    local payload = ""
    local safe_value = value or ""

    if act == "SetUserVar" then
        -- WezTerm 規範：SetUserVar=Key=Base64(Value)
        payload = string.format("SetUserVar=%s=%s", name, b64_encode(safe_value))
    elseif act == "Copy" then
        -- Copy 通常也是傳 Base64 內容
        payload = string.format("Copy=%s", b64_encode(safe_value))
    else
        -- 像是 CurrentDir 這種通常直接傳明文
        payload = string.format("%s=%s", act, safe_value)
    end

    local osc = string.format("\27]1337;%s\7", payload)

    io.stdout:write(osc)
    io.stdout:flush()
end

local function send_to_osc(msg, seq)
    seq = seq or "2"
    local osc = "\27]"..seq..";" .. msg .. "\7"

    -- vim.api.nvim_chan_send(1, osc)
    io.stdout:write(osc)
    io.stdout:flush()
end

local function wezterm_trigger_paste()
    -- 我們發送一個自定義的 UserVar 給 WezTerm，內容是 "PASTE"
    send_to_term("TRIGGER_ACTION", "PASTE")
    -- if os.getenv("TMUX") then
    --     osc = "\27Ptmux;\27" .. osc .. "\27\\"
    -- end
    -- io.stdout:write(osc)
end

function M.setup()
    if Env.is_wezterm then
        vim.keymap.set('i', '<C-v>', wezterm_trigger_paste, { desc = "WezTerm 遠端貼上" })
        -- 這裡可以放我們未來的高級 Yank 邏輯
    else
        -- 如果在一般環境 (如 VS Code 終端)，就回歸標準行為
        vim.keymap.set('i', '<C-v>', '<C-r>+', { desc = "標準貼上" })
    end
    vim.keymap.set('i', '<M-v>', '<C-q>', { remap = true, desc = "Original CTRL-V behavior" })

    if Env.is_ssh and not Env.is_wezterm then
    -- 這裡可以放你原本跨終端機的標準 OSC 52 Yank 配置
    end
    -- local wezterm_sync_group = vim.api.nvim_create_augroup("WezTermSync", { clear = true })
    local wezterm_sync_nvim = vim.api.nvim_create_augroup("WezTermSyncNvim", { clear = true })
    
    local STATUS_GROUP = {
        EDIT = "edit",     -- 包含 Insert, Command, Terminal
        NORMAL = "normal"  -- 包含 Normal, Visual 等
    }
    local last_sent_group = nil
    
    local send_term_status = function(status, m)
        local current_group
        if status == "" then
            send_to_term("PROG", "")
            return
        end
        m = m or vim.api.nvim_get_mode().mode
        if (m == 'i' or m == 'c' or m == 't' or m == 's' or m == 's') then
            current_group = STATUS_GROUP.EDIT
        else
            current_group = STATUS_GROUP.NORMAL
        end

        if status == "ON" or last_sent_group ~= current_group then
            last_sent_group = current_group
            if current_group == STATUS_GROUP.EDIT then
                send_to_term("PROG", "NVIM:I")
            else
                send_to_term("PROG", "NVIM:N")
            end
        end
 
    end


    vim.api.nvim_create_autocmd({"VimEnter", "VimResume"}, {
        group = wezterm_sync_nvim,
        callback = function()
            -- send_to_term("PROG", "NVIM")
            -- send_to_osc("#NVIM", "2")
        end,
    })
    --
    -- -- 2. 在註冊 autocmd 時把 group 傳進去
    vim.api.nvim_create_autocmd({ "VimSuspend", "VimLeavePre"}, {
        group = wezterm_sync_nvim,
        callback = function()
            -- send_to_term("PROG", "")
            -- send_to_osc("#", "2")
        end,
    })

    vim.api.nvim_create_autocmd("FocusGained", {
        group = wezterm_sync_nvim,
        callback = function()
            -- send_to_term("PROG", "NVIM")
            -- send_to_osc("#NVIM", "2")
        end,
    })
    
    vim.api.nvim_create_autocmd("FocusLost", {
        group = wezterm_sync_nvim,
        callback = function()
            -- send_to_term("PROG", "")
            -- send_to_osc("#lost", "2")
        end,
    })
    --
    -- vim.keymap.set('i', '<M-v>', '<C-v>', { remap = false })
end

return M
