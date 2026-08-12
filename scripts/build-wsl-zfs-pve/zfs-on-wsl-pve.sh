#!/usr/bin/env bash
set -euo pipefail

# Exit if we're running as root, unless this is a GitHub Actions runner
if [ "${GITHUB_ACTIONS:-false}" = "true" ]; then
  echo -e "Running inside GitHub Actions runner.\nAllowing rootful build.\n"
  SUDO=""
  USER="root"
else
  if [ "$(id -u)" -eq 0 ]; then
    echo -e "Please do not run this script as root.\nThis script uses sudo to elevate only where needed.\n" >&2; exit 1
  fi
  SUDO="sudo"
fi

KERNELSUFFIX="-with-zfs"
KERNELDIR="/opt/zfs-on-wsl-kernel"
ZFSDIR="/opt/zfs-on-wsl-zfs"

# Install pre-requisites
export DEBIAN_FRONTEND=noninteractive
${SUDO} apt-get update && \
${SUDO} apt-get --autoremove upgrade -y && \
${SUDO} apt-get install -y tzdata && \
${SUDO} apt-get install -y \
  alien \
  autoconf \
  automake \
  bc \
  binutils \
  bison \
  build-essential \
  curl \
  dkms \
  dwarves \
  fakeroot \
  flex \
  gawk \
  git \
  libaio-dev \
  libattr1-dev \
  libblkid-dev \
  libelf-dev \
  libffi-dev \
  libssl-dev \
  libtirpc-dev \
  libtool \
  libudev-dev \
  python3 \
  python3-cffi \
  python3-dev \
  python3-setuptools \
  uuid-dev \
  wget \
  zlib1g-dev

# Remove the Ubuntu-provided ZFS utilities if we have them
# (our build process will build them later)
${SUDO} apt-get purge -y zfsutils-linux

# Create kernel directory
${SUDO} mkdir -p $KERNELDIR $ZFSDIR
${SUDO} chown -R "${USER}":"${USER}" $KERNELDIR $ZFSDIR

# Clone Microsoft kernel source
UPSTREAMKERNELVER=$(curl -s https://api.github.com/repos/microsoft/WSL2-Linux-Kernel/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
test -d $KERNELDIR/.git || git clone --branch "$UPSTREAMKERNELVER" --single-branch --depth 1 https://github.com/microsoft/WSL2-Linux-Kernel.git $KERNELDIR

# Enter kernel source dir, reset it in case we have any half-finished builds, and update it
(cd $KERNELDIR && git reset --hard && git checkout "$UPSTREAMKERNELVER" && git pull)

# Update existing kernel config with any custom config options we want
export KCONFIG_CONFIG="Microsoft/config-wsl"
(
cd $KERNELDIR

# Run make olddefconfig to ensure config is up to date
make olddefconfig

# Create a blank ZFS config overlay
echo ''  > zfs.config

# Here, we enable CONFIG_USB_STORAGE to enable USB Mass Storage support,
# which does not appear to be enabled by default in Microsoft's kernel config
# but is needed for passing through USB devices to use for ZFS
#
# Also update the kernel name to add our suffix
{
echo "CONFIG_USB_STORAGE=y"
echo "CONFIG_LOCALVERSION=${KERNELSUFFIX}"
} >> zfs.config

# Statically build any config options we need for Docker to work
# We get this by running the following inside WSL *using a default kernel*:
#   wget https://raw.githubusercontent.com/moby/moby/refs/heads/master/contrib/check-config.sh
#   ./check-config.sh | sed '/Optional/q' | grep "(as module)" | awk '{print $2}' | cut -d':' -f1 | awk '{print $1"=y"}'
cat << 'EOF' >> zfs.config
CONFIG_BRIDGE=y
CONFIG_BRIDGE_NETFILTER=y
CONFIG_IP_NF_FILTER=y
CONFIG_IP_NF_MANGLE=y
CONFIG_IP_NF_TARGET_MASQUERADE=y
CONFIG_IP6_NF_FILTER=y
CONFIG_IP6_NF_MANGLE=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y
CONFIG_NETFILTER_XT_MATCH_IPVS=y
CONFIG_NETFILTER_XT_MARK=y
CONFIG_IP_NF_RAW=y
CONFIG_IP_NF_NAT=y
CONFIG_IP6_NF_RAW=y
CONFIG_IP6_NF_NAT=y
CONFIG_VLAN_8021Q=y
CONFIG_LLC=y
CONFIG_STP=y
CONFIG_NAMESPACES=y
CONFIG_UTS_NS=y
CONFIG_IPC_NS=y
CONFIG_USER_NS=y
CONFIG_PID_NS=y
CONFIG_NET_NS=y
CONFIG_CGROUPS=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_PIDS=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CGROUP_HUGETLB=y
CONFIG_CGROUP_PERF=y
CONFIG_CGROUP_SCHED=y
CONFIG_CGROUP_MEMCG=y
CONFIG_CGROUP_MEMCG_SWAP=y
CONFIG_EFI_PARTITION=y
CONFIG_ZLIB_DEFLATE=y
CONFIG_ZLIB_INFLATE=y
CONFIG_VIRTUALIZATION=y
CONFIG_KVM=y
CONFIG_KVM_INTEL=y
CONFIG_KVM_AMD=y
CONFIG_CGROUP_NS=y
CONFIG_CGROUP_BPF=y
CONFIG_MEMCG=y
CONFIG_MEMCG_SWAP=y
CONFIG_FUSE_FS=y
CONFIG_TMPFS=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_VFS_CAP_DATA=y
CONFIG_VHOST_NET=y
CONFIG_BRIDGE=y
CONFIG_BLK_CGROUP=y
CONFIG_OVERLAY_FS=y
CONFIG_SUNRPC=y
CONFIG_NFS_FS=y
CONFIG_NFS_V3=y
CONFIG_NFS_V4=y
CONFIG_ZLIB_DEFLATE=y
CONFIG_ZLIB_INFLATE=y
CONFIG_LIBCRC32C=y
CONFIG_SOFT_WATCHDOG=y
CONFIG_BRIDGE_NETFILTER=y
CONFIG_NETFILTER_FAMILY_BRIDGE=y
CONFIG_SKB_EXTENSIONS=y
CONFIG_NET_CLS_ACT=y
CONFIG_NET_SCH_HTB=y
CONFIG_NET_SCH_INGRESS=y
CONFIG_VETH=y
CONFIG_MACVLAN=y
CONFIG_TUN=y
CONFIG_CGROUP_WRITEBACK=y
CONFIG_CPUSETS=y
CONFIG_CRYPTO_SHA256=y
CONFIG_CRYPTO_SHA512=y
CONFIG_BLK_DEV_LOOP=y
CONFIG_WATCHDOG_NOWAYOUT=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_BLK=y
CONFIG_NETFILTER_XT_TARGET_MASQUERADE=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_MATCH_IPVS=y
CONFIG_NETFILTER_XT_MATCH_COMMENT=y
CONFIG_IP_VS=y
CONFIG_BLK_DEV_THROTTLING=y
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
# 防火牆核心支持
CONFIG_NETFILTER=y
CONFIG_NETFILTER_ADVANCED=y
CONFIG_NF_CONNTRACK=y
CONFIG_NF_CONNTRACK_PROCFS=y
CONFIG_NF_CONNTRACK_EVENTS=y
CONFIG_NF_CT_PROTO_TCP=y
CONFIG_NF_CT_PROTO_UDP=y
CONFIG_NF_CT_PROTO_ICMP=y
CONFIG_NF_TABLES=y
CONFIG_NF_TABLES_INET=y
# 這是你剛才抓到的「導航儀」，負責確認回包路徑
CONFIG_NFT_FIB_IPV4=y
# 這是讓 nftables 能處理「介面 Meta 資訊」的基礎 (例如判斷 iifname)
CONFIG_NFT_META=y
# 這是核心在做 NAT 之前，處理封包分片重組的必要零件
CONFIG_NF_DEFRAG_IPV4=y
CONFIG_NFT_CT=y
CONFIG_NFT_NAT=y
CONFIG_NFT_MASQ=y
CONFIG_NF_NAT=y
# --- 讓 iptables 指令不報錯的相容層 (這能解決 TRACE 報錯) ---
CONFIG_NETFILTER_XTABLES=y
CONFIG_NETFILTER_XT_TARGET_TRACE=y
CONFIG_NFT_COMPAT=y
# PVE 防火牆必備：完整的 Netfilter 支援
CONFIG_NETFILTER_XT_TARGET_REJECT=y
CONFIG_NETFILTER_XT_MATCH_BPF=y
CONFIG_NETFILTER_XT_MATCH_CONNLIMIT=y
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y
CONFIG_NETFILTER_XT_MATCH_STATE=y
# 具體的 iptables 支援 (PVE 強烈依賴)
CONFIG_IP_NF_IPTABLES=y
CONFIG_IP_NF_FILTER=y
CONFIG_IP_NF_TARGET_REJECT=y
CONFIG_IP_NF_MANGLE=y
CONFIG_IP_NF_RAW=y
# NFT 規則功能擴展
CONFIG_NFT_LIMIT=y
CONFIG_NFT_LOG=y
CONFIG_NFT_REJECT=y

# --- 讓核心「看懂」IPv4 流量的關鍵 (你目前缺這個) ---
CONFIG_NF_TABLES_IPV4=y
CONFIG_NFT_CHAIN_NAT_IPV4=y
CONFIG_NF_NAT_IPV4=y
CONFIG_NFT_BRIDGE_META=y
CONFIG_NFT_BRIDGE_REJECT=y

# 確保 NAT 變裝的核心邏輯
CONFIG_NF_NAT_MASQUERADE=y

CONFIG_NF_CONNTRACK_FTP=y
CONFIG_NF_CONNTRACK_TFTP=y
CONFIG_NF_NAT_FTP=y
CONFIG_NF_CONNTRACK_BRIDGE=y
CONFIG_NF_TABLES_BRIDGE=y
CONFIG_NFT_CHAIN_FORWARD_IPV4=y
CONFIG_NF_TABLES_ARP=y
EOF

# Merge the zfs.config overlay with our current .config file
echo "Applying ZFS config with the following options..."
cat zfs.config
echo ""
scripts/kconfig/merge_config.sh "$KERNELDIR/$KCONFIG_CONFIG" zfs.config

# Prep kernel and use the defaults for any new config options we just unlocked
make olddefconfig
make prepare
)

# Clone ZFS
UPSTREAMZFSVER=$(curl -s https://api.github.com/repos/openzfs/zfs/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
test -d $ZFSDIR/.git || git clone --branch "$UPSTREAMZFSVER" --depth 1 https://github.com/zfsonlinux/zfs.git $ZFSDIR

# Enter ZFS source dir, reset it in case we have any half-finished builds, and update it
(
cd $ZFSDIR
git reset --hard
git checkout "$UPSTREAMZFSVER"
git pull
)

# Configure ZFS and build/install the userspace binaries
#
# We could do this with the `native-deb` target added in OpenZFS 2.2, but that uses pre-configured
# paths for Debian and Ubuntu and the documentation does not recommend overriding it to use a kernel
# installed in a non-default location. TODO: I will see if I can sort this later.
#
# See: https://openzfs.github.io/openzfs-docs/Developer%20Resources/Building%20ZFS.html
(
cd $ZFSDIR || exit
sh autogen.sh
./configure \
  --prefix=/ \
  --libdir=/lib \
  --includedir=/usr/include \
  --datarootdir=/usr/share \
  --enable-linux-builtin=yes \
  --with-linux=$KERNELDIR \
  --with-linux-obj=$KERNELDIR
./copy-builtin $KERNELDIR
make -j "$(nproc)"
${SUDO} make install
)

(
cd $KERNELDIR

# Enable statically compiling in ZFS
echo "CONFIG_ZFS=y" >> "$KERNELDIR/$KCONFIG_CONFIG"

# Build kernel
make -j "$(nproc)"
)

# Install modules
(
cd $KERNELDIR
make -j "$(nproc)" modules
echo 'Enter sudo password to install kernel modules...'
${SUDO} make modules_install INSTALL_MOD_STRIP=1
)

# Copy our kernel to C:\ZFSonWSL\bzImage
# (We don't save it as bzImage in case we overwrite the kernel we're actually running
# so after the build process is done, the user will need to shutdown WSL and then rename
# the bzImage-new kernel to bzImage)
mkdir -p /mnt/c/ZFSonWSL
cp -fv "${KERNELDIR}/arch/x86/boot/bzImage" "/mnt/c/ZFSonWSL/bzImage-new"
mv "/mnt/c/ZFSonWSL/bzImage-new" "/mnt/c/ZFSonWSL/bzImage-${UPSTREAMKERNELVER}"
VER=$(curl -s https://api.github.com/repos/microsoft/WSL2-Linux-Kernel/releases/latest | grep -oP '"tag_name": ".+-\K(.*)(?=")')
REAL_VER=$(ls /lib/modules | grep "^${VER}" | head -n 1)
CMD="tar -czf /mnt/c/ZFSonWSL/module-${REAL_VER}.tgz -C /lib/modules ${REAL_VER}"
echo $CMD
sudo $CMD
