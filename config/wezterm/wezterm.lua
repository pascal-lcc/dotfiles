local wezterm = require 'wezterm'
package.path = package.path .. ";" .. wezterm.config_dir .. "/?.lua;" .. wezterm.config_dir .. "/?/init.lua"
local mytool = require 'config.mytool'

local log = mytool.log
local is_editor_active = mytool.is_editor_active

wezterm.log_info("wezterm.lua new")
local config = wezterm.config_builder()

config.keys = config.keys or {}
config.key_tables = config.key_tables or {}
config.ssh_domains = config.ssh_domains or {}

local tab_history = {}

local appearance = require 'config.appearance'
local launch = require 'config.launch'
local bindkeys = require 'config.bindkeys'
local myfonts = require 'config.fonts'
local mycolor = require 'colors.custom'
local nvim = require 'events.nvim'
local uservar = require 'events.user-var'

appearance.apply_to_config(config)
bindkeys.apply_to_config(config, tab_history)
launch.apply_to_config(config)
myfonts.apply_to_config(config)
nvim.setup(config)
uservar.setup(config)


config.colors = mycolor
-- 調整行高：1.0 是預設，0.9 ~ 0.95 會比較緊湊，超過 1.0 會變更鬆
-- config.line_height = 0.95
--


wezterm.on('format-tab-title', function(tab, tabs, panes, config, hover, max_width)
    local title = tab.active_pane.title

    local title = tab.tab_title
    
    -- 2. 如果沒有手動標題 (title 為空或長度為 0)，則抓取當前執行的程式名稱
    if not title or #title == 0 then
        title = tab.active_pane.title:gsub("%.exe$", "")        
    end

    -- 3. 可以在這裡處理你想要的文字格式，例如加上編號
    local index = tab.tab_index + 1
    if tab.is_active then
        local current_tab_id = tab.tab_id
        -- 如果歷史最後一個不是現在這個，就存進去
        if tab_history[#tab_history] ~= current_tab_id then
            table.insert(tab_history, current_tab_id)
        end
        -- 限制歷史長度，避免記憶體洩漏 (保留最後 10 個即可)
        if #tab_history > 20 then table.remove(tab_history, 1) end
    end

    
    -- 回傳最終要顯示在 Tab 上的字串
    return {
        { Text = " " .. index .. ": " .. title .. " " },
    }
end)

local scoop_path = os.getenv("SCOOP") or (os.getenv("USERPROFILE") .. "\\scoop")
local scoop_shims = scoop_path .. "\\shims"


config.automatically_reload_config = true 
-- config.tab_bar_at_bottom = false
config.show_tab_index_in_tab_bar = true
config.use_fancy_tab_bar = false
config.enable_kitty_graphics = true
config.status_update_interval = 1000     -- 確保狀態會定時更新
-- config.front_end = "Software"
-- config.selection_word_boundary = " \t\n{}[];\"';, "

-- 確保 Sixel 沒有被禁用 (雖然預設是開啟，但手動補上保平安)

config.set_environment_variables = config.set_environment_variables or {}
config.set_environment_variables.PATH = scoop_shims .. ";" .. os.getenv("PATH")

local last_battery_check = 0
local cached_battery_text = ""

-- 建議改用 update-right-status，語義更清晰
wezterm.on('update-right-status', function(window, pane)
    local name = window:active_key_table()
    local date = wezterm.strftime('%H:%M:%S')

    local now = os.time()
    if now - last_battery_check > 30 then
        local battery_info = wezterm.battery_info()
        last_battery_check = now
    end

    -- 1. 修正後的 Zoom 偵測邏輯
    local zoom_text = ""
    -- 從傳入的 pane 取得它所屬的 tab
    local tab = pane:tab()
    if tab then
        -- 遍歷該 tab 裡所有的 panes，看有沒有任何一個是被縮放的
        for _, p in ipairs(tab:panes_with_info()) do
            if p.is_zoomed then
                zoom_text = " 🔍 ZOOM "
                break
            end
        end
    end

    -- 2. 處理顏色與模式文字
    local T, fg, bg
    if name then
        T = ' 模式: ' .. name .. ' | ' .. date
        fg = { Foreground = { Color = 'black' } }
        bg = { Background = { Color = 'yellow' } }
    else
        T = date
        fg = { Foreground = { Color = '#a6adc8' } }
        bg = { Background = { Color = '#1e1e2e' } }
    end

    -- 3. 處理電池資訊
    local battery_text = ""
    if battery_info and #battery_info > 0 then
        local battery = battery_info[1]
        battery_text = ' | 🔋 ' .. string.format("%.0f%%", battery.state_of_charge * 100)
    end

    -- 4. 組合最終字串
    -- local active, reason = is_editor_active(pane)

    local pane_id = tostring(pane:pane_id())
    local prog = _G.PANE_PROG and _G.PANE_PROG[pane_id]
    
    local editor = ''
    if prog == 'NVIM' then
        editor = ''
    end
    -- 判斷邏輯：
    -- 1. val 為 nil (還沒觸發過事件)
    -- 2. val == "" (Tmux 噴了空的變數回來)
    -- 3. val ~= "ON" (變數是別的東西)
    if prog == nil or prog == "" then
        prog = "nil"
    end

    local status_text = ' ' .. zoom_text .. T .. battery_text .. ' '..editor.. '|'..prog
    -- local status_text = ' ' .. zoom_text .. T .. battery_text 

    window:set_right_status(wezterm.format({
        bg, fg, 
        { Text = status_text },
    }))
end)

return config


