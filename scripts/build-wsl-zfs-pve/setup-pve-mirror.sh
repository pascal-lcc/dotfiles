#!/usr/bin/env bash
set -euo pipefail

echo "=================================================="
echo "    PVE VHDX & ZFS Pool Mirror 自動化建立工具"
echo "=================================================="

# 0. 檢查 tank pool 是否已存在
if sudo zpool list tank &>/dev/null; then
    echo "[!] 警告：偵測到 ZFS Pool 'tank' 已經存在！"
    echo "[!] 若要重新建立，請先手動解除掛載並銷毀舊 Pool (例如: sudo zpool destroy tank)。"
    exit 0
fi

# 1. 互動式輸入容量，並進行智慧防呆與自動補 "G"
read -rp "請輸入每顆 VHD 的容量 (例如 100 或 100G) [預設 100G]: " RAW_SIZE
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

# 2. 互動式詢問需要幾顆碟做 Mirror (預設 2 顆)
read -rp "請輸入要建立 Mirror 的磁碟數量 (至少 2 顆) [預設 2]: " DISK_COUNT
DISK_COUNT=${DISK_COUNT:-2}

if [ "${DISK_COUNT}" -lt 2 ]; then
    echo "[!] 錯誤：Mirror 模式至少需要 2 顆磁碟！"
    exit 1
fi

echo "[+] 設定摘要: 數量 = ${DISK_COUNT} 顆, 單顆容量 = ${DISK_SIZE}"

# 3. 智慧分配不同磁碟槽 (D:, E:, F:, ...)
# 定義候選磁碟槽清單
CANDIDATE_DRIVES=("D" "E" "F" "G" "H")
ALLOCATED_DIRS=()

for ((i=0; i<DISK_COUNT; i++)); do
    target_drive=""
    for drv in "${CANDIDATE_DRIVES[@]}"; do
        # 檢查該磁碟槽是否存在於 Windows 系統中
        EXISTS=$(/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command "if (Test-Path '${drv}:') { '1' } else { '0' }" | tr -d '\r')
        if [ "${EXISTS}" = "1" ]; then
            # 檢查這個槽是不是已經被前面分配過了
            already_used=0
            for allocated in "${ALLOCATED_DIRS[@]}"; do
                if [[ "${allocated}" == "${drv}:"* ]]; then
                    already_used=1
                    break
                fi
            done
            if [ "${already_used}" -eq 0 ]; then
                target_drive="${drv}"
                break
            fi
        fi
    done
    
    # 如果獨立槽不夠，被迫退回 C 槽分流或提示
    if [ -z "${target_drive}" ]; then
        echo "[!] 注意：獨立磁碟槽（D, E, F...）不足 ${DISK_COUNT} 個，將允許共用 C 槽或現有磁碟進行分配。"
        target_drive="C"
    fi
    
    WIN_DIR="${target_drive}:\\Wsl\\disk"
    ALLOCATED_DIRS+=("${WIN_DIR}")
    
    # 確保 Windows 側目錄存在
    /mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command "if (!(Test-Path '${WIN_DIR}')) { New-Item -ItemType Directory -Force -Path '${WIN_DIR}' | Out-Null }"
    echo "[+] 第 $((i+1)) 顆 VHD 分配儲存目錄: ${WIN_DIR}"
done

# 4. 針對每一顆 VHD 檢查並決定不重複的檔名
FINAL_WIN_PATHS=()
FINAL_WSL_PATHS=()
HOST_POWER_COMMANDS=()

BASE_NAME="wsl-pve-mirror"

for ((i=0; i<DISK_COUNT; i++)); do
    WIN_DISK_DIR="${ALLOCATED_DIRS[$i]}"
    
    # 檢查同名檔案並自動遞增產生新流水號
    counter=0
    while true; do
        if [ $counter -eq 0 ]; then
            vhd_filename="${BASE_NAME}-$((i+1)).vhdx"
        else
            vhd_filename="${BASE_NAME}-$((i+1))-${counter}.vhdx"
        fi
        
        check_cmd="if (Test-Path '${WIN_DISK_DIR}\\${vhd_filename}') { exit 0 } else { exit 1 }"
        if /mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command "$check_cmd"; then
            counter=$((counter + 1))
        else
            break
        fi
    done
    
    final_win_path="${WIN_DISK_DIR}\\${vhd_filename}"
    tmp_win_path="${WIN_DISK_DIR}\\${BASE_NAME}-tmp-$((i+1)).vhdx"
    
    # 轉換 WSL 路徑
    d_letter=$(echo "${WIN_DISK_DIR}" | cut -c1 | tr '[:upper:]' '[:lower:]')
    sub_p=$(echo "${WIN_DISK_DIR}" | cut -c4- | tr '\\' '/')
    final_wsl_path="/mnt/${d_letter}/${sub_p}/${vhd_filename}"
    tmp_wsl_path="/mnt/${d_letter}/${sub_p}/${BASE_NAME}-tmp-$((i+1)).vhdx"
    
    echo "[*] 正在建立第 $((i+1)) 顆 VHD: ${vhd_filename} (於 ${WIN_DISK_DIR})..."
    
    # 建立、複製洗權限、設 sparse
    qemu-img create -f vhdx "${tmp_wsl_path}" "${DISK_SIZE}"
    /mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command "Copy-Item '${tmp_win_path}' '${final_win_path}' -Force"
    /mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command "Remove-Item '${tmp_win_path}' -Force"
    /mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command "fsutil sparse setflag '${final_win_path}'"
    
    FINAL_WIN_PATHS+=("${final_win_path}")
    
    # 準備 PowerShell 掛載指令格式
    win_path_fwd=$(echo "${final_win_path}" | tr '\\' '/')
    HOST_POWER_COMMANDS+=("/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command \\\"wsl -d pve --mount --vhd ${win_path_fwd} --bare\\\"")
done

# 5. 依序掛載並透過 lsblk 差集抓取新磁碟
TARGET_DEVICES=()

for ((i=0; i<DISK_COUNT; i++)); do
    win_path="${FINAL_WIN_PATHS[$i]}"
    win_path_fwd=$(echo "${win_path}" | tr '\\' '/')
    
    echo "[*] 記錄掛載前的磁碟快照..."
    before_disks=$(lsblk -dno NAME | sort)
    
    echo "[*] 正在透過 Windows 主機掛載第 $((i+1)) 顆 VHD..."
    mount_host_cmd="/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -Command \"wsl -d pve --mount --vhd ${win_path_fwd} --bare\""
    eval "${mount_host_cmd}"
    
    echo "[*] 比對新掛載的磁碟..."
    after_disks=$(lsblk -dno NAME | sort)
    new_disks=$(comm -13 <(echo "$before_disks") <(echo "$after_disks"))
    
    if [ -z "$new_disks" ]; then
        echo "[!] 錯誤：找不到第 $((i+1)) 顆新掛載的磁碟！"
        exit 1
    fi
    
    target_dev=$(echo "$new_disks" | head -n 1)
    by_id_path=$(find /dev/disk/by-id/ -name "scsi-*" -lname "*${target_dev}" | head -n 1)
    
    if [ -n "$by_id_path" ]; then
        final_target="${by_id_path}"
    else
        final_target="/dev/${target_dev}"
    fi
    
    echo "[+] 成功抓到第 $((i+1)) 顆目標磁碟: ${final_target}"
    TARGET_DEVICES+=("${final_target}")
done

# 6. 組合 ZFS Mirror 建立指令
POOL_NAME="tank"
ZPOOL_OPTS="-f -o ashift=12 -o autotrim=on -O compression=lz4 -O xattr=sa -O atime=off"

# 組裝 mirror 參數群
MIRROR_ARGS="mirror"
for dev in "${TARGET_DEVICES[@]}"; do
    MIRROR_ARGS="${MIRROR_ARGS} ${dev}"
done

echo "[*] 正在以 Mirror 模式建立 ZFS Pool '${POOL_NAME}'..."
sudo zpool create ${ZPOOL_OPTS} "${POOL_NAME}" ${MIRROR_ARGS}

echo "=================================================="
echo "[+] ZFS Mirror Pool 建立成功！"
echo "=================================================="
sudo zpool status "${POOL_NAME}"

# 7. 組合多道 PowerShell 掛載指令，並用一對雙引號包覆整行 command
echo "[*] 正在檢查與更新 /etc/wsl.conf..."

WSL_CONF_PATH="/etc/wsl.conf"

# 將所有 PowerShell 掛載指令用 && 串接
JOINED_PS_CMDS=""
for cmd in "${HOST_POWER_COMMANDS[@]}"; do
    if [ -z "${JOINED_PS_CMDS}" ]; then
        JOINED_PS_CMDS="${cmd}"
    else
        JOINED_PS_CMDS="${JOINED_PS_CMDS} && ${cmd}"
    fi
done

# 整個 command 的內容格式固定為：command = "指令1 && 指令2"
NEW_COMMAND_LINE="command = \"${JOINED_PS_CMDS}\""

if [ ! -f "${WSL_CONF_PATH}" ]; then
    # 若檔案不存在，直接建立並寫入 [boot] 與 command
    sudo bash -c "cat << 'EOF' > ${WSL_CONF_PATH}
[boot]
${NEW_COMMAND_LINE}
EOF"
    echo "[+] 已建立 /etc/wsl.conf 並寫入 Mirror 開機掛載指令。"
else
    # 確保有 [boot] 區塊
    if ! grep -q "\[boot\]" "${WSL_CONF_PATH}"; then
        sudo bash -c "echo -e '\n[boot]\n${NEW_COMMAND_LINE}' >> ${WSL_CONF_PATH}"
        echo "[+] 已在 /etc/wsl.conf 補上 [boot] 與 command。"
    else
        # 檢查是否有現有的 command 欄位
        if grep -q "^\s*command\s*=" "${WSL_CONF_PATH}"; then
            EXISTING_VAL=$(grep -E "^\s*command\s*=" "${WSL_CONF_PATH}" | sed 's/^[ \t]*command[ \t]*=[ \t]*//')
            
            # 如果原本的 command 是空的，直接覆蓋
            if [ -z "${EXISTING_VAL}" ] || [ "${EXISTING_VAL}" = '""' ] || [ "{EXISTING_VAL}" = "''" ]; then
                sudo sed -i "s|^\s*command\s*=.*|${NEW_COMMAND_LINE}|" "${WSL_CONF_PATH}"
                echo "[+] /etc/wsl.conf 的 command 原本為空，已填入新 Mirror 指令。"
            else
                # 檢查是否已經包含此組 VHD 路徑，避免重複執行時無限疊加
                first_vhd_path=$(echo "${FINAL_WIN_PATHS[0]}" | tr '\\' '/')
                if echo "${EXISTING_VAL}" | grep -q "${first_vhd_path}"; then
                    echo "[+] 偵測到 /etc/wsl.conf 的 command 已經包含這些 Mirror VHD，略過重複新增。"
                else
                    # 萃取出舊 command 雙引號內部的指令，並用 && 與新指令串接
                    # 去除前後可能存在的雙引號
                    CLEAN_EXISTING=$(echo "${EXISTING_VAL}" | sed 's/^"//;s/"$//')
                    COMBINED_CMDS="${CLEAN_EXISTING} && ${JOINED_PS_CMDS}"
                    UPDATED_COMMAND_LINE="command = \"${COMBINED_CMDS}\""
                    
                    sudo sed -i "s|^\s*command\s*=.*|${UPDATED_COMMAND_LINE}|" "${WSL_CONF_PATH}"
                    echo "[+] 已將新 Mirror 掛載指令串接到現有的 command 後方。"
                fi
            fi
        else
            # 有 [boot] 但沒有 command 欄位，在 [boot] 下方補上
            sudo sed -i "/\[boot\]/a ${NEW_COMMAND_LINE}" "${WSL_CONF_PATH}"
            echo "[+] 已在 [boot] 區塊下補上 command 欄位。"
        fi
    fi
fi

echo "[+] 全部 Mirror 流程完成！"
