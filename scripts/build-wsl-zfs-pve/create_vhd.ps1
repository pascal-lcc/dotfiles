$vhdPath = "E:\Wsl\disk\wsl-pve-new.vhdx"
$user = $env:USERNAME
$script = "create vdisk file=`"$vhdPath`" maximum=102400 type=expandable"
$script | diskpart
takeown /f $vhdPath
icacls $vhdPath /grant "${user}:F"
