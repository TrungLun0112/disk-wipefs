#!/usr/bin/env bash
#
# disk-wipefs.sh v2.3 (hotfix)
# Author: TrungLun0112 + ChatGPT
# Repo: https://github.com/TrungLun0112
#
# Safe & powerful disk wipe script for Linux

set -euo pipefail

# ----- Colors -----
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
NC="\033[0m"

log() {
    local level="$1"; shift
    local msg="$*"
    echo -e "$(date '+%F %T') ${BLUE}[${level}]${NC} $msg"
}

# ----- Detect OS -----
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$NAME"
        VER="$VERSION_ID"
    else
        OS="$(uname -s)"
        VER="$(uname -r)"
    fi
    log INFO "Detected OS: $OS $VER"
}

# ----- Check & install dependencies -----
check_dependencies() {
    local tools=("wipefs" "lsblk" "sgdisk" "mdadm" "lvm")
    local missing=()

    for t in "${tools[@]}"; do
        if ! command -v "$t" &>/dev/null; then
            missing+=("$t")
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        log INFO "All essential tools present."
    else
        log WARN "Missing tools: ${missing[*]}"
        log INFO "Script will auto install missing packages..."
        fix_cdrom_repo
        install_packages "${missing[@]}"
    fi
}

# ----- Fix CD-ROM repo (Ubuntu/Debian) -----
fix_cdrom_repo() {
    if grep -q "cdrom:" /etc/apt/sources.list; then
        log WARN "Found cdrom repo, disabling..."
        sed -i 's/^deb cdrom/#deb cdrom/g' /etc/apt/sources.list
    fi
}

# ----- Install packages depending on OS -----
install_packages() {
    local pkgs=("$@")
    if command -v apt-get &>/dev/null; then
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" || true
    elif command -v yum &>/dev/null; then
        yum install -y "${pkgs[@]}" || true
    elif command -v dnf &>/dev/null; then
        dnf install -y "${pkgs[@]}" || true
    elif command -v zypper &>/dev/null; then
        zypper install -y "${pkgs[@]}" || true
    else
        log ERROR "Unsupported package manager. Please install manually: ${pkgs[*]}"
        exit 1
    fi
}

# ----- Wipe one disk -----
wipe_disk() {
    local disk="$1"

    # Skip dangerous or unwanted devices
    [[ "$disk" == "sda" ]] && { log WARN "Skipping $disk (system disk)"; return; }
    [[ "$disk" =~ ^(sr|loop|dm-|mapper) ]] && { log WARN "Skipping $disk"; return; }

    log INFO "Processing /dev/$disk ..."

    # Try unmount partitions
    for part in /dev/${disk}?*; do
        if mount | grep -q "$part"; then
            log INFO "Unmounting $part"
            umount -f "$part" || true
        fi
    done

    # Wipe common metadata
    wipefs -a "/dev/$disk" || true
    sgdisk --zap-all "/dev/$disk" || true
    mdadm --zero-superblock "/dev/$disk" || true
    pvremove -ff -y "/dev/$disk" 2>/dev/null || true

    # Overwrite head/tail sectors
    dd if=/dev/zero of="/dev/$disk" bs=1M count=10 conv=fsync &>/dev/null || true
    sz=$(blockdev --getsz "/dev/$disk")
    off=$((sz - 20480))
    dd if=/dev/zero of="/dev/$disk" bs=512 seek=$off count=20480 conv=fsync &>/dev/null || true

    # Reload kernel partition table
    blockdev --rereadpt "/dev/$disk" || true
    partprobe "/dev/$disk" || true

    log INFO "Disk /dev/$disk wiped successfully."
}

# ----- Main flow -----
main() {
    if [ $# -lt 1 ]; then
        echo -e "${YELLOW}Usage:${NC} $0 <disk1> [disk2...] | all"
        exit 1
    fi

    detect_os
    check_dependencies

    local targets=()
    if [ "$1" == "all" ]; then
        targets=$(lsblk -dn -o NAME | grep -E '^(sd|nvme|vd|mmcblk)')
    else
        targets=("$@")
    fi

    for d in ${targets[@]}; do
        wipe_disk "$d"
    done

    log INFO "Wipe completed. Run 'lsblk' to verify."
}

main "$@"
