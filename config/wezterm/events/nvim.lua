local wezterm = require('wezterm')
local mytool = require 'config.mytool'

local log = mytool.log
local logf = function(...)
    mytool.logf("d:/Scoop/log/weztern.log", ...)
end
local M = {}

M.setup = function(config)
    _G.PANE_PROG = _G.PANE_PROG or {}
    -- window:mux_window():active_pane():get_user_vars()
    wezterm.on('user-var-changed', function(window, pane, name, value)
        logf("user-var-change:"..name.." = "..value)
        -- log("user-var-change:"..name.." = "..value)
    --     -- 當接收到 TRIGGER_ACTION 且值為 "PASTE" 時
        if name == 'TRIGGER_ACTION' and value == 'PASTE' then
            window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
            -- (選配) 貼完後立刻清空變數，防止重複觸發
            -- 或是讓 Neovim 負責歸零
        end

        if name == 'pane_ctx' then
            if not _G.PASDBG then _G.PASDBG = {} end
            local pane_id = tostring(pane:pane_id())
            _G.PASDBG[pane_id] = value
        end

        if name == 'PROG' then
            local pane_id = tostring(pane:pane_id())
            _G.PANE_PROG[pane_id] = value
        end
    end)
end


return M
