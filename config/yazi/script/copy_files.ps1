# copy_files.ps1
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Clipboard]::SetFileDropList($Args)

# 順便把通知訊息也寫在這裡，絕對不會噴錯
$count = $Args.Count
& ya pub notification --kind info --title "系統剪貼簿" --content "已複製 $count 個檔案"
