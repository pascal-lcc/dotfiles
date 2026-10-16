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
git clone --recursive https://github.com/pascal-lcc/dotfiles.git ~/.dotfiles
```

### 2. ⚡PVE on WSL & ZFS Quick Deployment (Advanced)
If you want to deploy a professional-grade Proxmox VE environment with ZFS storage directly on Windows WSL2 without manually cloning the repository, run the following command in an PowerShell:

```powershell
iex (irm "https://raw.githubusercontent.com/pascal-lcc/dotfiles/main/scripts/build-wsl-zfs-pve/Install-PveZfs.ps1")
```

### 3. 🚀 Windows 11 Dotfiles Quick Setup (No Git Required)
If you are on a fresh Windows 11 machine without Git pre-installed, you can quickly download, extract, and deploy these dotfiles using a single PowerShell command:

```powershell
iex (irm "https://raw.githubusercontent.com/pascal-lcc/dotfiles/main/scripts/setup-dotfiles.ps1")
```

### 4. 🐧 Linux Dotfiles Quick Setup (No Git Required)
If you are on a fresh Linux machine or a minimal server without Git pre-installed, you can automatically install dependencies, download the dotfiles with all submodules, clean up git traces, and deploy everything using a single shell command:

```shell
bash <(curl -s https://raw.githubusercontent.com/pascal-lcc/dotfiles/main/scripts/setup-dotfiles.sh)
```

### 5. 🔄 Update WSL PVE & ZFS Kernel (Advanced)
If you already have your PVE WSL environment set up and want to check, download, and update to the latest custom ZFS-enabled Linux kernel and modules, run the following command in an PowerShell:

```powershell
$scriptPath = "$env:TEMP\Update-PveZfsWslKernel.ps1"; Invoke-RestMethod -Uri "https://raw.githubusercontent.com/pascal-lcc/dotfiles/main/scripts/build-wsl-zfs-pve/Update-PveZfsWslKernel.ps1" -OutFile $scriptPath; & $scriptPath; Remove-Item $scriptPath -Force
```
