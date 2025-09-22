#!/usr/bin/env bash
#
# disk-wipefs.sh - Strong disk cleaner tool
#
# Author: ChatGPT & TrungLun0112
# Repo  : https://github.com/TrungLun0112/disk-wipefs
#
# Description:
#   Safely wipe disks by removing all filesystem/RAID/LVM/ZFS/Ceph traces.
#   Includes verbose logging, color output, confirmation mode or auto mode,
#   and disk reload after wipe.
#
#   ⚠️ WARNING: This script is destructive. Use at your own risk.
#

# ---------------- Colors ----------------
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

log() { echo -e "${BLUE}[INFO]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }

# ---------------- Trap ----------------
trap 'echo -e "\n${YELLOW}[WARN] Interrupted by user (Ctrl+C). Exiting safely.${RESET}"; exit 1' INT

# ---------------- Functions ----------------
reload_disk() {
    local dev="$1"
    log "Reloading disk ${dev}..."
    partprobe "$dev" &>/dev/null || true
    blockdev --rereadpt "$dev" &>/dev/null || true
    kpartx -u "$dev" &>/dev/null || true
    echo 1 > /sys/class/block/"$(basename $dev)"/device/rescan 2>/dev/null || true
    success "Disk ${dev} reloaded."
}

wipe_disk() {
    local dev="$1"

    # Skip loop, sr, dm
    if [[ "$dev" =~ ^/dev/loop ]] || [[ "$dev" =~ ^/dev/sr ]]; then
        warn "Skipping $dev (loop/sr device)"
        return
    fi
    if [[ "$dev" =~ ^/dev/dm- ]] || [[ "$dev" =~ ^/dev/mapper/ ]]; then
        warn "Skipping $dev (device mapper)"
        return
    fi

    # Skip sda unless --force
    if [[ "$dev" == "/dev/sda" && "$FORCE_SDA" != "1" ]]; then
        warn "Skipping /dev/sda (system disk). Use --force to override."
        return
    fi

    log "Checking disk type for $dev..."
    blkid "$dev" || true
    pvs "$dev" 2>/dev/null || true
    mdadm --examine "$dev" 2>/dev/null | head -n 5 || true
    zpool labelclear -n "$dev" 2>/dev/null || true

    if [[ "$MODE" == "manual" ]]; then
        read -p "Wipe $dev? (y/n): " ans
        [[ "$ans" != "y" ]] && warn "Skipped $dev" && return
    fi

    log "Wiping $dev..."
    wipefs -a "$dev" || true
    sgdisk --zap-all "$dev" &>/dev/null || true

    # Optional Ceph
    if [[ "$ZAP_CEPH" == "1" ]]; then
        log "Zapping Ceph metadata on $dev..."
        ceph-volume lvm zap --destroy "$dev" || true
    fi

    # Optional ZFS
    if [[ "$ZAP_ZFS" == "1" ]]; then
        log "Clearing ZFS label on $dev..."
        zpool labelclear -f "$dev" || true
    fi

    success "Wipe completed for $dev"
    reload_disk "$dev"
}

usage() {
    cat <<EOF
Usage:
  ./disk-wipefs.sh [options] <disks...>

Examples:
  ./disk-wipefs.sh sdb sdc nvme0n1
  ./disk-wipefs.sh all -sda -nvme0n1   # wipe all except system disks
  ./disk-wipefs.sh sd* nvme* vd* mmcblk*

Options:
  --auto        Run in automatic mode (no confirmation).
  --manual      Run in manual confirm mode (default if no flag).
  --force       Allow wiping /dev/sda (system disk).
  --zap-ceph    Run Ceph zap if Ceph metadata is found.
  --zap-zfs     Run ZFS labelclear if ZFS metadata is found.

Notes:
  - loop and sr devices are always skipped.
  - device-mapper (dm-*) devices are skipped; wipe the underlying disk instead.
EOF
    exit 1
}

# ---------------- Main ----------------
ARGS=()
MODE="manual"
FORCE_SDA=0
ZAP_CEPH=0
ZAP_ZFS=0

for arg in "$@"; do
    case "$arg" in
        --auto) MODE="auto";;
        --manual) MODE="manual";;
        --force) FORCE_SDA=1;;
        --zap-ceph) ZAP_CEPH=1;;
        --zap-zfs) ZAP_ZFS=1;;
        -*) EXCLUDE+=("${arg#-}");;
        all) ALL=1;;
        *) ARGS+=("$arg");;
    esac
done

if [[ ${#ARGS[@]} -eq 0 && "$ALL" != "1" ]]; then
    usage
fi

if [[ "$ALL" == "1" ]]; then
    # Collect all disks
    mapfile -t DISKS < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
    # Apply exclusions
    for ex in "${EXCLUDE[@]}"; do
        DISKS=("${DISKS[@]/\/dev\/$ex/}")
    done
else
    DISKS=("${ARGS[@]/#/\/dev\/}")
fi

log "Mode: $MODE"
log "Disks to wipe: ${DISKS[*]}"

for dev in "${DISKS[@]}"; do
    wipe_disk "$dev"
done
