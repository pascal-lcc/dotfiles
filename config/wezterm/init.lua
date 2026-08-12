local wezterm = require("wezterm")

local config = wezterm.config_builder()

config.color_scheme = "Tokyo Night"
-- 2. 字體大小
config.font_size = 10.5

-- 3. 修正剪貼簿設定 (這是 OSC 52 的關鍵)
-- 如果 set_clipboard 報錯，通常是因為在較新版本中它不需要特別宣告
-- 或者應該使用以下這行：
-- config.set_clipboard_allow_trusted_ca_without_asking = true
config.window_background_opacity = 1.0 -- 0.0 到 1.0，建議 0.9 左右
config.window_decorations = "TITLE | RESIZE"
config.tab_max_width = 20

config.colors = {
    tab_bar = {
        active_tab = {
            bg_color = "#2b2042", -- 選中時的底色
            fg_color = "#c0caf5", -- 選中時的文字顏色
        },
    },
}

-- 2. 自定義標題邏輯：只顯示最後的程式名或自定義名稱
wezterm.on("format-tab-title", function(tab, tabs, panes, config, hover, max_width)
    local title = tab.active_pane.title

    -- 如果是 Windows 的長路徑，只取最後一個檔名或程式名
    -- 例如把 "C:\WINDOWS\system32\cmd.exe - nvim" 變成 "nvim"
    if title:find(" - ") then
        title = title:gsub(".* %- ", "")
    elseif title:find("\\") then
        title = title:gsub(".*\\", "")
    end

    -- 如果處理完還是太長，強制截斷
    if #title > 15 then
        title = string.sub(title, 1, 12) .. "..."
    end

    return {
        { Text = " " .. title .. " " },
    }
end)

config.launch_menu = {
    {
        label = "Connect to pve211",
        args = { "ssh", "pascual@10.40.0.211" },
    },
    {
        label = "Connect to pve212",
        args = { "ssh", "pascual@10.40.0.212" },
    },
}

config.keys = {
    {
        key = "K",
        mods = "CTRL|SHIFT",
        -- 注意這裡：ShowLauncher 是一個函數，後面要接 ({...})
        action = wezterm.action.ShowLauncher,
    },
    { key = "v", mods = "SHIFT", action = wezterm.action.DisableDefaultAssignment },
    { key = "v", mods = "NONE", action = wezterm.action.DisableDefaultAssignment },
    { key = "h", mods = "CTRL|ALT", action = wezterm.action.ActivatePaneDirection("Left") },
    { key = "l", mods = "CTRL|ALT", action = wezterm.action.ActivatePaneDirection("Right") },
    { key = "k", mods = "CTRL|ALT", action = wezterm.action.ActivatePaneDirection("Up") },
    { key = "j", mods = "CTRL|ALT", action = wezterm.action.ActivatePaneDirection("Down") },
    -- 水平分割 (Split Horizontally) - 新視窗在右邊
    {
        key = "v",
        mods = "CTRL|ALT",
        action = wezterm.action.SplitHorizontal({ domain = "CurrentPaneDomain" }),
    },

    -- 垂直分割 (Split Vertically) - 新視窗在下面
    {
        key = "s",
        mods = "CTRL|ALT",
        action = wezterm.action.SplitVertical({ domain = "CurrentPaneDomain" }),
    },
}

return config
