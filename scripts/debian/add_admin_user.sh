#!/bin/bash
read -p "Enter admin username [pascual]: " UNAME
UNAME=${UNAME:-pascual}

if ! dpkg -s sudo zsh >/dev/null 2>&1; then
    apt-get update && apt-get install -y sudo zsh
fi

if ! id "$UNAME" &>/dev/null; then
    # 注意：如果之後要掛載 ZFS volume 到 /home，建議先掛載再執行此腳本
    useradd -m -s /bin/zsh "$UNAME"
    echo "Please set password for $UNAME:"
    passwd "$UNAME"
fi

# 獨立 sudoers 設定
if [ ! -f "/etc/sudoers.d/$UNAME" ]; then
    echo "$UNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$UNAME"
    chmod 0440 "/etc/sudoers.d/$UNAME"
fi
