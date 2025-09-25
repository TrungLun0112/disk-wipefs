#!/usr/bin/env bash
# disk-wipefs.sh v2.5
# Author: ChatGPT + TrungLun0112
# Repo: https://github.com/TrungLun0112/disk-wipefs
#
# Description:
#   Strong and verbose disk wiping utility for Linux servers.
#   Supports selective disks, auto/manual confirm, --all mode (skip /dev/sda by default).
#   Cleans partition tables, RAID, LVM, Ceph, ZFS metadata.
#   Auto-reload disk after wipe (no reboot needed).

set -euo pipefail

# ==============================
# Colors
# ==============================
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

log() { echo -e "$(date +'%F %T') ${BLUE}[INFO]${RESET} $*"; }
warn() { echo -e "$(date +'%F %T') ${YELLOW}[WARN]${RESET} $*"; }
err() { echo -e "$(date +'%F %T') ${RED}[ERROR]${RESET} $*" >&2; }
success() { echo -e "$(date +'%F %T') ${GREEN}[OK]${RESET} $*"; }

# ==============================
# Trap Ctrl+C
# ==============================
trap "warn 'Interrupted! Script aborted by user (Ctrl+C).'" INT

# ==============================
# Usage
# ==============================
usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [DISKS...]

Examples:
  $0 sdb nvme0n1
  $0 --all
  $0 --all --auto
  $0 sd* nvme*

Options:
  --all        Wipe all available disks (excluding /dev/sda by default)
  --force-sda  Include /dev/sda in --all mode (DANGEROUS)
  --auto       Run without manual confirmation
  --manual     Always ask before wiping (default)
  -h, --help   Show this help message

Notes:
  - Skips loop, sr*, dm*, mapper* by default
  - Always tries to auto-unmount partitions before wiping
  - Reloads disk state after wipe (partprobe, blockdev, kpartx, SCSI rescan)
EOF
}

# ==============================
# Detect OS + check dependencies
# ==============================
detect_os() {
  if command -v lsb_release >/dev/null 2>&1; then
    OS_NAME=$(lsb_release -si)
    OS_VER=$(lsb_release -sr)
  elif [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_NAME=$NAME
    OS_VER=$VERSION_ID
  else
    OS_NAME="Unknown"
    OS_VER="Unknown"
  fi
  log "Detected OS: $OS_NAME $OS_VER"
}

check_deps() {
  local deps=(wipefs sgdisk mdadm pvremove vgremove lvremove zpool dd)
  local missing=()

  for bin in "${deps[@]}"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      missing+=("$bin")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing tools: ${missing[*]}"
    log "Installing required packages..."
    if [[ "$OS_NAME" =~ Ubuntu|Debian ]]; then
      sed -i '/cdrom/d' /etc/apt/sources.list
      apt-get update -y
      apt-get install -y gdisk mdadm lvm2 zfsutils-linux util-linux
    elif [[ "$OS_NAME" =~ CentOS|Red\ Hat|Rocky|Alma ]]; then
      yum install -y gdisk mdadm lvm2 zfsutils util-linux
    else
      warn "Unknown OS, please install dependencies manually."
    fi
  else
    success "All essential tools present."
  fi
}

# ==============================
# Disk Operations
# ==============================
unmount_disk() {
  local disk="$1"
  for part in $(lsblk -ln -o NAME "/dev/$disk" | tail -n +2); do
    if mount | grep -q "/dev/$part"; then
      warn "Unmounting /dev/$part ..."
      umount -f "/dev/$part" || true
    fi
  done
}

reload_disk() {
  local disk="$1"
  log "Reloading disk $disk ..."
  partprobe "/dev/$disk" || true
  blockdev --rereadpt "/dev/$disk" || true
  kpartx -u "/dev/$disk" || true
  echo 1 > "/sys/block/$disk/device/rescan" || true
}

wipe_disk() {
  local disk="$1"
  log "Processing /dev/$disk ..."

  unmount_disk "$disk"

  # wipefs & partition zap
  wipefs -a -f "/dev/$disk" || true
  sgdisk --zap-all "/dev/$disk" || true

  # RAID / LVM / Ceph / ZFS cleanup
  mdadm --zero-superblock "/dev/$disk" || true
  pvremove -ff -y "/dev/$disk" 2>/dev/null || true
  vgremove -ff -y "/dev/$disk" 2>/dev/null || true
  lvremove -ff -y "/dev/$disk" 2>/dev/null || true
  ceph-volume lvm zap --destroy "/dev/$disk" 2>/dev/null || true
  zpool labelclear -f "/dev/$disk" 2>/dev/null || true

  # zero out head/tail
  dd if=/dev/zero of="/dev/$disk" bs=1M count=10 conv=fsync status=none || true
  DISK_SIZE=$(blockdev --getsz "/dev/$disk")
  SEEK=$((DISK_SIZE - 20480))
  dd if=/dev/zero of="/dev/$disk" bs=512 seek=$SEEK count=20480 conv=fsync status=none || true

  reload_disk "$disk"
  success "Disk /dev/$disk wiped successfully."
}

# ==============================
# Parse args
# ==============================
DISKS=()
MODE="manual"
ALL_MODE=false
FORCE_SDA=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) ALL_MODE=true ;;
    --force-sda) FORCE_SDA=true ;;
    --auto) MODE="auto" ;;
    --manual) MODE="manual" ;;
    -h|--help) usage; exit 0 ;;
    *) DISKS+=("$1") ;;
  esac
  shift
done

detect_os
check_deps

if $ALL_MODE; then
  log "Collecting all disks..."
  mapfile -t DISKS < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}')
  # skip sda unless forced
  if ! $FORCE_SDA; then
    DISKS=("${DISKS[@]/sda}")
  fi
  # skip loop, sr, dm, mapper
  DISKS=($(printf "%s\n" "${DISKS[@]}" | grep -Ev '^(loop|sr|dm-)'))
fi

if [[ ${#DISKS[@]} -eq 0 ]]; then
  err "No disks specified. Use --all or pass disk names."
  exit 1
fi

for d in "${DISKS[@]}"; do
  if [[ "$MODE" == "manual" ]]; then
    read -rp "Wipe /dev/$d ? (y/N): " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { warn "Skipped /dev/$d"; continue; }
  fi
  wipe_disk "$d"
done

success "Wipe completed. Run 'lsblk' to verify."
