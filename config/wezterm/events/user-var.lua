local wezterm = require('wezterm')

local log = wezterm.log_info
local M = {}

local var_chaned_listen = {}

M.setup = function(config)
     -- window:mux_window():active_pane():get_user_vars()
     wezterm.on('user-var-changed', function(window, pane, name, value)
        if name == 'SYNC_TERM' then
            if wezterm.target_triple:find("windows") then
                pane:send_text("WezTerm-windows ") 
            else
                pane:send_text("WezTerm ") 
            end
        end
        if name == 'SYNC_REQ' then
            local req_id = value
            
            -- 取得你想傳回去的變數 (例如 TERM_BRAND)
            local vars = pane:get_user_vars()
            local brand = vars.TERM_BRAND or "WezTerm"
            
            -- 精準注入：echo 到對應的 ID 檔案裡
            -- 我們加上 \n 確保指令執行
            -- local inject_cmd = string.format("echo '%s' > /tmp/wez_vars_%s; printf '\r\27[2K'\n", brand, req_id)
            -- local inject_cmd = string.format("\r \27[K echo '%s' > /tmp/wez_vars_%s; printf '\r\27[K'\n", brand, req_id)
            -- local inject_cmd = string.format("echo export TERM_BRAND=WezTerm")
            local inject_cmd = string.format("export TERM_BRAND=WezTerm\n")
            
            wezterm.log_info("正在為 ID " .. req_id .. " 注入資料")
            pane:send_text(inject_cmd)
        end

        -- 當接收到 TRIGGER_ACTION 且值為 "PASTE" 時
        -- if name == 'TRIGGER_ACTION' and value == 'PASTE' then
        --     -- 執行貼上動作
        --     window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
        --     -- (選配) 貼完後立刻清空變數，防止重複觸發
        --     -- 或是讓 Neovim 負責歸零
        -- end
    end)

    -- window:mux_window():active_pane():get_user_vars()
    -- wezterm.log_info("--- user_vars", window:mux_window():active_pane():get_user_vars())

    -- 1. 處理新視窗
    -- wezterm.on('gui-startup', function(spawn_info)
    --     local _, pane, _ = wezterm.mux.spawn_window(spawn_info or {})
    --     inject_vars(pane)
    -- end)
end

return M
