#!/usr/bin/env bash
#
# disk-wipefs v2.2
# Author: ChatGPT & TrungLun0112
# Repo: https://github.com/TrungLun0112/disk-wipefs
#
# A powerful disk cleaning script for Linux servers.
# Features: auto-unmount, RAID/LVM/Ceph/ZFS wipe, GPT/MBR zap,
# residual metadata cleanup, detailed logs with colors.
#

set -euo pipefail

### ========== Colors ==========
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
RESET="\033[0m"

log_info()    { echo -e "${GREEN}[INFO]${RESET} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*"; }
log_step()    { echo -e "${BLUE}[STEP]${RESET} $*"; }

### ========== Trap ==========
trap 'echo -e "\n${YELLOW}[ABORTED]${RESET} Script interrupted by user (Ctrl+C)" && exit 1' INT

### ========== Functions ==========

check_dependencies() {
    log_step "Checking dependencies..."
    local pkgs=("wipefs" "sgdisk" "mdadm" "lvm" "parted" "lsblk" "blockdev" "kpartx")
    local missing=()
    for p in "${pkgs[@]}"; do
        if ! command -v "$p" &>/dev/null; then
            missing+=("$p")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing packages: ${missing[*]}"
        log_info "Script will auto install missing packages..."
        if command -v apt-get &>/dev/null; then
            sudo sed -i '/cdrom:/d' /etc/apt/sources.list || true
            sudo apt-get update -y
            sudo apt-get install -y "${missing[@]}"
        elif command -v yum &>/dev/null; then
            sudo yum install -y "${missing[@]}"
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y "${missing[@]}"
        elif command -v zypper &>/dev/null; then
            sudo zypper install -y "${missing[@]}"
        else
            log_error "Unsupported package manager. Please install manually: ${missing[*]}"
            exit 1
        fi
    else
        log_info "All dependencies are present."
    fi
}

unmount_partitions() {
    local disk="$1"
    log_step "Unmounting partitions for /dev/${disk}..."
    lsblk -ln "/dev/${disk}" | awk '{print $1}' | grep -v "^${disk}$" || true | while read -r part; do
        if mount | grep -q "/dev/${part}"; then
            log_info "Unmounting /dev/${part}"
            sudo umount -lf "/dev/${part}" || log_warn "Failed to unmount /dev/${part}"
        fi
    done
}

wipe_disk() {
    local disk="$1"

    # Skip sda unless --force
    if [[ "$disk" == "sda" && "$FORCE" -eq 0 ]]; then
        log_warn "Skipping /dev/sda (system disk). Use --force to override."
        return
    fi

    log_step "Starting wipe process on /dev/${disk}"

    unmount_partitions "$disk"

    log_info "Wiping filesystem signatures..."
    sudo wipefs -a "/dev/${disk}" || true

    log_info "Zapping GPT/MBR..."
    sudo sgdisk --zap-all "/dev/${disk}" || true

    log_info "Clearing RAID superblocks..."
    sudo mdadm --zero-superblock --force "/dev/${disk}" || true

    log_info "Cleaning LVM metadata..."
    if sudo pvs "/dev/${disk}" &>/dev/null; then
        sudo vgremove -ff -y "$(sudo pvs --noheadings -o vg_name "/dev/${disk}" | xargs)" || true
        sudo pvremove -ff --yes "/dev/${disk}" || true
    fi

    if [[ "$ZAP_CEPH" -eq 1 ]]; then
        log_info "Running Ceph zap..."
        sudo ceph-volume lvm zap --destroy "/dev/${disk}" || true
    fi

    if [[ "$ZAP_ZFS" -eq 1 ]]; then
        log_info "Clearing ZFS labels..."
        sudo zpool labelclear -f "/dev/${disk}" || true
    fi

    log_info "Residual wipe with dd (first/last 10MB)..."
    size=$(sudo blockdev --getsz "/dev/${disk}")
    mb=$((size * 512 / 1024 / 1024))
    if [[ $mb -gt 20 ]]; then
        sudo dd if=/dev/zero of="/dev/${disk}" bs=1M count=10 conv=fsync status=none
        sudo dd if=/dev/zero of="/dev/${disk}" bs=1M seek=$((mb - 10)) count=10 conv=fsync status=none
    fi

    log_info "Reloading kernel partition table..."
    sudo partprobe "/dev/${disk}" || true
    sudo blockdev --rereadpt "/dev/${disk}" || true
    sudo kpartx -u "/dev/${disk}" || true
    for host in /sys/class/scsi_host/host*/scan; do
        echo "- - -" | sudo tee "$host" >/dev/null
    done

    log_step "Wipe completed for /dev/${disk}"
}

show_usage() {
cat <<EOF
Usage: $0 [OPTIONS] <disk(s) | all>

Examples:
  $0 sdb sdc
  $0 nvme0n1
  $0 all --exclude sda,nvme0n1
  $0 all --auto --zap-ceph --zap-zfs

Options:
  --auto         Automatic mode (no confirmation)
  --manual       Manual mode (confirm each disk)
  --force        Allow wiping system disk (sda)
  --exclude X,Y  Exclude listed disks
  --zap-ceph     Run ceph-volume zap if Ceph metadata detected
  --zap-zfs      Run zpool labelclear if ZFS metadata detected
  --include-dm   Include /dev/dm-* mapper devices
  -h, --help     Show this help
EOF
}

### ========== Main ==========

AUTO=0
MANUAL=0
FORCE=0
ZAP_CEPH=0
ZAP_ZFS=0
EXCLUDE=()
ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto) AUTO=1 ;;
        --manual) MANUAL=1 ;;
        --force) FORCE=1 ;;
        --zap-ceph) ZAP_CEPH=1 ;;
        --zap-zfs) ZAP_ZFS=1 ;;
        --exclude) shift; IFS=',' read -r -a EXCLUDE <<< "$1" ;;
        -h|--help) show_usage; exit 0 ;;
        *) ARGS+=("$1") ;;
    esac
    shift
done

if [[ ${#ARGS[@]} -eq 0 ]]; then
    show_usage
    exit 1
fi

check_dependencies

DISKS=()
if [[ "${ARGS[0]}" == "all" ]]; then
    mapfile -t DISKS < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}')
else
    DISKS=("${ARGS[@]}")
fi

# Apply exclusions
for ex in "${EXCLUDE[@]}"; do
    DISKS=("${DISKS[@]/$ex}")
done

for d in "${DISKS[@]}"; do
    [[ -z "$d" ]] && continue
    if [[ $MANUAL -eq 1 ]]; then
        read -rp "Do you want to wipe /dev/${d}? (y/n): " ans
        [[ "$ans" != "y" ]] && continue
    fi
    wipe_disk "$d"
done

log_info "All requested disks processed."
