#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: [YourGitHubUsername]
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/openclaw/openclaw

# ==============================================================================
# OpenClaw Minimal VM - Bare Ubuntu VM for manual openclaw-ansible installation
# ==============================================================================
# Creates a clean Ubuntu 24.04 VM with only qemu-guest-agent and SSH access.
# After provisioning, SSH in and run the openclaw-ansible installer manually.
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
NSAPP="openclaw-vm-minimal"
var_os="ubuntu"
var_version="24.04"

GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
ROOT_PASSWORD="$(openssl rand -base64 16 | tr -d '/+=' | head -c 16)"
METHOD=""
DISK_SIZE="32G"
USE_CLOUD_INIT="yes"
OS_TYPE="ubuntu"
OS_VERSION="24.04"
OS_CODENAME="noble"
OS_DISPLAY="Ubuntu 24.04 LTS"
THIN="discard=on,ssd=1,"
DIAGNOSTICS="${DIAGNOSTICS:-no}"

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
  BALLOON="0"

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

  MACHINE=" -machine q35"
  FORMAT=""
  echo -e "${CONTAINERTYPE}${BOLD}${DGN}Machine Type: ${BGN}Q35 (Required for OpenClaw)${CL}"

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

  DISK_CACHE=""
  echo -e "${DISKSIZE}${BOLD}${DGN}Disk Cache: ${BGN}None${CL}"

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

  CPU_TYPE=" -cpu host"
  echo -e "${OS}${BOLD}${DGN}CPU Model: ${BGN}Host (Required for OpenClaw)${CL}"

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

  BALLOON="0"

  if BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a Bridge" 8 58 vmbr0 --title "BRIDGE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $BRG ]; then
      BRG="vmbr0"
    fi
    echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}$BRG${CL}"
  else
    exit_script
  fi

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
    /_/       Minimal VM (manual install)
EOF
}

header_info
echo -e "\n Loading..."

if whiptail --backtitle "Proxmox VE Helper Scripts" --title "OpenClaw Minimal VM" --yesno "This will create a clean Ubuntu 24.04 VM for OpenClaw.\n\nAfter creation, SSH in and run:\n  curl -fsSL https://raw.githubusercontent.com/openclaw/openclaw-ansible/main/install.sh | bash\n\nProceed?" 14 68; then
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
# IMAGE CUSTOMIZATION (minimal: only qemu-guest-agent and SSH)
# ==============================================================================
msg_info "Preparing ${OS_DISPLAY} image"

WORK_FILE=$(mktemp --suffix=.qcow2)
cp "$CACHE_FILE" "$WORK_FILE"

export LIBGUESTFS_BACKEND_SETTINGS=dns=8.8.8.8,1.1.1.1

msg_info "Installing qemu-guest-agent"
virt-customize -q -a "$WORK_FILE" --install qemu-guest-agent || {
  msg_error "Failed to install qemu-guest-agent"
  exit 1
}
msg_ok "Installed qemu-guest-agent"

# Finalize image (hostname, SSH config, clean machine-id)
msg_info "Finalizing image"
virt-customize -q -a "$WORK_FILE" \
  --hostname "${HN}" \
  --run-command "truncate -s 0 /etc/machine-id" \
  --run-command "rm -f /var/lib/dbus/machine-id" \
  --run-command "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config" \
  --run-command "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config" || {
  msg_error "Failed to finalize image"
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
  qm set "$VMID" --ciuser "root" --cipassword "${ROOT_PASSWORD}" >/dev/null

  if [ -n "${CLOUDINIT_CONFIG_SSH_KEYS:-}" ]; then
    qm set "$VMID" --sshkeys "${CLOUDINIT_CONFIG_SSH_KEYS}" >/dev/null
  fi

  qm set "$VMID" --ipconfig0 ip=dhcp >/dev/null
  msg_ok "Configured Cloud-Init"
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
  <p style='font-size: 14px;'>Clean Ubuntu 24.04 - run openclaw-ansible manually after SSH</p>

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
echo -e "${INFO}${YW}              OpenClaw VM Ready${CL}"
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
echo -e "${INFO}${RD}${BOLD}SSH Login Credentials (SAVE THESE!):${CL}"
echo -e "${TAB}${BOLD}Username: ${BGN}root${CL}"
echo -e "${TAB}${BOLD}Password: ${BGN}${ROOT_PASSWORD}${CL}"
if [ -n "$VM_IP" ]; then
  echo -e "${TAB}${BOLD}Command:  ${BGN}ssh root@${VM_IP}${CL}"
fi
echo -e ""
echo -e "${INFO}${YW}Install OpenClaw:${CL}"
if [ -n "$VM_IP" ]; then
  echo -e "${TAB}${GN}1.${CL} SSH into the VM: ${YW}ssh root@${VM_IP}${CL}"
else
  echo -e "${TAB}${GN}1.${CL} Wait for VM to boot and check IP in Proxmox console"
fi
echo -e "${TAB}${GN}2.${CL} Run the installer: ${YW}curl -fsSL https://raw.githubusercontent.com/openclaw/openclaw-ansible/main/install.sh | bash${CL}"
echo -e "${TAB}${GN}3.${CL} Switch to clawdbot user: ${YW}sudo su - clawdbot${CL}"
echo -e "${TAB}${GN}4.${CL} Run onboarding: ${YW}clawdbot onboard --install-daemon${CL}"
echo -e ""
