# 取得使用者字型資料夾
$FontFolder = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
if (!(Test-Path $FontFolder)) { New-Item -Path $FontFolder -ItemType Directory }

# 取得字型來源（假設在腳本上一層的 fonts 目錄）
$SourceDir = Join-Path $PSScriptRoot "..\fonts"

if (-not (Test-Path -Path "$SourceDir" -PathType Container)) {
    mkdir -p $SourceDir
}

Write-Host "--- Install fonts ---" -ForegroundColor Cyan

Get-ChildItem -Path "$SourceDir\*.ttf" | ForEach-Object {
    $Dest = Join-Path $FontFolder $_.Name
    if (!(Test-Path $Dest)) {
        Copy-Item $_.FullName $Dest
        # 關鍵：寫入 HKCU，這不需要 Admin
        $RegPath = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
        New-ItemProperty -Path $RegPath -Name "$($_.BaseName) (TrueType)" -Value $_.Name -PropertyType String -Force
        Write-Host "Installed: $($_.Name)"
    }
}

