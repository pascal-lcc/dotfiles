# Personal Dotfiles

A modular, lightweight, and modern dev environment tailored for **Cross-Platform Linux Workflows** (WSL2 on Windows, Linux VMs, and Proxmox VE LXC Containers).

## 🚀 Key Features

- **Cross-Platform Support**: Seamlessly works across Windows WSL2, native Linux, Proxmox VE (PVE) nodes, LXC containers (CT), and virtual machines (VM).
- **Zsh Shell Environment**: Custom completion, plugins (autosuggestions, syntax-highlighting), and optimized interactive shell setup.
- **Vim / Neovim Integration**: Streamlined configurations with fast keybindings and plugin management.
- **Terminal & Multiplexer**: Configured for modern terminal setups and workflow efficiency.

## 🛠️ Quick Installation

### 1. Standard Dotfiles Installation
Clone this repository to your home directory:

```bash
git clone --recursive [https://github.com/pascal-lcc/dotfiles.git](https://github.com/pascal-lcc/dotfiles.git) ~/.dotfiles
```

### 2. ⚡PVE on WSL & ZFS Quick Deployment (Advanced)
If you want to deploy a professional-grade Proxmox VE environment with ZFS storage directly on Windows WSL2 without manually cloning the repository, run the following command in an administrator PowerShell:



```powershell
iex (irm "[https://raw.githubusercontent.com/pascal-lcc/dotfiles/main/scripts/build-wsl-zfs-pve/Install-PveZfs.ps1](https://raw.githubusercontent.com/pascal-lcc/dotfiles/main/scripts/build-wsl-zfs-pve/Install-PveZfs.ps1)")
```

