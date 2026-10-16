#!/bin/bash

# 1. 檢查是否以 root 身分執行
if [ "$EUID" -ne 0 ]; then
    echo "錯誤：此腳本需要 root 權限才能執行。"
    echo "請使用 sudo 執行此腳本，例如：sudo bash $0"
    exit 1
fi

TARGET="tank/lxc"
STORAGE_ID="zfs-lxc"

# 2. 檢查 ZFS dataset 是否已存在（若存在則提示並離開）
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

# 3. 檢查 PVE 儲存庫 ID 是否已存在
if pvesm status | grep -q "^$STORAGE_ID "; then
    echo "錯誤：PVE 儲存庫 ID '$STORAGE_ID' 已經存在於 PVE 中！"
    echo "請先手動執行以下指令移除舊註冊："
    echo "  sudo pvesm remove $STORAGE_ID"
    exit 1
fi

# 4. 建立新的 ZFS dataset 並套用最佳參數
echo "正在建立 ZFS dataset: $TARGET ..."
zfs create "$TARGET"
zfs set compression=zstd "$TARGET"
zfs set atime=off "$TARGET"
zfs set acltype=posixacl "$TARGET"
zfs set xattr=sa "$TARGET"
echo "ZFS 參數設定完成。"

# 5. 自動將這個 dataset 加入 PVE 儲存管理系統 (使用 zfspool 類型)
echo "正在將 $TARGET 註冊到 PVE 儲存庫 (ID: $STORAGE_ID) ..."
pvesm add zfspool "$STORAGE_ID" \
    --pool "$TARGET" \
    --content rootdir,images

echo "全部完成！現在可以在 PVE 建立 LXC 時選擇 '$STORAGE_ID' 了。"
