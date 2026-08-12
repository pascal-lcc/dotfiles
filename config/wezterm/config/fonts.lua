local wezterm = require('wezterm')
local platform = require('utils.platform')
local mytool = require 'config.mytool'

local merge_lists = mytool.merge_lists
local log = mytool.log

local module = {}

local font_family = 'JetBrainsMono Nerd Font'


local function my_font_fallback(base_font_name, base_weight)
    return wezterm.font_with_fallback({
        { family = base_font_name, weight = base_weight },
        { family = 'Sarasa Term TC Nerd Font', weight = base_weight }, -- 更紗黑體優先，確保 1:2 對齊
        { family = 'HanaMinA' },                             -- 罕用字擴充
        { family = 'HanaMinB' },
        -- 'Microsoft JhengHei' 建議拿掉，因為它不是等寬，會導致 Yazi 介面歪掉
    })
end

local fonts = {
    font = my_font_fallback('JetBrainsMono Nerd Font', 'Regular'),
    font_rules = {
        {
            intensity = "Bold",
    	    -- italic = false,
    	    font = my_font_fallback('JetBrainsMono Nerd Font', 'Bold'),
        },
        {
            intensity = "Bold",
            italic = true,
            font = wezterm.font("JetBrains Mono", { weight = "Bold", stretch = "Normal", style = "Italic" }),
        },
    },
    font_size = (platform.is_mac and 12.0 or 12.0) ,
    -- freetype_load_target = 'Normal', ---@type 'Normal'|'Light'|'Mono'|'HorizontalLcd'
    -- freetype_render_target = 'Normal', ---@type 'Normal'|'Light'|'Mono'|'HorizontalLcd'
}

function module.apply_to_config(config)
    merge_lists(config, fonts)
	--    config.font_rules = {
	-- {
	-- 	intensity = "Bold",
	-- 	italic = false,
	-- 	font = wezterm.font("JetBrains Mono", { weight = "Bold", stretch = "Normal", style = "Normal" }),
	-- },
	-- {
	-- 	intensity = "Bold",
	-- 	italic = true,
	-- 	font = wezterm.font("JetBrains Mono", { weight = "Bold", stretch = "Normal", style = "Italic" }),
	-- },
	--    }
end

return module
