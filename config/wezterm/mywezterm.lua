local wezterm = require('wezterm')

local act = wezterm.action

local config
local myCfg = {

}
myCfg.__index = myCfg

local act = wezterm.action
-- local keys = cfg.keys

-- keys[#keys+1]={ key = 'PageUp', mods = 'SHIFT', action = act.ScrollByPage(-1) }
-- keys[#keys+1]={ key = 'PageDown', mods = 'SHIFT', action = act.ScrollByPage(1) }

function myCfg:append(cfg)
    local keys = cfg.keys
    local mouse_bindings = cfg.mouse_bindings
    
    if config == nil then
        config = cfg
    end
    -- wezterm.log_error ('Hello zzee!', config)

    
    keys[#keys+1]={ key = 'PageUp', mods = 'SHIFT', action = act.ScrollByPage(-1) }
    keys[#keys+1]={ key = 'PageDown', mods = 'SHIFT', action = act.ScrollByPage(1) }

    keys[#keys+1]={ key = 'j', mods = 'ALT', action = act ({ScrollByLine = -1}) }
    keys[#keys+1]={ key = 'k', mods = 'ALT', action = act ({ScrollByLine = 1}) }

    keys[#keys+1]={ key = 'j', mods = 'SHIFT|ALT', action = act ({ScrollByLine = -3}) }
    keys[#keys+1]={ key = 'k', mods = 'SHIFT|ALT', action = act ({ScrollByLine = 3}) }    


    mouse_bindings[#mouse_bindings+1] = {
        event = { Down = { streak = 1, button = "Right" } },
        mods = "NONE",
        action = wezterm.action_callback(function(window, pane)
            local has_selection = window:get_selection_text_for_pane(pane) ~= ""
                if has_selection then
                    window:perform_action(act.CopyTo("ClipboardAndPrimarySelection"), pane)
                    window:perform_action(act({ PasteFrom = "Clipboard" }), pane)
                    window:perform_action(act.ClearSelection, pane)
                else
                    -- window:perform_action(act({ PasteFrom = "Clipboard" }), pane)
                end
            end),
    }

end


return myCfg