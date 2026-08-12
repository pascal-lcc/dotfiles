local wezterm = require 'wezterm'
local platform = require('utils.platform')
local mytool = require 'config.mytool'

local merge_lists = mytool.merge_lists
local act = wezterm.action
local log = mytool.log
local is_editor_active = mytool.is_editor_active

wezterm.on('debug-key', function(window, pane, key, mods)
  wezterm.log_info("KEY: " .. key .. " MODS: " .. mods)
end)

local tab_history = {}
local module = {}

if platform.is_mac then
    module.SUPER = 'SUPER'
    module.SUPER_REV = 'SUPER|CTRL'
elseif platform.is_win or platform.is_linux then
    module.SUPER = 'ALT' -- to not conflict with Windows key shortcuts
    module.SUPER_REV = 'ALT|CTRL'
end

local dynamic_ssh_file = wezterm.config_dir .. '\\.wezterm_dynamic_ssh.lua'
local _config

-- 定義一個自定義動作
local function open_tab_picker(window, pane)
  local tabs = window:mux_window():tabs()
  local choices = {}
  local current_tab_id = window:active_tab():tab_id()

  -- 先找出當前分頁，把它塞在最前面
  for i, tab in ipairs(tabs) do
    local title = tab:get_title()
    if not title or title == "" then
       -- 抓取該 Tab 中活動中的 Pane 標題
       title = tab:active_pane():get_title()
    end
    if not title or title == "" then
       title = "Tab " .. (i - 1)
    end
    
    local label = string.format("%d: %s", i - 1, title)
    if tab:tab_id() == current_tab_id then
      -- 如果是當前分頁，標註一下並放在第一筆
      table.insert(choices, 1, { id = tostring(i - 1), label = label .. " (Current)" })
    else
      table.insert(choices, { id = tostring(i - 1), label = label })
    end
  end

  window:perform_action(
    wezterm.action.InputSelector {
      title = "跳轉至分頁 (當前分頁已置頂)",
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(window, pane, id, label)
        if id then
          window:perform_action(wezterm.action.ActivateTab(tonumber(id)), pane)
        end
      end),
    },
    pane
  )
end

wezterm.on('debug-log-action', function(window, pane, msg)
    wezterm.log_info(">>> " .. (msg or "觸發了按鍵") .. " <<<")
end)
local key_tables = {
    resize_pane = {
        -- 進入模式後，按住 Shift 狂按 J 或 K 即可連發
        { key = 'J', mods = 'SHIFT', action = wezterm.action.AdjustPaneSize({ 'Down', 1 }) },
        { key = 'K', mods = 'SHIFT', action = wezterm.action.AdjustPaneSize({ 'Up', 1 }) },
        { key = 'H', mods = 'SHIFT', action = wezterm.action.AdjustPaneSize({ 'Left', 1 }) },
        { key = 'L', mods = 'SHIFT', action = wezterm.action.AdjustPaneSize({ 'Right', 1 }) },
        -- 退出模式
        { key = 'Escape', action = 'PopKeyTable' },
        { key = 'Enter', action = 'PopKeyTable' },
        { key = 'q', action = 'PopKeyTable' },
    },
}

-- 定義一個快捷函數
local function resize_and_activate(direction)
    return wezterm.action_callback(function(window, pane)
        window:perform_action(
            wezterm.action.Multiple {
                wezterm.action.AdjustPaneSize({ direction, 1 }),
                wezterm.action.ActivateKeyTable {
                    name = 'resize_pane',
                    one_shot = false,
                    timeout_milliseconds = 1000,
                    replace_current_binds = true,
                },
            },
            pane
        )
    end)
end

local keys = {
    -- 禁用 WezTerm 預設的 Unicode 選取器 (原本是 CTRL_SHIFT + 'u')
    { key = 'U', mods = 'CTRL|SHIFT', action = wezterm.action.DisableDefaultAssignment, },
     -- 注意這裡：ShowLauncher 是一個函數，後面要接 ({...})
    { key = 'K', mods = 'CTRL|SHIFT', action = wezterm.action.ShowLauncher, },
    { key = 'v', mods = 'SHIFT', action = wezterm.action.DisableDefaultAssignment },
    { key = 'v', mods = 'NONE',  action = wezterm.action.DisableDefaultAssignment },
    { key = 'h', mods = 'CTRL|ALT', action = wezterm.action.ActivatePaneDirection 'Left' },
    { key = 'l', mods = 'CTRL|ALT', action = wezterm.action.ActivatePaneDirection 'Right' },
    { key = 'k', mods = 'CTRL|ALT', action = wezterm.action.ActivatePaneDirection 'Up' },
    { key = 'j', mods = 'CTRL|ALT', action = wezterm.action.ActivatePaneDirection 'Down' },
    -- 水平分割 (Split Horizontally) - 新視窗在右邊
    { key = 'v', mods = 'LEADER', action = wezterm.action.SplitHorizontal({ domain = 'CurrentPaneDomain' }), },
    -- 垂直分割 (Split Vertically) - 新視窗在下面
    { key = 's', mods = 'LEADER', action = wezterm.action.SplitVertical({ domain = 'CurrentPaneDomain' }), },
    { key = 'M', mods = 'CTRL|SHIFT', action = wezterm.action.DisableDefaultAssignment, },  
    -- 面板移動 (Navigate Panes)
    { key = 'h', mods = 'LEADER', action = wezterm.action.ActivatePaneDirection('Left') },
    { key = 'l', mods = 'LEADER', action = wezterm.action.ActivatePaneDirection('Right') },
    { key = 'k', mods = 'LEADER', action = wezterm.action.ActivatePaneDirection('Up') },
    { key = 'j', mods = 'LEADER', action = wezterm.action.ActivatePaneDirection('Down') },
    { key = 'z', mods = 'LEADER', action = wezterm.action.TogglePaneZoomState },
    -- 這樣寫乾淨多了！
    { key = 'J', mods = 'LEADER|SHIFT', action = resize_and_activate('Down') },
    { key = 'K', mods = 'LEADER|SHIFT', action = resize_and_activate('Up') },
    { key = 'H', mods = 'LEADER|SHIFT', action = resize_and_activate('Left') },
    { key = 'L', mods = 'LEADER|SHIFT', action = resize_and_activate('Right') },
    {
      key = 'A', mods = 'LEADER|SHIFT',
          action = wezterm.action.PromptInputLine {
              description = 'Enter new name for tab',
              action = wezterm.action_callback(function(window, pane, line)
                  if line then
                      window:active_tab():set_title(line)
                  end
              end),
          },
    }, 
    -- { key = 'q', mods = 'LEADER|CTRL', action = wezterm.action.ActivateLastTab, },
    {
        key = 'q',
        mods = 'LEADER|CTRL',
        action = wezterm.action_callback(function(window, pane)
            -- 從歷史中往回找
            -- #tab_history 是當前分頁，#tab_history - 1 是上一個
            for i = #tab_history - 1, 1, -1 do
                local last_tab_id = tab_history[i]
                
                -- 核心功能：檢查這個 Tab ID 是否還存在於目前的視窗中
                local all_tabs = window:mux_window():tabs()
                local target_tab = nil
                for _, t in ipairs(all_tabs) do
                    if t:tab_id() == last_tab_id then
                        target_tab = t
                        break
                    end
                end

                if target_tab then
                    target_tab:activate()
                    -- 成功跳轉後，清理一下歷史，把剛跳過去的設為最新
                    return
                end
            end
            window:toast_notification("WezTerm", "找不到有效的前一個分頁", 1000)
        end),
    },

    -- 選擇切換tab
    -- { key = '"', mods = 'LEADER|SHIFT', action = wezterm.action.ShowLauncherArgs { flags = 'TABS|FUZZY' } },
    { key = '"', mods = 'LEADER|SHIFT', action = wezterm.action.ShowTabNavigator },
    -- { key = '"', mods = 'LEADER|SHIFT', action = wezterm.action_callback(open_tab_picker)},
    -- 範例：改成 ALT + n 切換到下一個 tab
    { key = 'n', mods = 'LEADER', action = wezterm.action.ActivateTabRelative(1), },
    { key = 'n', mods = 'LEADER|CTRL', action = wezterm.action.ActivateTabRelative(1), },
    --範例：改成 ALT + p 切換到上一個 tab
    { key = 'p', mods = 'LEADER', action = wezterm.action.ActivateTabRelative(-1), },
    { key = 'p', mods = 'LEADER|CTRL', action = wezterm.action.ActivateTabRelative(-1), },
    { key = 't', mods = 'LEADER', action = wezterm.action.SpawnTab 'CurrentPaneDomain', },
    { key = 'c', mods = 'LEADER', action = wezterm.action.SpawnCommandInNewTab {
      args = { 'pwsh.exe', '-NoLogo' }, -- 這裡填入你想執行的指令與參數
          -- cwd = '/home/user', -- 如果你想指定起始目錄也可以加這行
      }
    }, 
    { key = 'Insert', mods = 'SHIFT', action = wezterm.action.PasteFrom 'Clipboard', },
--  {
--     key = 'v',
--     mods = 'CTRL',
--     action = wezterm.action_callback(function(window, pane)
--       -- 1. 抓取變數與程序名稱
--       local vars = pane:get_user_vars()
--       local is_nvim_var = vars.IS_NVIM
--       local process_name = pane:get_foreground_process_name() or "unknown"
--       -- 2. 在 Debug Overlay 印出目前的狀態
--       -- wezterm.log_info("--- Ctrl-v Triggered ---")
--       -- wezterm.log_info("Process Name: " .. process_name)
--       -- 用 pairs 遍歷 vars，確保你沒拼錯變數名稱
--       -- for k, v in pairs(vars) do
--       --   wezterm.log_info("User Var: " .. k .. " = " .. v)
--       -- end
--       local vars = pane:get_user_vars()
--       local is_insert = vars.IS_NVIM_INSERT == '1'
--
--       -- 如果在 Insert 模式，執行貼上
--       if is_insert then
--         window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
--       else
--         -- 否則 (例如 Normal 模式)，發送原始 Ctrl-v 讓 Neovim 進入區塊選取
--         window:perform_action(wezterm.action.SendKey{key='v', mods='CTRL'}, pane)
--       end
--     end),
--   },
    { key = ']', mods = 'LEADER', action = wezterm.action.PasteFrom 'Clipboard', },
    { key = '[', mods = 'LEADER', action = wezterm.action.ActivateCopyMode , },
    { key = '[', mods = 'CTRL', action = wezterm.action_callback(function(window, pane, id, label)
        local prog = _G.PANE_PROG and _G.PANE_PROG[tostring(pane:pane_id())] or ""
        if prog == "nvim" then
            -- wezterm.log_info("Detected nvim, sending Raw CTRL-[")
            -- 在 nvim 中，我們送出一個特定的鍵盤序列
            -- 如果你開啟了 Kitty Graphics/Keyboard Protocol，這會被區分為 CTRL-[
            -- window:perform_action(wezterm.action.SendKey{ key = '[', mods = 'CTRL' }, pane)
            window:perform_action(wezterm.action.SendKey{ key = 'F13'}, pane)
            -- window:perform_action(wezterm.action.SendString("\x1b[100;5u"), pane)
        else
            -- wezterm.log_info("Not nvim, sending standard ESC")
            window:perform_action(wezterm.action.SendKey{ key = 'Escape' }, pane)
        end
        
    end) },    
    -- { key = 'x', mods = 'LEADER', action = wezterm.action.CloseCurrentTab { confirm = true } },
    { key = 'x', mods = 'LEADER', 
      action = wezterm.action.InputSelector {
        title = 'close Panel?',
        choices = {
          { label = 'yes, close', id = 'kill' },
          { label = 'no，keep', id = 'keep' },
      },
      action = wezterm.action_callback(function(window, pane, id, label)
        if id == 'kill' then
          window:perform_action(wezterm.action.CloseCurrentPane{confirm=false}, pane)
        end
      end),      
      }
    },
    { key = 'x', mods = 'LEADER|SHIFT', action = wezterm.action.CloseCurrentTab { confirm = true } },
    {
      key = 'F12', -- 按 F12 直接觸發內建 SSH
      mods = 'NONE',
      action = wezterm.action.SpawnCommandInNewTab {
        -- 關鍵：直接叫 WezTerm 去連線，不依賴選單列表
        domain = { DomainName = 'my-debian' },
      },      
    },
    {
      key = 'S',
      mods = 'LEADER|SHIFT',
      action = wezterm.action.PromptInputLine {
        description = '請輸入 user@ip:',
        action = wezterm.action_callback(function(window, pane, line)
          if line then
            local user, host = line:match("([^@]+)@(.+)")
            if not host then host = line; user = "pascual" end
 
            -- 1. 將新的 Domain 寫入臨時檔案
            log(dynamic_ssh_file)
            local f = io.open(dynamic_ssh_file, "w")
            f:write(string.format('return {{ name = "tmp-ssh", remote_address = "%s", username = "%s", multiplexing = "None" }}', host, user))
            f:close()
 
            -- 2. 叫 WezTerm 重載設定 (這會讓剛寫入的 tmp-ssh 生效)
            window:perform_action(wezterm.action.ReloadConfiguration, pane)
 
            -- 3. 等待一小段時間後執行連線 (延遲確保重載完成)
            wezterm.sleep_ms(300)
 
            window:perform_action(
              wezterm.action.SpawnCommandInNewTab { domain = { DomainName = "tmp-ssh" } },            
              pane
            )
          end
        end),
      },
    },
    -- {
    --   key = 'I',
    --   mods = 'CTRL|SHIFT',
    --   action = wezterm.action_callback(function(window, pane)
    --       local active, reason = is_editor_active(pane)
    --       wezterm.log_info(string.format(">>> 檢查結果: Active=%s, Reason=%s", tostring(active), reason))
    --   end),
    -- },
    { key = 'UpArrow', mods = 'CTRL|SHIFT', action = wezterm.action.SendString("\x1b[1;6A"), },
    { key = 'DownArrow', mods = 'CTRL|SHIFT', action = wezterm.action.SendString("\x1b[1;6B"), },
    { key = 'RightArrow', mods = 'CTRL|SHIFT', action = wezterm.action.SendString("\x1b[1;6C"), },
    { key = 'LeftArrow', mods = 'CTRL|SHIFT', action = wezterm.action.SendString("\x1b[1;6D"), },
    { key = 'm', mods = 'CTRL|SHIFT', action = wezterm.action.SendString("\x1b[1;6M"), },
    -- { key = 'u', mods = 'CTRL|SHIFT', action = wezterm.action.SendString("\x1b[1;6U") }
    { key = 'u', mods = 'CTRL|SHIFT', action = wezterm.action.SendString("\u{F0001}") }
    -- { key = 'u', mods = 'CTRL|SHIFT', action = wezterm.action.SendString("\x1b[1;6P") }
    -- { key = 'u', mods = 'CTRL|SHIFT', action = wezterm.action.SendString("\x1b[24;6~") },
    -- { key = 'u', mods = 'CTRL|SHIFT', action = wezterm.action.SendString("UUU") },
}

function module.apply_to_config(config, history)
    tab_history = history
    config.leader = { key = 'q', mods = 'CTRL', timeout_milliseconds = 1000 }
    config.keys = config.keys or {}
    config.key_tables = config.key_tables or {}
    config.ssh_domains = config.ssh_domains or {}
    config.disable_default_key_bindings = false
    -- config.window_close_confirmation = 'AlwaysPrompt'
    merge_lists(config.key_tables, key_tables)
    merge_lists(config.keys, keys)

    local success, dynamic_domains = pcall(dofile, dynamic_ssh_file)

    if not success or not dynamic_domains then dynamic_domains = {
      { name = "tmp-ssh", remote_address = "127.0.0.1",  multiplexing = "None" }
    } end

    for _, dom in ipairs(dynamic_domains) do
        table.insert(config.ssh_domains, dom)
    end

end

return module
