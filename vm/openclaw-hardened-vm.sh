#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: [YourGitHubUsername]
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/openclaw/openclaw

# ==============================================================================
# OpenClaw Hardened VM - Creates an OpenClaw AI Agent VM via openclaw-ansible
# ==============================================================================
# Uses the official openclaw-ansible installer for a hardened deployment with:
#   - UFW firewall, Fail2ban, unattended-upgrades
#   - Tailscale VPN for secure remote access
#   - Docker CE for sandbox isolation
#   - Node.js + pnpm + OpenClaw
#   - Systemd hardening (NoNewPrivileges, PrivateTmp, ProtectSystem)
#
# Source: https://github.com/openclaw/openclaw-ansible
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
NSAPP="openclaw-hardened-vm"
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
  echo -e "${CREATING}${BOLD}${DGN}Creating a Hardened OpenClaw VM using the above settings${CL}"
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

  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "ADVANCED SETTINGS COMPLETE" --yesno "Ready to create a Hardened OpenClaw VM?" --no-button Do-Over 10 58); then
    echo -e "${CREATING}${BOLD}${DGN}Creating a Hardened OpenClaw VM using the above settings${CL}"
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
    /_/       Hardened AI Agent VM
EOF
}

header_info
echo -e "\n Loading..."

if whiptail --backtitle "Proxmox VE Helper Scripts" --title "OpenClaw Hardened VM" --yesno "This will create a Hardened OpenClaw AI Agent VM.\n\nUses openclaw-ansible for security hardening:\n  - UFW firewall + Fail2ban\n  - Tailscale VPN\n  - Docker isolation\n  - Automatic security updates\n\nInstallation takes ~10-15 minutes on first boot.\n\nProceed?" 16 68; then
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
# IMAGE CUSTOMIZATION
# ==============================================================================
msg_info "Preparing ${OS_DISPLAY} image"

WORK_FILE=$(mktemp --suffix=.qcow2)
cp "$CACHE_FILE" "$WORK_FILE"

export LIBGUESTFS_BACKEND_SETTINGS=dns=8.8.8.8,1.1.1.1

# Install minimal base packages (ansible installer handles the rest)
msg_info "Installing base packages"
virt-customize -q -a "$WORK_FILE" --install qemu-guest-agent,curl,git,ca-certificates,gnupg || {
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

# ==============================================================================
# FIRST-BOOT SCRIPT (uses openclaw-ansible)
# ==============================================================================
msg_info "Creating first-boot installation script (openclaw-ansible)"

# Create script in temporary file to avoid command line length limits
INSTALL_SCRIPT=$(mktemp)
cat > "$INSTALL_SCRIPT" << 'EOINSTALL'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export HOME=/root
export USER=root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Log to file
exec > >(tee /var/log/openclaw-install.log) 2>&1

log() { echo "[$(date)] $1"; }
fail() { echo "[$(date)] ERROR: $1" >&2; exit 1; }

log "Starting OpenClaw Hardened installation (via openclaw-ansible)"

# Create 2GB swap file (disk is now resized, so we have space)
# The fstab entry is pre-configured, so systemd may have already activated swap.
if swapon --show | grep -q '/swapfile'; then
  log "Swap file already active (mounted via fstab)"
else
  log "Creating 2GB swap file..."
  swapoff /swapfile 2>/dev/null || true
  fallocate -l 2G /swapfile || fail "Failed to create swap file"
  chmod 600 /swapfile || fail "Failed to set swap permissions"
  mkswap /swapfile >/dev/null || fail "Failed to format swap"
  swapon /swapfile || fail "Failed to activate swap"
  log "Swap file created and activated"
fi

# Sync system clock (critical for apt repository validation)
log "Syncing system clock..."
systemctl restart systemd-timesyncd
timedatectl set-ntp true
sleep 2
log "System time after sync: $(date)"

# Verify network connectivity
if ! curl -s --connect-timeout 10 https://github.com > /dev/null; then
  fail "No network connectivity to github.com"
fi
log "Network connectivity verified"

# --------------------------------------------------------------------------
# The upstream openclaw-ansible installer is designed to run as root
# (using -e ansible_become=false). However, its Homebrew task refuses root.
# Strategy: pre-install Homebrew as a non-root user, then run the full
# installer as root. The playbook's Homebrew task checks for the binary
# and skips if it already exists.
# --------------------------------------------------------------------------

# Create clawdbot user (the ansible playbook also creates this user,
# but we need it now to install Homebrew before the playbook runs)
log "Creating clawdbot user..."
if ! id clawdbot &>/dev/null; then
  useradd -m -s /bin/bash clawdbot || fail "Failed to create clawdbot user"
fi
log "clawdbot user created"

# Wait for any automatic apt processes (unattended-upgrades, apt-daily) to finish.
# Ubuntu cloud images run these on first boot and hold the dpkg lock.
log "Waiting for apt locks to be released..."
LOCK_WAIT=0
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
  if [ $LOCK_WAIT -eq 0 ]; then
    log "Another apt process is running (likely unattended-upgrades), waiting..."
  fi
  LOCK_WAIT=$((LOCK_WAIT + 1))
  if [ $LOCK_WAIT -gt 600 ]; then
    fail "Timed out waiting for apt lock after 600 seconds"
  fi
  sleep 1
done
if [ $LOCK_WAIT -gt 0 ]; then
  log "Apt lock released after ${LOCK_WAIT}s"
fi

log "Refreshing apt package index..."
apt-get update -q || fail "apt-get update failed"

# Pre-install Homebrew as clawdbot (Homebrew refuses to run as root).
# The ansible playbook checks for /home/linuxbrew/.linuxbrew/bin/brew
# and skips installation if it exists.
if [ ! -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  log "Pre-installing Homebrew as clawdbot user (Homebrew refuses root)..."
  su - clawdbot -c 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' 2>&1 || {
    fail "Homebrew installation failed"
  }
  log "Homebrew installed at /home/linuxbrew/.linuxbrew/bin/brew"
else
  log "Homebrew already installed, skipping"
fi

# Run the upstream openclaw-ansible installer as root (the designed path).
# Homebrew is already installed so the playbook will skip that task.
log "Running openclaw-ansible installer (this takes 10-15 minutes)..."
log "Installing: Ansible, UFW, Fail2ban, Tailscale, Docker, Node.js, pnpm, OpenClaw"

curl -fsSL https://raw.githubusercontent.com/openclaw/openclaw-ansible/main/install.sh | bash 2>&1 || {
  fail "openclaw-ansible installer failed"
}

log "openclaw-ansible installation completed"

# Verify OpenClaw is installed
if su - clawdbot -c "command -v clawdbot" &>/dev/null; then
  log "OpenClaw installed: $(su - clawdbot -c 'clawdbot --version 2>/dev/null' || echo unknown)"
else
  log "WARNING: clawdbot command not found in PATH (may need login shell)"
fi

log "OpenClaw Hardened installation completed successfully"
log "Switch to clawdbot user: sudo su - clawdbot"
log "Then run onboarding: clawdbot onboard --install-daemon"

touch /root/.openclaw-installed
EOINSTALL

# Upload script to VM image and make it executable
virt-customize -q -a "$WORK_FILE" \
  --upload "$INSTALL_SCRIPT:/root/install-openclaw.sh" \
  --chmod 0755:/root/install-openclaw.sh || {
  rm -f "$INSTALL_SCRIPT"
  msg_error "Failed to create first-boot installation script"
  exit 1
}
rm -f "$INSTALL_SCRIPT"
msg_ok "Created first-boot installation script"

# Create systemd unit for first-boot installation
msg_info "Creating first-boot systemd unit"

SERVICE_FILE=$(mktemp)
cat > "$SERVICE_FILE" << 'EOSERVICE'
[Unit]
Description=Install OpenClaw (Hardened) on First Boot
After=network-online.target cloud-final.service apt-daily.service apt-daily-upgrade.service
Wants=network-online.target
ConditionPathExists=!/root/.openclaw-installed

[Service]
Type=oneshot
Environment="HOME=/root"
Environment="USER=root"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="DEBIAN_FRONTEND=noninteractive"
ExecStart=/root/install-openclaw.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
TimeoutStartSec=1200

[Install]
WantedBy=multi-user.target
EOSERVICE

virt-customize -q -a "$WORK_FILE" \
  --upload "$SERVICE_FILE:/etc/systemd/system/install-openclaw.service" \
  --run-command "systemctl enable install-openclaw.service" || {
  rm -f "$SERVICE_FILE"
  msg_error "Failed to create and enable systemd unit"
  exit 1
}
rm -f "$SERVICE_FILE"
msg_ok "Created and enabled first-boot systemd unit"

# Create setup instructions
msg_info "Creating setup instructions"

INSTRUCTIONS_FILE=$(mktemp)
cat > "$INSTRUCTIONS_FILE" << 'EOINSTRUCTIONS'
================================================================================
                  OpenClaw Hardened VM - Setup Instructions
================================================================================

This VM was provisioned with openclaw-ansible, which provides:
  - UFW firewall (SSH + Tailscale ports only)
  - Fail2ban (SSH brute-force protection)
  - Automatic security updates (unattended-upgrades)
  - Tailscale VPN (secure remote access)
  - Docker CE (sandbox isolation for agent commands)
  - Node.js + pnpm + OpenClaw
  - Systemd hardening (NoNewPrivileges, PrivateTmp, ProtectSystem)

OpenClaw runs as the "clawdbot" user (created by the ansible installer).

Installation log: /var/log/openclaw-install.log

================================================================================
STEP 1 - CHECK INSTALLATION STATUS
================================================================================

    systemctl status install-openclaw.service
    cat /var/log/openclaw-install.log

Wait until installation is complete (10-15 minutes on first boot).

================================================================================
STEP 2 - SWITCH TO CLAWDBOT USER
================================================================================

    sudo su - clawdbot

================================================================================
STEP 3 - RUN ONBOARDING (REQUIRED)
================================================================================

    clawdbot onboard --install-daemon

The wizard will guide you through:
  - Choosing your AI provider (Anthropic recommended, or OpenAI, etc.)
  - Entering your API key
  - Selecting gateway mode (choose: Local)
  - Configuring channels (Telegram, Discord, WhatsApp, etc.)
  - Installing the daemon service

================================================================================
STEP 4 - START THE GATEWAY
================================================================================

    clawdbot gateway start

Verify:

    clawdbot status
    clawdbot gateway status

================================================================================
STEP 5 - TEST WITH DASHBOARD (BEFORE TELEGRAM)
================================================================================

    clawdbot dashboard

Access from your computer via SSH port forwarding:
    ssh -L 18789:localhost:18789 root@<VM-IP>
    Then open: http://localhost:18789

================================================================================
TAILSCALE VPN (SECURE REMOTE ACCESS)
================================================================================

Tailscale is pre-installed. To connect your VM to your tailnet:

    sudo tailscale up

Or with an auth key (for unattended setup):
    sudo tailscale up --authkey=tskey-auth-xxxxx

Once connected, access the VM via its Tailscale IP instead of LAN IP.
This is the recommended way to access OpenClaw remotely.

================================================================================
TELEGRAM BOT SETUP (OPTIONAL)
================================================================================

1. Create a Telegram Bot:
   - Open Telegram and search for @BotFather
   - Send: /newbot
   - Choose a display name and username (must end in "bot")
   - Save the bot token

2. Configure channel:
    clawdbot configure --section channels

3. Restart the gateway:
    clawdbot gateway restart

4. Pair your account:
    clawdbot pairing list telegram
    clawdbot pairing approve telegram <CODE>

================================================================================
DIAGNOSTIC COMMANDS (run in order when troubleshooting)
================================================================================

    clawdbot status                        # Quick health check
    clawdbot gateway status                # Gateway-specific status
    clawdbot logs --follow                 # Live logs
    clawdbot doctor                        # Full diagnostic
    clawdbot channels status --probe       # Channel connectivity

================================================================================
SERVICE MANAGEMENT
================================================================================

    clawdbot gateway start
    clawdbot gateway stop
    clawdbot gateway restart
    clawdbot gateway status

Or via systemd:
    systemctl --user status openclaw
    systemctl --user restart openclaw

================================================================================
SECURITY
================================================================================

Firewall (UFW):
    sudo ufw status                        # Show firewall rules

Fail2ban:
    sudo fail2ban-client status            # Show jails
    sudo fail2ban-client status sshd       # SSH jail details

Tailscale:
    sudo tailscale status                  # VPN status

Docker:
    docker ps                              # Running containers

Security audit:
    clawdbot security audit --deep
    clawdbot security audit --fix

Public ports: SSH (22) and Tailscale (41641/udp) ONLY.
Verify: nmap -p- <VM-IP> (should show only port 22 open)

================================================================================
BACKUP
================================================================================

Important directories:
    /home/clawdbot/.clawdbot/              # Config, credentials, sessions
    /home/clawdbot/.config/openclaw/       # Alternate config location

Backup command:
    sudo tar -czf openclaw-backup.tar.gz /home/clawdbot/.clawdbot

================================================================================
MORE INFORMATION
================================================================================

    OpenClaw:         https://github.com/openclaw/openclaw
    openclaw-ansible: https://github.com/openclaw/openclaw-ansible
    Documentation:    https://docs.openclaw.ai

================================================================================
EOINSTRUCTIONS

virt-customize -q -a "$WORK_FILE" \
  --upload "$INSTRUCTIONS_FILE:/root/SETUP_INSTRUCTIONS.txt" \
  --chmod 0644:/root/SETUP_INSTRUCTIONS.txt || {
  rm -f "$INSTRUCTIONS_FILE"
  msg_error "Failed to create setup instructions"
  exit 1
}
rm -f "$INSTRUCTIONS_FILE"
msg_ok "Created setup instructions"

# Create dynamic MOTD banner showing installation status
msg_info "Creating login banner"

MOTD_FILE=$(mktemp)
cat > "$MOTD_FILE" << 'EOMOTD'
#!/bin/bash
echo ""
echo "================================================================"
echo "            OpenClaw Hardened AI Agent VM"
echo "          (installed via openclaw-ansible)"
echo "================================================================"
if [ -f /root/.openclaw-installed ]; then
  echo "  Status: INSTALLED"
  if su - clawdbot -c "command -v clawdbot" &>/dev/null 2>&1; then
    VER=$(su - clawdbot -c "clawdbot --version 2>/dev/null" 2>/dev/null || echo "unknown")
    echo "  Version: $VER"
  fi
  if [ -f /home/clawdbot/.clawdbot/clawdbot.json ] || [ -f /home/clawdbot/.clawdbot/moltbot.json ]; then
    echo "  Config: Configured"
    SVC=$(su - clawdbot -c "systemctl --user is-active openclaw 2>/dev/null" 2>/dev/null || echo "inactive")
    echo "  Service: $SVC"
  else
    echo "  Config: NOT CONFIGURED"
    echo ""
    echo "  >>> Switch user:  sudo su - clawdbot"
    echo "  >>> Then run:     clawdbot onboard --install-daemon"
  fi
  echo ""
  echo "  Security: UFW + Fail2ban + Tailscale + Docker"
  UFW=$(sudo ufw status 2>/dev/null | head -1 || echo "unknown")
  echo "  Firewall: $UFW"
elif systemctl is-active --quiet install-openclaw.service 2>/dev/null; then
  echo "  Status: INSTALLING (please wait ~10-15 minutes)"
  echo ""
  echo "  This hardened install includes UFW, Fail2ban,"
  echo "  Tailscale, Docker, and OpenClaw."
  echo ""
  echo "  Monitor progress:"
  echo "    tail -f /var/log/openclaw-install.log"
else
  STATUS=$(systemctl is-failed install-openclaw.service 2>/dev/null || echo "unknown")
  if [ "$STATUS" = "failed" ]; then
    echo "  Status: INSTALLATION FAILED"
    echo ""
    echo "  Check logs:"
    echo "    cat /var/log/openclaw-install.log"
    echo "  Retry:"
    echo "    sudo /root/install-openclaw.sh"
  else
    echo "  Status: PENDING (waiting for first-boot service)"
  fi
fi
echo "================================================================"
echo ""
EOMOTD

virt-customize -q -a "$WORK_FILE" \
  --upload "$MOTD_FILE:/etc/update-motd.d/99-openclaw" \
  --chmod 0755:/etc/update-motd.d/99-openclaw || {
  rm -f "$MOTD_FILE"
  msg_error "Failed to create login banner"
  exit 1
}
rm -f "$MOTD_FILE"
msg_ok "Created login banner"

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

  <h2 style='font-size: 24px; margin: 20px 0;'>OpenClaw Hardened AI Agent VM</h2>
  <p style='font-size: 14px;'>Installed via openclaw-ansible (UFW + Fail2ban + Tailscale + Docker)</p>

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

# ==============================================================================
# IP ADDRESS DETECTION
# ==============================================================================
VM_IP=""
if [ "$START_VM" == "yes" ]; then
  msg_info "Waiting for VM to obtain IP address"
  set +e
  for i in {1..15}; do
    VM_IP=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null |
      jq -r '.[] | select(.name != "lo") | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"' 2>/dev/null |
      grep -v "^127\." | head -1) || true
    [ -n "$VM_IP" ] && break
    sleep 3
  done
  set -e
  if [ -n "$VM_IP" ]; then
    msg_ok "VM IP address: ${CL}${BL}${VM_IP}${CL}"
  else
    msg_ok "IP address not yet available (VM may still be booting)"
  fi
fi

# ==============================================================================
# FINAL OUTPUT
# ==============================================================================
echo -e "${INFO}${YW}===================================================================================${CL}"
echo -e "${INFO}${YW}              OpenClaw Hardened VM Setup Complete${CL}"
echo -e "${INFO}${YW}===================================================================================${CL}"
echo -e ""
echo -e "${INFO}${GN}VM Configuration:${CL}"
echo -e "${TAB}• VM ID: ${VMID}"
echo -e "${TAB}• Machine: Q35 with UEFI"
echo -e "${TAB}• CPU: Host type (passthrough)"
echo -e "${TAB}• Memory: ${RAM_SIZE}MB (Ballooning disabled)"
echo -e "${TAB}• Disk: ${DISK_SIZE}"
[ -n "$VM_IP" ] && echo -e "${TAB}• IP Address: ${VM_IP}"
echo -e ""
echo -e "${INFO}${GN}Security Hardening (via openclaw-ansible):${CL}"
echo -e "${TAB}• UFW firewall (SSH + Tailscale only)"
echo -e "${TAB}• Fail2ban (SSH brute-force protection)"
echo -e "${TAB}• Automatic security updates"
echo -e "${TAB}• Tailscale VPN (secure remote access)"
echo -e "${TAB}• Docker CE (sandbox isolation)"
echo -e "${TAB}• Systemd hardening"
echo -e ""
echo -e "${INFO}${RD}${BOLD}SSH Login Credentials (SAVE THESE!):${CL}"
echo -e "${TAB}${BOLD}Username: ${BGN}root${CL}"
echo -e "${TAB}${BOLD}Password: ${BGN}${ROOT_PASSWORD}${CL}"
if [ -n "$VM_IP" ]; then
  echo -e "${TAB}${BOLD}Command:  ${BGN}ssh root@${VM_IP}${CL}"
fi
echo -e ""
echo -e "${INFO}${YW}Next Steps:${CL}"
if [ -n "$VM_IP" ]; then
  echo -e "${TAB}${GN}1.${CL} SSH into the VM: ${YW}ssh root@${VM_IP}${CL}"
else
  echo -e "${TAB}${GN}1.${CL} Wait for VM to boot and check IP in Proxmox console"
fi
echo -e "${TAB}${GN}2.${CL} Wait for hardened installation to complete (~10-15 min)"
echo -e "${TAB}${GN}3.${CL} Monitor progress: ${YW}tail -f /var/log/openclaw-install.log${CL}"
echo -e "${TAB}${GN}4.${CL} Switch to clawdbot user: ${YW}sudo su - clawdbot${CL}"
echo -e "${TAB}${GN}5.${CL} Run onboarding: ${YW}clawdbot onboard --install-daemon${CL}"
echo -e "${TAB}${GN}6.${CL} Start gateway: ${YW}clawdbot gateway start${CL}"
echo -e "${TAB}${GN}7.${CL} Setup instructions: ${YW}cat /root/SETUP_INSTRUCTIONS.txt${CL}"
echo -e ""
echo -e "${INFO}${YW}Security Note:${CL}"
echo -e "${TAB}OpenClaw runs as the 'clawdbot' user with scoped sudo."
echo -e "${TAB}Hypervisor isolation + UFW + Fail2ban protect the system."
echo -e "${TAB}Use Tailscale for secure remote access (sudo tailscale up)."
echo -e ""
