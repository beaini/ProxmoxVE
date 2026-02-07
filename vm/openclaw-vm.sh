#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: [YourGitHubUsername]
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/openclaw/openclaw

# ==============================================================================
# OpenClaw VM - Creates an OpenClaw AI Agent VM
# ==============================================================================
# OpenClaw is an AI agent with shell access. This script creates a VM with
# hypervisor isolation for security, as recommended for AI agents with shell
# access. LXC containers share the host kernel and are not suitable for this use case.
# ==============================================================================

source <(curl -fsSL https://git.community-scripts.org/community-scripts/ProxmoxVE/raw/branch/main/misc/api.func) 2>/dev/null
source <(curl -fsSL https://git.community-scripts.org/community-scripts/ProxmoxVE/raw/branch/main/misc/vm-core.func) 2>/dev/null
source <(curl -fsSL https://git.community-scripts.org/community-scripts/ProxmoxVE/raw/branch/main/misc/cloud-init.func) 2>/dev/null || true
load_functions

# ==============================================================================
# SCRIPT VARIABLES
# ==============================================================================
APP="OpenClaw"
APP_TYPE="vm"
NSAPP="openclaw-vm"
var_os="ubuntu"
var_version="24.04"

GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
ROOT_PASSWORD="$(openssl rand -base64 16 | tr -d '/+=' | head -c 16)"
METHOD=""
DISK_SIZE="32G"
USE_CLOUD_INIT="yes"  # Ubuntu requires cloud-init
OS_TYPE="ubuntu"
OS_VERSION="24.04"
OS_CODENAME="noble"
OS_DISPLAY="Ubuntu 24.04 LTS"
THIN="discard=on,ssd=1,"
DIAGNOSTICS="${DIAGNOSTICS:-no}"  # Initialize to prevent unbound variable errors

# ==============================================================================
# ERROR HANDLING & CLEANUP
# ==============================================================================
set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'post_update_to_api "failed" "INTERRUPTED"' SIGINT
trap 'post_update_to_api "failed" "TERMINATED"' SIGTERM

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  post_update_to_api "failed" "${command}"
  echo -e "\n$error_message\n"
  cleanup_vmid
}

function get_image_url() {
  local arch=$(dpkg --print-architecture)
  echo "https://cloud-images.ubuntu.com/${OS_CODENAME}/current/${OS_CODENAME}-server-cloudimg-${arch}.img"
}

# ==============================================================================
# SETTINGS FUNCTIONS
# ==============================================================================
function default_settings() {
  VMID=$(get_valid_nextid)
  FORMAT=""
  MACHINE=" -machine q35"
  DISK_CACHE=""
  DISK_SIZE="32G"
  HN="openclaw"
  CPU_TYPE=" -cpu host"
  CORE_COUNT="2"
  RAM_SIZE="4096"
  BRG="vmbr0"
  MAC="$GEN_MAC"
  VLAN=""
  MTU=""
  START_VM="yes"
  METHOD="default"
  BALLOON="0"  # Disable memory ballooning for OpenClaw

  echo -e "${CONTAINERID}${BOLD}${DGN}Virtual Machine ID: ${BGN}${VMID}${CL}"
  echo -e "${CONTAINERTYPE}${BOLD}${DGN}Machine Type: ${BGN}Q35 (Modern)${CL}"
  echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}${DISK_SIZE}${CL}"
  echo -e "${DISKSIZE}${BOLD}${DGN}Disk Cache: ${BGN}None${CL}"
  echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}${HN}${CL}"
  echo -e "${OS}${BOLD}${DGN}CPU Model: ${BGN}Host${CL}"
  echo -e "${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}${CORE_COUNT}${CL}"
  echo -e "${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}${RAM_SIZE} (Ballooning: Disabled)${CL}"
  echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}${BRG}${CL}"
  echo -e "${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}${MAC}${CL}"
  echo -e "${VLANTAG}${BOLD}${DGN}VLAN: ${BGN}Default${CL}"
  echo -e "${DEFAULT}${BOLD}${DGN}Interface MTU Size: ${BGN}Default${CL}"
  echo -e "${GATEWAY}${BOLD}${DGN}Start VM when completed: ${BGN}yes${CL}"
  echo -e "${CREATING}${BOLD}${DGN}Creating an OpenClaw VM using the above settings${CL}"
}

function advanced_settings() {
  METHOD="advanced"
  configure_cloudinit_ssh_keys || true
  
  [ -z "${VMID:-}" ] && VMID=$(get_valid_nextid)

  # VM ID
  while true; do
    if VMID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Virtual Machine ID" 8 58 $VMID --title "VIRTUAL MACHINE ID" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      if [ -z "$VMID" ]; then
        VMID=$(get_valid_nextid)
      fi
      if pct status "$VMID" &>/dev/null || qm status "$VMID" &>/dev/null; then
        echo -e "${CROSS}${RD} ID $VMID is already in use${CL}"
        sleep 2
        continue
      fi
      echo -e "${CONTAINERID}${BOLD}${DGN}Virtual Machine ID: ${BGN}$VMID${CL}"
      break
    else
      exit_script
    fi
  done

  # Machine Type (force Q35 for OpenClaw)
  MACHINE=" -machine q35"
  FORMAT=""
  echo -e "${CONTAINERTYPE}${BOLD}${DGN}Machine Type: ${BGN}Q35 (Required for OpenClaw)${CL}"

  # Disk Size
  if DISK_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Disk Size in GiB (minimum 32)" 8 58 "32" --title "DISK SIZE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    DISK_SIZE=$(echo "$DISK_SIZE" | tr -d ' ')
    if [[ "$DISK_SIZE" =~ ^[0-9]+$ ]]; then
      if [ "$DISK_SIZE" -lt 32 ]; then
        DISK_SIZE="32"
      fi
      DISK_SIZE="${DISK_SIZE}G"
      echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}$DISK_SIZE${CL}"
    elif [[ "$DISK_SIZE" =~ ^[0-9]+G$ ]]; then
      echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}$DISK_SIZE${CL}"
    else
      echo -e "${DISKSIZE}${BOLD}${RD}Invalid Disk Size. Using default 32G.${CL}"
      DISK_SIZE="32G"
    fi
  else
    exit_script
  fi

  # Disk Cache
  DISK_CACHE=""
  echo -e "${DISKSIZE}${BOLD}${DGN}Disk Cache: ${BGN}None${CL}"

  # Hostname
  if VM_NAME=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Hostname" 8 58 openclaw --title "HOSTNAME" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $VM_NAME ]; then
      HN="openclaw"
      echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}$HN${CL}"
    else
      HN=$(echo ${VM_NAME,,} | tr -d ' ')
      echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}$HN${CL}"
    fi
  else
    exit_script
  fi

  # CPU Type (force Host for OpenClaw)
  CPU_TYPE=" -cpu host"
  echo -e "${OS}${BOLD}${DGN}CPU Model: ${BGN}Host (Required for OpenClaw)${CL}"

  # CPU Cores
  if CORE_COUNT=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate CPU Cores (minimum 2)" 8 58 2 --title "CORE COUNT" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $CORE_COUNT ]; then
      CORE_COUNT="2"
    elif [ "$CORE_COUNT" -lt 2 ]; then
      CORE_COUNT="2"
    fi
    echo -e "${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}$CORE_COUNT${CL}"
  else
    exit_script
  fi

  # RAM Size
  if RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate RAM in MiB (minimum 4096)" 8 58 4096 --title "RAM" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $RAM_SIZE ]; then
      RAM_SIZE="4096"
    elif [ "$RAM_SIZE" -lt 4096 ]; then
      RAM_SIZE="4096"
    fi
    echo -e "${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}$RAM_SIZE (Ballooning: Disabled)${CL}"
  else
    exit_script
  fi
  
  BALLOON="0"  # Disable memory ballooning

  # Network Bridge
  if BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a Bridge" 8 58 vmbr0 --title "BRIDGE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $BRG ]; then
      BRG="vmbr0"
    fi
    echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}$BRG${CL}"
  else
    exit_script
  fi

  # MAC Address
  if MAC1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a MAC Address" 8 58 $GEN_MAC --title "MAC ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $MAC1 ]; then
      MAC="$GEN_MAC"
    else
      MAC="$MAC1"
    fi
    echo -e "${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}$MAC${CL}"
  else
    exit_script
  fi

  # VLAN
  if VLAN1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a Vlan(leave blank for default)" 8 58 --title "VLAN" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $VLAN1 ]; then
      VLAN1="Default"
      VLAN=""
    else
      VLAN=",tag=$VLAN1"
    fi
    echo -e "${VLANTAG}${BOLD}${DGN}VLAN: ${BGN}$VLAN1${CL}"
  else
    exit_script
  fi

  # MTU
  if MTU1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Interface MTU Size (leave blank for default)" 8 58 --title "MTU SIZE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $MTU1 ]; then
      MTU1="Default"
      MTU=""
    else
      MTU=",mtu=$MTU1"
    fi
    echo -e "${DEFAULT}${BOLD}${DGN}Interface MTU Size: ${BGN}$MTU1${CL}"
  else
    exit_script
  fi

  # Start VM
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "START VIRTUAL MACHINE" --yesno "Start VM when completed?" 10 58); then
    echo -e "${GATEWAY}${BOLD}${DGN}Start VM when completed: ${BGN}yes${CL}"
    START_VM="yes"
  else
    echo -e "${GATEWAY}${BOLD}${DGN}Start VM when completed: ${BGN}no${CL}"
    START_VM="no"
  fi

  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "ADVANCED SETTINGS COMPLETE" --yesno "Ready to create an OpenClaw VM?" --no-button Do-Over 10 58); then
    echo -e "${CREATING}${BOLD}${DGN}Creating an OpenClaw VM using the above settings${CL}"
  else
    header_info
    echo -e "${ADVANCED}${BOLD}${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}

function start_script() {
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "SETTINGS" --yesno "Use Default Settings?" --no-button Advanced 10 58); then
    header_info
    echo -e "${DEFAULT}${BOLD}${BL}Using Default Settings${CL}"
    default_settings
  else
    header_info
    echo -e "${ADVANCED}${BOLD}${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================
function header_info {
  clear
  cat <<"EOF"
   ____                   ________
  / __ \____  ___  ____  / ____/ /___ __      __
 / / / / __ \/ _ \/ __ \/ /   / / __ `/ | /| / /
/ /_/ / /_/ /  __/ / / / /___/ / /_/ /| |/ |/ /
\____/ .___/\___/_/ /_/\____/_/\__,_/ |__/|__/
    /_/           AI Agent VM
EOF
}

header_info
echo -e "\n Loading..."

if whiptail --backtitle "Proxmox VE Helper Scripts" --title "OpenClaw VM" --yesno "This will create a new OpenClaw AI Agent VM with hypervisor isolation.\n\nOpenClaw has shell access and runs with elevated privileges.\nVM isolation provides security from the Proxmox host.\n\nProceed?" 12 68; then
  :
else
  header_info && echo -e "${CROSS}${RD}User exited script${CL}\n" && exit
fi

check_root
arch_check
pve_check
start_script
post_to_api_vm

# ==============================================================================
# STORAGE SELECTION
# ==============================================================================
msg_info "Validating Storage"
while read -r line; do
  TAG=$(echo $line | awk '{print $1}')
  TYPE=$(echo $line | awk '{printf "%-10s", $2}')
  FREE=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
  ITEM="  Type: $TYPE Free: $FREE "
  OFFSET=2
  if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
    MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
  fi
  STORAGE_MENU+=("$TAG" "$ITEM" "OFF")
done < <(pvesm status -content images | awk 'NR>1')

VALID=$(pvesm status -content images | awk 'NR>1')
if [ -z "$VALID" ]; then
  msg_error "Unable to detect a valid storage location."
  exit
elif [ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]; then
  STORAGE=${STORAGE_MENU[0]}
else
  if [ -n "$SPINNER_PID" ] && ps -p $SPINNER_PID >/dev/null; then kill $SPINNER_PID >/dev/null; fi
  printf "\e[?25h"
  while [ -z "${STORAGE:+x}" ]; do
    STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Storage Pools" --radiolist \
      "Which storage pool would you like to use for ${HN}?\nTo make a selection, use the Spacebar.\n" \
      16 $(($MSG_MAX_LENGTH + 23)) 6 \
      "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3)
  done
fi
msg_ok "Using ${CL}${BL}$STORAGE${CL} ${GN}for Storage Location."
msg_ok "Virtual Machine ID is ${CL}${BL}$VMID${CL}."

# ==============================================================================
# PREREQUISITES
# ==============================================================================
if ! command -v virt-customize &>/dev/null; then
  msg_info "Installing libguestfs-tools"
  apt-get -qq update >/dev/null
  apt-get -qq install libguestfs-tools lsb-release -y >/dev/null
  apt-get -qq install dhcpcd-base -y >/dev/null 2>&1 || true
  msg_ok "Installed libguestfs-tools"
fi

# ==============================================================================
# IMAGE DOWNLOAD
# ==============================================================================
msg_info "Retrieving the URL for the ${OS_DISPLAY} Cloud Image"
URL=$(get_image_url)
CACHE_DIR="/var/lib/vz/template/cache"
CACHE_FILE="$CACHE_DIR/$(basename "$URL")"
mkdir -p "$CACHE_DIR"
msg_ok "${CL}${BL}${URL}${CL}"

if [[ ! -s "$CACHE_FILE" ]]; then
  curl -f#SL -o "$CACHE_FILE" "$URL"
  echo -en "\e[1A\e[0K"
  msg_ok "Downloaded ${CL}${BL}$(basename "$CACHE_FILE")${CL}"
else
  msg_ok "Using cached image ${CL}${BL}$(basename "$CACHE_FILE")${CL}"
fi

# ==============================================================================
# STORAGE TYPE DETECTION
# ==============================================================================
STORAGE_TYPE=$(pvesm status -storage "$STORAGE" | awk 'NR>1 {print $2}')
case $STORAGE_TYPE in
nfs | dir)
  DISK_EXT=".qcow2"
  DISK_REF="$VMID/"
  DISK_IMPORT="--format qcow2"
  THIN=""
  ;;
btrfs)
  DISK_EXT=".raw"
  DISK_REF="$VMID/"
  DISK_IMPORT="--format raw"
  FORMAT=",efitype=4m"
  THIN=""
  ;;
*)
  DISK_EXT=""
  DISK_REF=""
  DISK_IMPORT="--format raw"
  ;;
esac

# ==============================================================================
# IMAGE CUSTOMIZATION WITH OPENCLAW
# ==============================================================================
msg_info "Preparing ${OS_DISPLAY} image with OpenClaw"

WORK_FILE=$(mktemp --suffix=.qcow2)
cp "$CACHE_FILE" "$WORK_FILE"

export LIBGUESTFS_BACKEND_SETTINGS=dns=8.8.8.8,1.1.1.1

# Install base packages
msg_info "Installing base packages and dependencies"
virt-customize -q -a "$WORK_FILE" --install qemu-guest-agent,curl,git,build-essential,ca-certificates,gnupg || {
  msg_error "Failed to install base packages"
  exit 1
}
# Clean apt cache to free space in the small cloud image filesystem
virt-customize -q -a "$WORK_FILE" --run-command "apt-get clean && rm -rf /var/lib/apt/lists/*" || true
msg_ok "Installed base packages"

# Add swap fstab entry (swap file will be created on first boot after disk resize)
msg_info "Configuring swap fstab entry"
virt-customize -q -a "$WORK_FILE" --run-command "echo '/swapfile none swap sw 0 0' >> /etc/fstab" || {
  msg_error "Failed to add swap to fstab"
  exit 1
}
msg_ok "Configured swap fstab entry"

# Create openclaw user
msg_info "Creating dedicated OpenClaw user"
virt-customize -q -a "$WORK_FILE" --run-command "adduser --disabled-password --gecos '' openclaw" || {
  msg_error "Failed to create openclaw user"
  exit 1
}
virt-customize -q -a "$WORK_FILE" --run-command "usermod -aG sudo openclaw" || {
  msg_error "Failed to add openclaw to sudo group"
  exit 1
}
virt-customize -q -a "$WORK_FILE" --run-command "echo 'openclaw ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/openclaw" || {
  msg_error "Failed to create sudoers file"
  exit 1
}
virt-customize -q -a "$WORK_FILE" --run-command "chmod 0440 /etc/sudoers.d/openclaw" || {
  msg_error "Failed to set sudoers permissions"
  exit 1
}
msg_ok "Created OpenClaw user"

# Create first-boot installation script
msg_info "Creating first-boot OpenClaw installation script"
virt-customize -q -a "$WORK_FILE" --run-command 'cat > /root/install-openclaw.sh << '\''EOINSTALL'\''
#!/bin/bash
set -euo pipefail

# Log to file but show errors
exec > >(tee /var/log/openclaw-install.log) 2>&1

echo "[$(date)] Starting OpenClaw installation"

# Create 2GB swap file (disk is now resized, so we have space)
echo "[$(date)] Creating 2GB swap file..."
fallocate -l 2G /swapfile || {
  echo "[$(date)] ERROR: Failed to create swap file" >&2
  exit 1
}
chmod 600 /swapfile || {
  echo "[$(date)] ERROR: Failed to set swap permissions" >&2
  exit 1
}
mkswap /swapfile || {
  echo "[$(date)] ERROR: Failed to format swap" >&2
  exit 1
}
swapon /swapfile || {
  echo "[$(date)] ERROR: Failed to activate swap" >&2
  exit 1
}
echo "[$(date)] Swap file created and activated"

# Verify network connectivity (fail immediately if no network)
if ! curl -s --connect-timeout 5 https://registry.npmjs.org > /dev/null; then
  echo "[$(date)] ERROR: No network connectivity" >&2
  exit 1
fi
echo "[$(date)] Network connectivity verified"

# Setup NodeSource repository and install Node.js 24 (disk is now resized, so we have space)
echo "[$(date)] Setting up NodeSource repository..."
curl -fsSL https://deb.nodesource.com/setup_24.x | bash - || {
  echo "[$(date)] ERROR: Failed to setup NodeSource repository" >&2
  exit 1
}
echo "[$(date)] Installing Node.js 24..."
apt-get install -y nodejs || {
  echo "[$(date)] ERROR: Failed to install Node.js" >&2
  exit 1
}
# Clean apt cache to free disk space before npm install
apt-get clean
rm -rf /var/lib/apt/lists/*
if ! command -v node &>/dev/null; then
  echo "[$(date)] ERROR: Node.js installation failed - command not found" >&2
  exit 1
fi
echo "[$(date)] Node.js installed: $(node --version)"

# Install OpenClaw via npm
echo "[$(date)] Installing OpenClaw from npm..."
npm install -g openclaw@latest
if ! command -v openclaw &>/dev/null; then
  echo "[$(date)] ERROR: OpenClaw installation failed - command not found" >&2
  exit 1
fi
echo "[$(date)] OpenClaw installed: $(openclaw --version)"

# Enable lingering for openclaw user (requires systemd-logind)
echo "[$(date)] Enabling systemd lingering for openclaw user..."
loginctl enable-linger openclaw
echo "[$(date)] Lingering enabled"

# Install OpenClaw daemon as user service
echo "[$(date)] Installing OpenClaw daemon service..."
su - openclaw -c '\''export XDG_RUNTIME_DIR=/run/user/$(id -u) && openclaw daemon install'\''
if ! su - openclaw -c '\''systemctl --user list-unit-files openclaw-gateway.service'\'' &>/dev/null; then
  echo "[$(date)] ERROR: OpenClaw service installation failed" >&2
  exit 1
fi
echo "[$(date)] OpenClaw daemon service installed"

# Note: Service is NOT started automatically - user must run openclaw onboard first
echo "[$(date)] OpenClaw installation completed successfully"
echo "[$(date)] User must run: sudo -u openclaw openclaw onboard"

touch /root/.openclaw-installed
EOINSTALL' || {
  msg_error "Failed to create first-boot installation script"
  exit 1
}

virt-customize -q -a "$WORK_FILE" --run-command "chmod +x /root/install-openclaw.sh" || {
  msg_error "Failed to set script permissions"
  exit 1
}
msg_ok "Created first-boot installation script"

# Create systemd unit for first-boot installation
msg_info "Creating first-boot systemd unit"
virt-customize -q -a "$WORK_FILE" --run-command 'cat > /etc/systemd/system/install-openclaw.service << '\''EOSERVICE'\''
[Unit]
Description=Install OpenClaw on First Boot
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/root/.openclaw-installed

[Service]
Type=oneshot
ExecStart=/root/install-openclaw.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOSERVICE' || {
  msg_error "Failed to create systemd unit"
  exit 1
}

virt-customize -q -a "$WORK_FILE" --run-command "systemctl enable install-openclaw.service" || {
  msg_error "Failed to enable first-boot service"
  exit 1
}
msg_ok "Created and enabled first-boot systemd unit"

# Create setup instructions
msg_info "Creating setup instructions"
virt-customize -q -a "$WORK_FILE" --run-command 'cat > /home/openclaw/SETUP_INSTRUCTIONS.txt << '\''EOINSTRUCTIONS'\''
================================================================================
                        OpenClaw Setup Instructions
================================================================================

OpenClaw will be installed automatically on first boot via a systemd service.
You can check the installation log at: /var/log/openclaw-install.log

IMPORTANT: You MUST run the onboarding wizard before OpenClaw will work.

================================================================================
FIRST STEP - RUN ONBOARDING (REQUIRED)
================================================================================

After the VM boots and OpenClaw installs, run the onboarding wizard:

    sudo -u openclaw openclaw onboard

The wizard will guide you through:
  • Choosing your AI provider (OpenAI, Anthropic, Google, etc.)
  • Entering your API key
  • Selecting gateway mode (choose: Local)
  • Setting bind address (choose: Loopback 127.0.0.1)
  • Configuring channels (Telegram, voice, web)
  • Selecting runtime (choose: Node)

This creates the configuration and starts the service.

================================================================================
TELEGRAM BOT SETUP (RECOMMENDED)
================================================================================

1. Create a Telegram Bot:
   • Open Telegram and search for @BotFather
   • Send: /newbot
   • Choose a display name and username (must end in "bot")
   • Save the bot token
   • Send: /setprivacy -> Select your bot -> Disable

2. Get Your Telegram User ID:
   • Message @userinfobot to get your Telegram user ID

3. The onboarding wizard will ask for your Telegram bot token.
   You can also configure it later:

    sudo -u openclaw openclaw configure --section channels

4. After configuration, restart the service:

    sudo -u openclaw systemctl --user restart openclaw-gateway

================================================================================
PAIRING YOUR TELEGRAM ACCOUNT
================================================================================

1. Send any message to your bot in Telegram
   You'\''ll receive a pairing code

2. Approve the pairing on the server:

    sudo -u openclaw openclaw pairing list telegram
    sudo -u openclaw openclaw pairing approve telegram <CODE>

3. Send another message - OpenClaw should now respond!

================================================================================
SECURITY AUDIT (RECOMMENDED)
================================================================================

After setup, run the built-in security audit:

    sudo -u openclaw openclaw security audit --deep
    sudo -u openclaw openclaw security audit --fix

================================================================================
USEFUL COMMANDS
================================================================================

Check Installation Status:
  systemctl status install-openclaw.service
  cat /var/log/openclaw-install.log

Service Management:
  sudo -u openclaw systemctl --user status openclaw-gateway
  sudo -u openclaw systemctl --user start openclaw-gateway
  sudo -u openclaw systemctl --user stop openclaw-gateway
  sudo -u openclaw systemctl --user restart openclaw-gateway
  sudo -u openclaw journalctl --user -u openclaw-gateway -f

OpenClaw Commands:
  sudo -u openclaw openclaw status
  sudo -u openclaw openclaw doctor
  sudo -u openclaw openclaw logs --follow
  sudo -u openclaw openclaw pairing list telegram
  sudo -u openclaw openclaw security audit --deep

Configuration:
  Config file: /home/openclaw/.openclaw/openclaw.json (created by onboard)
  Data directory: /home/openclaw/.openclaw/

================================================================================
TROUBLESHOOTING
================================================================================

Installation Failed:
  • Check: cat /var/log/openclaw-install.log
  • Verify network: curl -I https://registry.npmjs.org
  • Manual install: sudo /root/install-openclaw.sh

Service Not Starting:
  • Run onboarding first: sudo -u openclaw openclaw onboard
  • Check service: sudo -u openclaw systemctl --user status openclaw-gateway
  • Verify config: sudo -u openclaw openclaw doctor

================================================================================
SECURITY NOTES
================================================================================

• OpenClaw runs with sudo access within this VM
• Security is provided by hypervisor isolation from the Proxmox host
• The gateway binds to 127.0.0.1 (NOT exposed to network)
• All communication with Telegram is outgoing (polling-based)
• Regular security audits are recommended

For more information, visit: https://github.com/openclaw/openclaw

================================================================================
EOINSTRUCTIONS' || {
  msg_error "Failed to create setup instructions"
  exit 1
}

virt-customize -q -a "$WORK_FILE" --run-command "chown openclaw:openclaw /home/openclaw/SETUP_INSTRUCTIONS.txt" || {
  msg_error "Failed to set instructions ownership"
  exit 1
}
virt-customize -q -a "$WORK_FILE" --run-command "chmod 644 /home/openclaw/SETUP_INSTRUCTIONS.txt" || {
  msg_error "Failed to set instructions permissions"
  exit 1
}
msg_ok "Created setup instructions"

# Finalize image
msg_info "Finalizing image (hostname, SSH config)"
virt-customize -q -a "$WORK_FILE" --hostname "${HN}" || {
  msg_error "Failed to set hostname"
  exit 1
}
virt-customize -q -a "$WORK_FILE" --run-command "truncate -s 0 /etc/machine-id" || {
  msg_error "Failed to clear machine-id"
  exit 1
}
virt-customize -q -a "$WORK_FILE" --run-command "rm -f /var/lib/dbus/machine-id" || {
  msg_error "Failed to remove dbus machine-id"
  exit 1
}

# Configure SSH for Cloud-Init
virt-customize -q -a "$WORK_FILE" --run-command "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config" || {
  msg_error "Failed to configure SSH PermitRootLogin"
  exit 1
}
virt-customize -q -a "$WORK_FILE" --run-command "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config" || {
  msg_error "Failed to configure SSH PasswordAuthentication"
  exit 1
}
msg_ok "Finalized image"

# Resize disk to target size
msg_info "Resizing disk image to ${DISK_SIZE}"
qemu-img resize "$WORK_FILE" "${DISK_SIZE}" >/dev/null 2>&1
msg_ok "Resized disk image"

# ==============================================================================
# VM CREATION
# ==============================================================================
msg_info "Creating OpenClaw VM shell"

qm create $VMID -agent 1${MACHINE} -tablet 0 -localtime 1 -bios ovmf${CPU_TYPE} -cores $CORE_COUNT -memory $RAM_SIZE -balloon $BALLOON \
  -name $HN -tags community-script -net0 virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU -onboot 1 -ostype l26 -scsihw virtio-scsi-pci >/dev/null

msg_ok "Created VM shell"

# ==============================================================================
# DISK IMPORT
# ==============================================================================
msg_info "Importing disk into storage ($STORAGE)"

if qm disk import --help >/dev/null 2>&1; then
  IMPORT_CMD=(qm disk import)
else
  IMPORT_CMD=(qm importdisk)
fi

IMPORT_OUT="$("${IMPORT_CMD[@]}" "$VMID" "$WORK_FILE" "$STORAGE" ${DISK_IMPORT:-} 2>&1 || true)"
DISK_REF_IMPORTED="$(printf '%s\n' "$IMPORT_OUT" | sed -n "s/.*successfully imported disk '\([^']\+\)'.*/\1/p" | tr -d "\r\"'")"
[[ -z "$DISK_REF_IMPORTED" ]] && DISK_REF_IMPORTED="$(pvesm list "$STORAGE" | awk -v id="$VMID" '$5 ~ ("vm-"id"-disk-") {print $1":"$5}' | sort | tail -n1)"
[[ -z "$DISK_REF_IMPORTED" ]] && {
  msg_error "Unable to determine imported disk reference."
  echo "$IMPORT_OUT"
  exit 1
}

msg_ok "Imported disk (${CL}${BL}${DISK_REF_IMPORTED}${CL})"

# Clean up work file
rm -f "$WORK_FILE"

# ==============================================================================
# VM CONFIGURATION
# ==============================================================================
msg_info "Attaching EFI and root disk"

qm set "$VMID" \
  --efidisk0 ${STORAGE}:0,efitype=4m \
  --scsi0 ${DISK_REF_IMPORTED},${DISK_CACHE}${THIN%,} \
  --boot order=scsi0 \
  --serial0 socket >/dev/null

qm set "$VMID" --agent enabled=1 >/dev/null
msg_ok "Attached EFI and root disk"

# ==============================================================================
# CLOUD-INIT CONFIGURATION
# ==============================================================================
if [ "$USE_CLOUD_INIT" = "yes" ]; then
  msg_info "Configuring Cloud-Init"
  qm set "$VMID" --ide2 ${STORAGE}:cloudinit >/dev/null
  
  # Set root user with auto-generated password
  qm set "$VMID" --ciuser "root" --cipassword "${ROOT_PASSWORD}" >/dev/null
  
  # Also add SSH keys if configured in advanced mode
  if [ -n "${CLOUDINIT_CONFIG_SSH_KEYS:-}" ]; then
    qm set "$VMID" --sshkeys "${CLOUDINIT_CONFIG_SSH_KEYS}" >/dev/null
  fi
  
  qm set "$VMID" --ipconfig0 ip=dhcp >/dev/null
  msg_ok "Configured Cloud-Init with auto-generated password"
fi

# ==============================================================================
# VM DESCRIPTION
# ==============================================================================
DESCRIPTION=$(
  cat <<EOF
<div align='center'>
  <a href='https://Helper-Scripts.com' target='_blank' rel='noopener noreferrer'>
    <img src='https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/images/logo-81x112.png' alt='Logo' style='width:81px;height:112px;'/>
  </a>

  <h2 style='font-size: 24px; margin: 20px 0;'>OpenClaw AI Agent VM</h2>

  <p style='margin: 16px 0;'>
    <a href='https://ko-fi.com/community_scripts' target='_blank' rel='noopener noreferrer'>
      <img src='https://img.shields.io/badge/&#x2615;-Buy us a coffee-blue' alt='Sponsor' />
    </a>
  </p>
  
  <span style='margin: 0 10px;'>
    <i class="fa fa-github fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/community-scripts/ProxmoxVE' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>GitHub</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class="fa fa-comments fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/community-scripts/ProxmoxVE/discussions' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Discussions</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class="fa fa-exclamation-circle fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/community-scripts/ProxmoxVE/issues' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Issues</a>
  </span>
</div>
EOF
)
qm set "$VMID" -description "$DESCRIPTION" >/dev/null
msg_ok "Created OpenClaw VM ${CL}${BL}(${HN})"

# ==============================================================================
# CACHE MANAGEMENT
# ==============================================================================
if whiptail --backtitle "Proxmox VE Helper Scripts" --title "Image Cache" \
  --yesno "Keep downloaded Ubuntu image for future VMs?\n\nFile: $CACHE_FILE" 10 70; then
  msg_ok "Keeping cached image"
else
  rm -f "$CACHE_FILE"
  msg_ok "Deleted cached image"
fi

# ==============================================================================
# START VM
# ==============================================================================
if [ "$START_VM" == "yes" ]; then
  msg_info "Starting OpenClaw VM"
  qm start $VMID
  msg_ok "Started OpenClaw VM"
fi

post_update_to_api "done" "none"
msg_ok "Completed successfully!\n"

echo -e "${INFO}${YW}===================================================================================${CL}"
echo -e "${INFO}${YW}                     OpenClaw VM Setup Complete${CL}"
echo -e "${INFO}${YW}===================================================================================${CL}"
echo -e ""
echo -e "${INFO}${GN}VM Configuration:${CL}"
echo -e "${TAB}• Machine: Q35 with UEFI"
echo -e "${TAB}• CPU: Host type (passthrough)"
echo -e "${TAB}• Memory: ${RAM_SIZE}MB (Ballooning disabled)"
echo -e "${TAB}• Disk: ${DISK_SIZE}"
echo -e "${TAB}• Gateway: 127.0.0.1:18789 (loopback only)"
echo -e ""
echo -e "${INFO}${RD}${BOLD}SSH Login Credentials (SAVE THESE!):${CL}"
echo -e "${TAB}${BOLD}Username: ${BGN}root${CL}"
echo -e "${TAB}${BOLD}Password: ${BGN}${ROOT_PASSWORD}${CL}"
echo -e ""
echo -e "${INFO}${YW}Next Steps:${CL}"
echo -e "${TAB}${GN}1.${CL} Wait for VM to boot and get IP address from Proxmox console"
echo -e "${TAB}${GN}2.${CL} SSH into the VM: ${YW}ssh root@<VM-IP>${CL}"
echo -e "${TAB}${GN}3.${CL} Read setup instructions: ${YW}cat /home/openclaw/SETUP_INSTRUCTIONS.txt${CL}"
echo -e "${TAB}${GN}4.${CL} Configure AI provider: ${YW}sudo -u openclaw openclaw onboard${CL}"
echo -e "${TAB}${GN}5.${CL} Setup Telegram bot and pair your account"
echo -e "${TAB}${GN}6.${CL} Run security audit: ${YW}sudo -u openclaw openclaw security audit --deep${CL}"
echo -e ""
echo -e "${INFO}${YW}Security Note:${CL}"
echo -e "${TAB}OpenClaw has shell access and sudo privileges within the VM."
echo -e "${TAB}Hypervisor isolation protects your Proxmox host."
echo -e ""
