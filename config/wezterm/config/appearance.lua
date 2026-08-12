local wezterm = require 'wezterm'
local gpu_adapters = require('utils.gpu_adapter')
local colors = require('colors.custom')
local mytool = require 'config.mytool'

local merge_lists = mytool.merge_lists
local merge_tables = mytool.merge_tables
local log = mytool.log


local module = {}

-- config.allow_win32_input_mode = false
local opt = {
   enable_scroll_bar = true,
   enable_kitty_keyboard = true,
   animation_fps = 60,
   max_fps = 60,   
   color_scheme = 'Tokyo Night',
   font_size = 10.5,
   window_background_opacity = 1.0,
   window_decorations = "TITLE | RESIZE",
   webgpu_preferred_adapter = gpu_adapters:pick_best(),
   webgpu_power_preference = 'HighPerformance',
   enable_tab_bar = true,
   use_ime = true,
   ime_preedit_rendering = "System",
   front_end = 'WebGpu',
   hide_tab_bar_if_only_one_tab = false,
   use_fancy_tab_bar = false,
   tab_max_width = 25,
   show_tab_index_in_tab_bar = false,
   switch_to_last_active_tab_when_closing_tab = true,
   window_padding = {
      left = 0,
      right = 0,
      top = 10,
      bottom = 7.5,
   },
   window_close_confirmation = 'NeverPrompt',
   window_frame = {
      active_titlebar_bg = '#090909',
      -- font = fonts.font,
      -- font_size = fonts.font_size,
   },
   -- inactive_pane_hsb = {
   --    saturation = 0.9,
   --    brightness = 0.65,
   -- },
   inactive_pane_hsb = {
      saturation = 1,
      brightness = 1,
   },
   background = {
      -- {
         -- source = { File = wezterm.GLOBAL.background },
         -- horizontal_align = 'Center',
      -- },
      {
         source = { Color = colors.background },
         height = '120%',
         width = '120%',
         vertical_offset = '-10%',
         horizontal_offset = '-10%',
         opacity = 0.96,
      },
   },
   colors = {
      tab_bar = {
          active_tab = {
            bg_color = '#2b2042', -- 選中時的底色
            fg_color = '#c0caf5', -- 選中時的文字顏色
          },
      },
   },
   term = 'xterm-256color',
   audible_bell = "Disabled",
   visual_bell = {
     fade_in_duration_ms = 0,
     fade_out_duration_ms = 0,
     target = 'BackgroundColor', -- 或者 'CursorColor'
   },
}


function module.apply_to_config(config)
    merge_lists(config, opt)
    config.set_environment_variables = config.set_environment_variables or {}
    if wezterm.target_triple:find("windows") then
        config.set_environment_variables = {
            ['LC_TERM_BRAND'] = 'WezTerm-Windows',
        }
    else
        config.set_environment_variables = {
            ['LC_TERM_BRAND'] = 'WezTerm-Linux',
        }
    end
end

return module
