#!/bin/bash
set -euo pipefail

# 1. 檢查是否以 root 身分執行
if [ "$EUID" -ne 0 ]; then
    echo "錯誤：此腳本需要 root 權限才能執行。"
    echo "請使用 sudo 執行此腳本，例如：sudo bash $0"
    exit 1
fi

# 2. 自動檢查並列出系統中現有的 ZFS Pool
POOLS=$(zpool list -H -o name 2>/dev/null || true)
if [ -z "$POOLS" ]; then
    echo "錯誤：系統中找不到任何 ZFS Pool！"
    echo "請先建立 ZFS Pool 後再執行此腳本。"
    exit 1
fi

echo "=================================================="
echo " 偵測到以下可用的 ZFS Pool："
echo "=================================================="

# 互動式選單讓使用者挑選 Pool
PS3="請輸入對應的數字來選擇要使用的 ZFS Pool: "
select CHOSEN_POOL in $POOLS; do
    if [ -n "$CHOSEN_POOL" ]; then
        echo "[+] 已選擇 ZFS Pool: ${CHOSEN_POOL}"
        break
    else
        echo "[!] 無效的選擇，請重新輸入。"
    fi
done

TARGET="${CHOSEN_POOL}/lxc"
# 為了避免多個 pool 時 storage id 撞名，這裡動態帶入 pool 名稱
STORAGE_ID="zfs-${CHOSEN_POOL}-lxc"

echo "[+] 目標 ZFS Dataset: ${TARGET}"
echo "[+] PVE 儲存庫 ID: ${STORAGE_ID}"
echo "=================================================="

# 3. 檢查 ZFS dataset 是否已存在（若存在則提示並離開）
if zfs list "$TARGET" &>/dev/null; then
    echo "錯誤：ZFS dataset '$TARGET' 已經存在！"
    echo "基於安全考量，腳本不會自動銷毀現有資料。"
    echo "如果你確定要重建，請依序執行以下手動清理指令後，再重新執行此腳本："
    echo "  1. 從 PVE 移除儲存庫註冊："
    echo "     sudo pvesm remove $STORAGE_ID"
    echo "  2. 銷毀舊的 ZFS dataset 與其子容器資料："
    echo "     sudo zfs destroy -r $TARGET"
    exit 1
fi

# 4. 檢查 PVE 儲存庫 ID 是否已存在
if pvesm status | grep -q "^$STORAGE_ID "; then
    echo "錯誤：PVE 儲存庫 ID '$STORAGE_ID' 已經存在於 PVE 中！"
    echo "請先手動執行以下指令移除舊註冊："
    echo "  sudo pvesm remove $STORAGE_ID"
    exit 1
fi

# 5. 建立新的 ZFS dataset 並套用最佳參數
echo "正在建立 ZFS dataset: $TARGET ..."
zfs create "$TARGET"
zfs set compression=zstd "$TARGET"
zfs set atime=off "$TARGET"
zfs set acltype=posixacl "$TARGET"
zfs set xattr=sa "$TARGET"
echo "ZFS 參數設定完成。"

# 6. 自動將這個 dataset 加入 PVE 儲存管理系統 (使用 zfspool 類型)
echo "正在將 $TARGET 註冊到 PVE 儲存庫 (ID: $STORAGE_ID) ..."
pvesm add zfspool "$STORAGE_ID" \
    --pool "$TARGET" \
    --content rootdir,images

echo "全部完成！現在可以在 PVE 建立 LXC 時選擇 '$STORAGE_ID' 了。"
