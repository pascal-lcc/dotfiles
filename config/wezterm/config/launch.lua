local platform = require('utils.platform')
local wezterm = require 'wezterm'
local module = {}
local mytool = require 'config.mytool'

local log = mytool.log
local merge_lists = mytool.merge_lists

local options = {
   default_prog = {},
   launch_menu = {},
}

if platform.is_win then   
   options.default_prog = { 'pwsh.exe', '-NoLogo' }
   options.launch_menu = {      
      -- { label = 'PowerShell Desktop', args = { 'powershell.exe', '-NoExit', '-Command', 'Remove-Module PSReadLine' } },
      { label = 'WSL Ubuntu-20.0.1', args = {
	  'powershell.exe', '-NoExit', '-Command',
	  [[
$distro = "Ubuntu-20.0.1"
$vhdPath = 'D:\wsl\disk\ruten.vhdx'
$rawList = (wsl.exe --list --running | Out-String).Replace("`0", "")
if ($rawList -notmatch $distro) {
    Write-Host "--- 偵測到 WSL 未執行，開始初始化 ---" -ForegroundColor Cyan
    
    # 2. 檢查 VHDX 檔案是否存在
    if (Test-Path $vhdPath) {
        Write-Host "掛載磁碟: $vhdPath"
        wsl.exe -d $distro --mount --vhd $vhdPath --bare
    } else {
        Write-Host "錯誤: 找不到 VHDX 檔案於 $vhdPath" -ForegroundColor Red
    }
    
    # 3. 執行初始化腳本
    Write-Host "執行 init 腳本..."
    wsl.exe -d $distro -u pascual bash -c "sudo ~pascual/init/start.init"
} else {
    Write-Host "--- WSL $distro 已在運行中 ---" -ForegroundColor Green
}
wsl.exe -d $distro -u pascual --cd /home/pascual

	  ]]
      } },
      { label = 'pwsh', args = { 'pwsh.exe' } },
      { label = 'Command Prompt', args = { 'cmd' } },
   }

elseif platform.is_mac then
   options.default_prog = { '/opt/homebrew/bin/fish', '-l' }
   options.launch_menu = {
      { label = 'Bash', args = { 'bash', '-l' } },
      { label = 'Fish', args = { '/opt/homebrew/bin/fish', '-l' } },
      { label = 'Nushell', args = { '/opt/homebrew/bin/nu', '-l' } },
      { label = 'Zsh', args = { 'zsh', '-l' } },
   }
elseif platform.is_linux then
   options.default_prog = { 'fish', '-l' }
   options.launch_menu = {
      { label = 'Bash', args = { 'bash', '-l' } },
      { label = 'Fish', args = { 'fish', '-l' } },
      { label = 'Zsh', args = { 'zsh', '-l' } },
   }

end


local launch_ssh = {
   { label = 'Connect to pve211 (Simple SSH)', args = { 'ssh', 'pascual@10.40.0.211' } },
}

local ssh_domains = {   
   { name = 'pve211',    remote_address = '10.40.0.211',    username = 'pascual', multiplexing = 'None' },
   { name = 'pve212',    remote_address = '10.40.0.212',    username = 'pascual', multiplexing = 'None' },
}


-- wezterm.log_info(wezterm.to_string(options))

-- merge_lists(launch_ssh, options.launch_menu)

function module.apply_to_config(config)
   config.launch_menu = config.launch_menu or {}   
   config.ssh_domains = config.ssh_domains or {}


   -- for _, domain in ipairs(ssh_domains) do
   --     table.insert(launch_ssh, {
   --         -- 動態組合成你要的 label 格式
   --         label = string.format('SSH to %s (%s)', domain.name, domain.remote_address),
   --         -- 對應 WezTerm 的 SSH Domain 啟動方式
   --         domain = { DomainName = domain.name },
   --     })
   -- end
   merge_lists(config.ssh_domains, ssh_domains)

   for _, domain in ipairs(config.ssh_domains) do
       table.insert(launch_ssh, {
           -- 動態組合成你要的 label 格式
           label = string.format('SSH to %s (%s)', domain.name, domain.remote_address),
           -- 對應 WezTerm 的 SSH Domain 啟動方式
           domain = { DomainName = domain.name },
       })
   end   
   
   merge_lists(config.launch_menu, launch_ssh)

   config.default_prog = options.default_prog
   config.font = options.font
   -- wezterm.log_info(wezterm.to_string(config.launch_menu))
end

return module

