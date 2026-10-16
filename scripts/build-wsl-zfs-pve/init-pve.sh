#!/usr/bin/env bash
set -e

PVE_HOSTNAME="pve"

# 自動取得系統 Debian 代號 (例如 trixie, bookworm)
# 1. 自動從系統讀取代號
if [ -f /etc/os-release ]; then
    source /etc/os-release
    DETECTED_CODENAME="${VERSION_CODENAME:-trixie}"
else
    DETECTED_CODENAME="trixie"
fi

# 2. 定義 Proxmox 官方目前實際有支援的代號白名單
# （例如：bookworm 是 Debian 12，trixie 是 Debian 13）
SUPPORTED_CODENAMES=("bookworm" "trixie")

# 3. 檢查抓到的代號是否在支援清單內
DEBIAN_CODENAME="trixie" # 預設安全 fallback
for code in "${SUPPORTED_CODENAMES[@]}"; do
    if [ "$DETECTED_CODENAME" == "$code" ]; then
        DEBIAN_CODENAME="$code"
        break
    fi
done

if [ "$DEBIAN_CODENAME" != "$DETECTED_CODENAME" ]; then
    echo "[!] 警告：偵測到系統代號 '$DETECTED_CODENAME'，但 Proxmox 官方未支援。"
    echo "[*] 自動安全切換至相容的官方代號: $DEBIAN_CODENAME"
fi

echo "[+] 最終使用的 PVE 套件庫代號: $DEBIAN_CODENAME"

function setup_hostname() {
    echo "[*] 設定主機名稱: $PVE_HOSTNAME"
    hostnamectl set-hostname "$PVE_HOSTNAME"
    echo "$PVE_HOSTNAME" >/etc/hostname
}

function install_base_packages() {
    echo "[*] 更新軟體源並安裝基本套件..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    apt-get install -y git wget ifupdown2 bridge-utils nftables
}

function setup_resolv() {
    echo "[*] 設定固定的 /etc/resolv.conf..."
    # 確保解除可能存在的符號連結或殘留掛載
    rm -f /etc/resolv.conf

    # 寫入真實的 DNS 內容
    tee /etc/resolv.conf >/dev/null <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
}

function setup_hosts() {
    echo "[*] 檢查並更新 /etc/hosts 中的主機名稱對應..."

    local target_ip=""

    # 策略 1: 優先尋找狀態為 UP 且有 inet IP 的網卡（排除 lo 和 docker 等虛擬介面）
    target_ip=$(ip -4 addr show up scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)

    # 策略 2: 如果找不到，嘗試抓預設路由出去的那張網卡 IP
    if [ -z "$target_ip" ]; then
        target_ip=$(ip route show default 2>/dev/null | awk '/default/ {print $3}')
    fi

    # 策略 3: 真的都抓不到則退回 127.0.1.1
    if [ -z "$target_ip" ]; then
        target_ip="127.0.1.1"
    fi

    echo "[+] 偵測到當前 PVE 節點有效 IP: $target_ip"

    # 確保 /etc/hosts 中存在對應，若已存在則替換，不存在則追加
    if grep -q "$PVE_HOSTNAME" /etc/hosts; then
        sudo sed -i "s/.*$PVE_HOSTNAME.*/$target_ip\t$PVE_HOSTNAME.proxmox.com $PVE_HOSTNAME/g" /etc/hosts
    else
        echo -e "$target_ip\t$PVE_HOSTNAME.proxmox.com $PVE_HOSTNAME" >>/etc/hosts
    fi
}

function setup_network() {
    echo "[*] 寫入 /etc/network/interfaces 網路設定..."
    tee /etc/network/interfaces >/dev/null <<'EOF'
auto lo
iface lo inet loopback

auto vmbr1
iface vmbr1 inet manual
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        bridge-vlan-aware yes
        bridge-vids 10 20
#Internal VLAN Lab

auto vmbr1.10
iface vmbr1.10 inet static
        address 10.10.10.1/24
        post-up nft 'add table ip pve_nat'
        post-up nft 'add chain ip pve_nat vlan10 { type nat hook postrouting priority -100 ; }'
        post-up nft 'add rule ip pve_nat vlan10 ip saddr 10.10.10.0/24 ip daddr != { 10.20.0.0/16, 10.40.0.0/16, 192.168.0.0/24 } masquerade'
        post-down nft 'delete chain ip pve_nat vlan10' || true

auto vmbr1.20
iface vmbr1.20 inet static
        address 10.10.20.1/24
        post-up nft 'add table ip pve_nat'
        post-up nft 'add chain ip pve_nat vlan20 { type nat hook postrouting priority 50 ; }'
        post-up nft 'add rule ip pve_nat vlan20 ip saddr 10.10.20.0/24 ip daddr != { 10.10.0.0/16, 10.40.0.0/16, 192.168.0.0/24 } masquerade'
        post-down nft 'delete chain ip pve_nat vlan20' || true
EOF
}

function setup_pve_repositories() {
    echo "[*] 設定 Proxmox VE 與 Ceph 官方套件庫 (代號: $DEBIAN_CODENAME)..."

    # PVE Repository
    tee /etc/apt/sources.list.d/pve-install-repo.sources >/dev/null <<EOL
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $DEBIAN_CODENAME
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOL

    # 下載對應版本的 GPG key (若該版本有專屬 key，或用通用金鑰)
    # 註：如果日後版本變更，可改抓通用金鑰或對應檔名
    wget -qO /usr/share/keyrings/proxmox-archive-keyring.gpg "https://enterprise.proxmox.com/debian/proxmox-archive-keyring-${DEBIAN_CODENAME}.gpg" ||
        wget -qO /usr/share/keyrings/proxmox-archive-keyring.gpg "https://enterprise.proxmox.com/debian/proxmox-archive-keyring.gpg"

    # 修正 backports
    if [ -f /etc/apt/sources.list.d/debian-backports.sources ]; then
        sed -i 's|^Signed-By:.*|Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg|' /etc/apt/sources.list.d/debian-backports.sources
    fi

    # 停用企業免費版源 (如果存在)
    # if [ -f /etc/apt/sources.list.d/pve-enterprise.sources ]; then
    #     mv /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.sources.bak
    # fi

    # Ceph Repository (動態帶入代號，此處以 squid/ceph 版本為例或對應代號)
    tee /etc/apt/sources.list.d/ceph.sources >/dev/null <<EOL
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: $DEBIAN_CODENAME
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOL

    # 現代化 Sources 轉換 (Debian 12/13 適用)
    if command -v apt &>/dev/null && apt-get --help | grep -q modernize-sources; then
        apt modernize-sources || true
    fi
}

function cleanup_enterprise_repo() {
    echo "[*] 檢查並停用 Proxmox 企業免費版源..."
    if [ -f /etc/apt/sources.list.d/pve-enterprise.sources ]; then
        mv /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.sources.bak
        echo "[+] 已成功將企業版源重新命名為 .bak"
    else
        echo "[+] 企業版源檔案不存在，跳過。"
    fi
}

function install_pve_and_tools() {
    echo "[*] 更新套件清單並升級系統..."
    apt-get update
    apt-get full-upgrade -y

    echo "[*] 安裝 Proxmox VE、Postfix、開放式 iSCSI 與 ZFS 相關工具..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y postfix open-iscsi chrony proxmox-ve --no-install-recommends

    # ZFS 實驗與壓縮工具
    apt-get install -y zfsutils-linux lz4 xz-utils
}

function cleanup_unwanted_packages() {
    echo "[*] 清理 WSL 環境不需要的 Debian 核心與引導工具..."
    apt-get remove -y linux-image-amd64 'linux-image-6.*' os-prober || true
    apt-get autoremove -y || true

    echo "[*] 更新 initramfs..."
    update-initramfs -u || true
}

function patch_pve_ui() {
    echo "[*] 正在修補 PVE 網頁介面（去除無訂閱警告彈窗）..."

    local widget_file="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"

    if [ -f "$widget_file" ]; then
        # 1. 找到判斷式並強行改為 false (不顯示彈窗)
        sed -i.bak 's/if (res.status !== "Active")/if (false)/g' "$widget_file"

        # 2. 將訂閱狀態空值改為 active
        sed -i 's/subscriptionActive: "",/subscriptionActive: "active",/g' "$widget_file"

        echo "[+] PVE UI 修補完成！"
    else
        echo "[-] 找不到 $widget_file，跳過 UI 修補。"
    fi
}

function fix_rrd_permissions() {
    echo "[*] 正在調整 RRD 數據目錄權限以供 www-data 讀取..."
    if [ -d "/var/lib/rrdcached/db" ]; then
        chown -R root:www-data /var/lib/rrdcached/db
        chmod -R 755 /var/lib/rrdcached/db
        echo "[+] RRD 權限調整完成！"
    fi
}

function apply_system_optimizations() {
    set +e
    echo "[*] 正在調整系統日誌 (Journald) 與資源限制..."

    # 1. Journald 日誌限制與持久化設定
    sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf
    sed -i 's/^#MaxRetentionSec=.*/MaxRetentionSec=1month/' /etc/systemd/journald.conf
    sed -i 's/#Storage=auto/Storage=persistent/' /etc/systemd/journald.conf
    sed -i 's/#RuntimeMaxUse=/RuntimeMaxUse=300M/' /etc/systemd/journald.conf
    sed -i 's/#SystemMaxFiles=/SystemMaxFiles=50/' /etc/systemd/journald.conf

    journalctl --vacuum-time=1s
    systemctl restart systemd-journald

    echo "[*] 設定 tmpfs 記憶體上限..."
    mkdir -p /etc/systemd/system/tmp.mount.d/
    tee /etc/systemd/system/tmp.mount.d/override.conf >/dev/null <<'EOF'
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=2G
EOF

    echo "[*] 修復 WSL 下的 LXCFS 服務..."
    if [ -f /usr/lib/systemd/system/lxcfs.service ]; then
        sed -i 's/^ConditionVirtualization/#ConditionVirtualization/' /usr/lib/systemd/system/lxcfs.service
    fi

    #設定swap及cache換頁
    tee /etc/sysctl.d/pve-custom.conf >/dev/null <<'EOF'
# 降低換頁傾向（預設 60，建議改 10）
vm.swappiness = 10

# 調整快取回收傾向（選配，讓核心盡量保留檔案快取）
vm.vfs_cache_pressure = 50
EOF

    echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/pve.conf
    sudo sysctl -p /etc/sysctl.d/pve.conf

    update-alternatives --set iptables /usr/sbin/iptables-nft
    update-alternatives --set arptables /usr/sbin/arptables-nft

    echo "[*] 重新載入 Systemd 並重啟相關服務..."
    sysctl --system
    systemctl daemon-reload

    systemctl restart lxcfs.service || true
    systemctl restart tmp.mount || true

    set -e
    echo "[+] 系統優化與資源限制設定完畢！"
}

function setup_wsl_conf() {
    echo "[*] 正在設定 /etc/wsl.conf（鎖定 Hostname、DNS/Hosts 覆寫與自動修復 IP）..."
    
    # 確保 /usr/local/bin 目錄存在（若不存在則自動建立）
    sudo mkdir -p /usr/local/bin

    # 建立一個開機自動修復 hosts 的輕量腳本
    sudo tee /usr/local/bin/fix-pve-hosts.sh >/dev/null << 'EOF'
#!/usr/bin/env bash
CUR_IP=$(ip -4 addr show up scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
if [ -n "$CUR_IP" ]; then
    sed -i "s/.*pve.*/$CUR_IP\tpve.proxmox.com pve/g" /etc/hosts
fi
EOF
    sudo chmod +x /usr/local/bin/fix-pve-hosts.sh

    # 寫入 /etc/wsl.conf
    tee /etc/wsl.conf >/dev/null <<EOF
[boot]
systemd=true
command="/usr/local/bin/fix-pve-hosts.sh"

[network]
generateResolvConf=false
generateHosts=false
hostname=$PVE_HOSTNAME

[automount]
options = "metadata,umask=22,fmask=11"
enabled = true
mountFsTab = true

[interop]
enabled = true
appendWindowsPath = false

EOF
}

function main() {
    setup_wsl_conf
    setup_hostname
    install_base_packages
    setup_resolv
    setup_hosts
    setup_network
    setup_pve_repositories
    install_pve_and_tools
    cleanup_unwanted_packages
    fix_rrd_permissions
    apply_system_optimizations
    patch_pve_ui
    cleanup_enterprise_repo
    echo "[+] PVE 完整環境與所有附加套件安裝設定完畢！"
}

main
