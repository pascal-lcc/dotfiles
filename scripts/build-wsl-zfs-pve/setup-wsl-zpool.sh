#!/usr/bin/env bash
set -euo pipefail

echo "=================================================="
echo "    PVE VHDX & ZFS Pool 全自動化建立與掛載工具"
echo "=================================================="

# 0. 互動式詢問 ZFS Pool 名稱與存在性處理
DEFAULT_POOL="tank"
read -rp "請輸入要建立的 ZFS Pool 名稱 [預設 ${DEFAULT_POOL}]: " INPUT_POOL_NAME
POOL_NAME="${INPUT_POOL_NAME:-${DEFAULT_POOL}}"

echo "[+] 確認使用的 ZFS Pool 名稱: ${POOL_NAME}"

# 檢查該 ZFS Pool 是否已經存在
if sudo zpool list "${POOL_NAME}" &>/dev/null; then
    echo ""
    echo "[!] 警告：偵測到 ZFS Pool '${POOL_NAME}' 已經存在！"
    
    # 智慧檢查：是否有 PVE 虛擬機/容器正在使用此 Pool (變數名稱已修正)
    ACTIVE_GUESTS=$(sudo zfs list -H -o name 2>/dev/null | grep "^${POOL_NAME}/" || true)
    
    if [ -n "${ACTIVE_GUESTS}" ] || sudo zfs list "${POOL_NAME}" &>/dev/null; then
        echo "[!] 注意：此 Pool 目前可能包含活躍的 Dataset 或受 PVE 管理的資料集。"
        echo "[*] 建議先至 Proxmox VE 介面確認並移除關聯的儲存區（Datacenter -> Storage），或手動卸載。"
    fi

    read -rp "是否要強制銷毀舊的 '${POOL_NAME}' 並重新建立？(y/N): " CONFIRM_DESTROY
    if [[ "${CONFIRM_DESTROY}" =~ ^[Yy]$ ]]; then
        echo "[*] 正在嘗試卸載並銷毀舊的 ZFS Pool '${POOL_NAME}'..."
        
        # 嘗試強制卸載與匯出
        sudo zpool export -f "${POOL_NAME}" 2>/dev/null || true
        
        # 強制銷毀
        if sudo zpool destroy -f "${POOL_NAME}"; then
            echo "[+] 舊的 ZFS Pool '${POOL_NAME}' 已成功銷毀，繼續建立流程..."
        else
            echo "[!] 錯誤：無法自動銷毀 '${POOL_NAME}'。可能仍有行程佔用中。"
            echo "[!] 請手動執行以下指令處理後再重試："
            echo "    sudo zfs unmount ${POOL_NAME}"
            echo "    sudo zpool destroy -f ${POOL_NAME}"
            exit 1
        fi
    else
        echo "[*] 使用者取消操作，結束程式。"
        exit 0
    fi
fi

# 1. 互動式輸入容量，並進行智慧防呆與自動補 "G"
read -rp "請輸入要建立的 VHD 容量 (例如 100 或 100G) [預設 100G]: " RAW_SIZE
RAW_SIZE=${RAW_SIZE:-100G}

if [[ "${RAW_SIZE}" =~ ^[0-9]+$ ]]; then
    DISK_SIZE="${RAW_SIZE}G"
else
    DISK_SIZE="${RAW_SIZE}"
fi

NUM_VAL=$(echo "${DISK_SIZE}" | tr -d 'gG')
if [ "${NUM_VAL}" -gt 1000 ]; then
    echo "[!] 錯誤：輸入的容量 (${DISK_SIZE}) 超過安全上限 (最大限制 1000G)！"
    exit 1
fi

echo "[+] 確認使用容量大小: ${DISK_SIZE}"

# 2. 智慧決定儲存路徑：優先 D 槽，沒有則退回 C 槽
WIN_DISK_DIR=$(/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command "if (Test-Path 'D:') { 'D:\\Wsl\\disk' } else { 'C:\\Wsl\\disk' }" | tr -d '\r')
echo "[+] 決定使用的 Windows 儲存目錄: ${WIN_DISK_DIR}"

# 3. 確保 Windows 目錄存在
/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command "if (!(Test-Path '${WIN_DISK_DIR}')) { New-Item -ItemType Directory -Force -Path '${WIN_DISK_DIR}' | Out-Null }"

# 4. 處理防衝突流水號檔名
BASE_NAME="wsl-pve"
COUNTER=0

while true; do
    if [ $COUNTER -eq 0 ]; then
        VHD_NAME="${BASE_NAME}.vhdx"
    else
        VHD_NAME="${BASE_NAME}-${COUNTER}.vhdx"
    fi
    
    CHECK_CMD="if (Test-Path '${WIN_DISK_DIR}\\${VHD_NAME}') { exit 0 } else { exit 1 }"
    if /mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command "$CHECK_CMD"; then
        COUNTER=$((COUNTER + 1))
    else
        break
    fi
done

FINAL_WIN_PATH="${WIN_DISK_DIR}\\${VHD_NAME}"
TMP_WIN_PATH="${WIN_DISK_DIR}\\${BASE_NAME}-tmp.vhdx"

# 轉換為 WSL 路徑格式
DRIVE_LETTER=$(echo "${WIN_DISK_DIR}" | cut -c1 | tr '[:upper:]' '[:lower:]')
SUB_PATH=$(echo "${WIN_DISK_DIR}" | cut -c4- | tr '\\' '/')
FINAL_WSL_PATH="/mnt/${DRIVE_LETTER}/${SUB_PATH}/${VHD_NAME}"
TMP_WSL_PATH="/mnt/${DRIVE_LETTER}/${SUB_PATH}/${BASE_NAME}-tmp.vhdx"

echo "[+] 最終決定 VHD 檔名: ${VHD_NAME}"

# 5. 記錄掛載前的磁碟快照（供後續差集比對）
echo "[*] 正在記錄掛載前的磁碟清單..."
BEFORE_DISKS=$(lsblk -dno NAME | sort)

# 6. 執行你的神招：qemu-img -> Windows copy 洗權限 -> set sparse
echo "[*] 正在 WSL 內透過 qemu-img 建立暫存 VHD (${DISK_SIZE})..."
qemu-img create -f vhdx "${TMP_WSL_PATH}" "${DISK_SIZE}"

echo "[*] 透過 Windows 側 copy 指令複製並洗白權限..."
/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command "Copy-Item '${TMP_WIN_PATH}' '${FINAL_WIN_PATH}' -Force"
/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command "Remove-Item '${TMP_WIN_PATH}' -Force"

echo "[*] 設定為疏鬆檔案 (Sparse)..."
/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command "fsutil sparse setflag '${FINAL_WIN_PATH}'"

# 7. 透過 Windows 側將 VHD 掛載進 WSL (pve)
echo "[*] 正在透過 Windows 主機將 VHD 掛載進 WSL..."
WIN_PATH_FWD=$(echo "${FINAL_WIN_PATH}" | tr '\\' '/')
MOUNT_HOST_CMD="/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command \"wsl -d pve --mount --vhd ${WIN_PATH_FWD} --bare\""
eval "${MOUNT_HOST_CMD}"

# 8. 透過前後 lsblk 差集精準抓出新磁碟
echo "[*] 正在比對新掛載的磁碟..."
AFTER_DISKS=$(lsblk -dno NAME | sort)
NEW_DISKS=$(comm -13 <(echo "$BEFORE_DISKS") <(echo "$AFTER_DISKS"))

if [ -z "$NEW_DISKS" ]; then
    echo "[!] 錯誤：找不到新掛載的磁碟！請檢查 Windows 側掛載是否成功。"
    exit 1
fi

TARGET_DEV=$(echo "$NEW_DISKS" | head -n 1)
BY_ID_PATH=$(find /dev/disk/by-id/ -name "scsi-*" -lname "*${TARGET_DEV}" | head -n 1)

if [ -n "$BY_ID_PATH" ]; then
    FINAL_TARGET="${BY_ID_PATH}"
else
    FINAL_TARGET="/dev/${TARGET_DEV}"
fi

echo "[+] 成功抓到新目標磁碟: ${FINAL_TARGET}"

# 9. 建立 Single ZFS Pool
POOL_NAME="tank"
ZPOOL_OPTS="-f -o ashift=12 -o autotrim=on -O compression=lz4 -O xattr=sa -O atime=off"

echo "[*] 正在以 Single 模式建立 ZFS Pool '${POOL_NAME}'..."
sudo zpool create ${ZPOOL_OPTS} "${POOL_NAME}" "${FINAL_TARGET}"

echo "=================================================="
echo "[+] ZFS Pool 建立成功！"
echo "=================================================="
sudo zpool status "${POOL_NAME}"

# 10. 寫入 /etc/wsl.conf（使用雙引號包覆整個 command，並支援防重複執行）
echo "[*] 正在檢查與更新 /etc/wsl.conf..."

WSL_CONF_PATH="/etc/wsl.conf"
# 組合內部 PowerShell 開機掛載指令，並用雙引號將整個 command 內容包起來
INNER_PS_CMD="/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command \"wsl -d pve --mount --vhd ${WIN_PATH_FWD} --bare\""
NEW_MOUNT_CMD="${INNER_PS_CMD}"

if [ ! -f "${WSL_CONF_PATH}" ]; then
    sudo bash -c "cat << 'EOF' > ${WSL_CONF_PATH}
[boot]
    command = ${NEW_MOUNT_CMD}
EOF"
    echo "[+] 已建立 $WSL_CONF_PATH 並寫入開機掛載指令。"
else
    if ! grep -q "\[boot\]" "${WSL_CONF_PATH}"; then
        # sudo bash -c "echo -e '\n[boot]\ncommand = ${NEW_MOUNT_CMD}' >> ${WSL_CONF_PATH}"
        echo "[+] 已在 /etc/wsl.conf 補上 [boot] 與 command。"
    else
        sudo /bin/cp ${WSL_CONF_PATH} ${WSL_CONF_PATH}.bak
        if grep -q "^\s*command\s*=" "${WSL_CONF_PATH}"; then
            parsed_command=$(cat $WSL_CONF_PATH | perl -0777 -ne '
if (/^\s*command\s*=\s*(["\x27]?)(.*?)\1\s*$/sm) {
    print $2;
}')
            if [[ "$parsed_command" =~ ^[[:space:]]*$ ]]; then
                NEW_CMD="\"${INNER_PS_CMD}\""
            else
                NEW_CMD="\"$parsed_command && \\
${INNER_PS_CMD}\"
"
            fi
            export NEW_CMD

            sudo -E perl -0777 -pi.bak -e '
    my $new_cmd = $ENV{NEW_CMD};
    die "Error: NEW_CMD is empty!\n" unless defined $new_cmd && length $new_cmd > 0;
    
    s/(^\s*command\s*=\s*)(["\x27]?)(.*?)\2\s*$/${1}${new_cmd}/sm;
' ${WSL_CONF_PATH}
        else
            newconf=$(cat $WSL_CONF_PATH | sed -e "/\[boot\]/a command = \"${NEW_MOUNT_CMD}\"")
            # echo $newconf
            sudo bash -c "cat << 'EOF' > ${WSL_CONF_PATH} 
$newconf
EOF"
        fi
    fi
fi
echo "[+] 全部流程完成！下次重啟 WSL 時將自動透過 PowerShell 掛載此 VHD。"
