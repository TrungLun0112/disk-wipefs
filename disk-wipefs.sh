#!/usr/bin/env bash
# disk-wipefs.sh v8.0
# Author: ChatGPT & TrungLun0112
# Purpose: Wipe a given disk clean (LVM, Ceph, ZFS, FS, partition table)

set -euo pipefail

#######################################
# Logging
#######################################
log() { echo -e "$(date '+%F %T') [INFO] $*"; }
warn() { echo -e "$(date '+%F %T') [WARN] $*"; }
err() { echo -e "$(date '+%F %T') [ERROR] $*" >&2; exit 1; }

#######################################
# 1. Check OS + tools
#######################################
check_env() {
    log "Checking OS and required tools..."
    local tools=(lsblk blkid wipefs sgdisk dd dmsetup lvm ceph-volume zpool partprobe blockdev fuser realpath)
    for t in "${tools[@]}"; do
        command -v "$t" >/dev/null 2>&1 || err "Missing tool: $t"
    done
    log "All essential tools present"
}

#######################################
# 2. Validate input
#######################################
validate_target() {
    [[ $# -eq 1 ]] || err "Usage: $0 <disk>"
    local disk="/dev/$1"

    [[ -b "$disk" ]] || err "$disk is not a block device"
    [[ "$disk" == /dev/sda ]] && err "Refusing to wipe system disk: $disk"

    TARGET=$(realpath "$disk")
    log "Target disk resolved: $TARGET"

    log "Partitions on $TARGET:"
    lsblk "$TARGET" || true
}

#######################################
# 3. Pre-clean
#######################################
preclean() {
    log "[preclean] Unmount partitions of $TARGET"
    umount -f "${TARGET}"* 2>/dev/null || true

    log "[preclean] swapoff for $TARGET"
    swapoff "${TARGET}"* 2>/dev/null || warn "No active swap found"

    log "[preclean] Kill processes using $TARGET"
    fuser -km "${TARGET}"* 2>/dev/null || true
}

#######################################
# 4. LVM cleanup
#######################################
lvm_cleanup() {
    log "[lvm] Cleaning LVM metadata on $TARGET"
    pvs --noheadings -o pv_name,vg_name 2>/dev/null | grep -q "$TARGET" || { log "No LVM PVs on $TARGET"; return; }

    local vgs
    vgs=$(pvs --noheadings -o vg_name "$TARGET" 2>/dev/null | awk '{print $1}' | sort -u)
    for vg in $vgs; do
        log "Deactivating VG: $vg"
        vgchange -an "$vg" || true
    done

    log "Removing PVs on $TARGET"
    pvremove -ff -y "${TARGET}"* || true
}

#######################################
# 5. Device Mapper cleanup
#######################################
dm_cleanup() {
    log "[dm] Removing device-mapper maps for $TARGET"
    local maps
    maps=$(dmsetup ls --tree 2>/dev/null | grep "$TARGET" | awk '{print $1}')
    for m in $maps; do
        log "Removing dm map: $m"
        dmsetup remove -f "$m" || true
    done
}

#######################################
# 6. Ceph cleanup
#######################################
ceph_cleanup() {
    log "[ceph] Zapping Ceph OSD metadata on $TARGET"
    ceph-volume lvm zap "$TARGET" --destroy || log "No Ceph OSDs on $TARGET"
}

#######################################
# 7. ZFS cleanup
#######################################
zfs_cleanup() {
    log "[zfs] Clearing ZFS labels on $TARGET"
    zpool labelclear -f "$TARGET" || log "No ZFS labels on $TARGET"
}

#######################################
# 8. Metadata wipe
#######################################
metadata_wipe() {
    log "[wipefs] Wiping FS signatures"
    wipefs -a -f "$TARGET" || true

    log "[sgdisk] Zapping GPT/MBR"
    sgdisk --zap-all --clear "$TARGET" || true

    log "[dd] Zeroing first 10MB"
    dd if=/dev/zero of="$TARGET" bs=1M count=10 conv=fsync status=none

    log "[dd] Zeroing last 10MB"
    local size
    size=$(blockdev --getsz "$TARGET")
    dd if=/dev/zero of="$TARGET" bs=512 seek=$((size-20480)) count=20480 conv=fsync status=none || true
}

#######################################
# 9. Reload kernel
#######################################
reload_kernel() {
    log "[kernel] Reloading partition table"
    partprobe "$TARGET" || blockdev --rereadpt "$TARGET" || true
}

#######################################
# 10. Verify
#######################################
verify_clean() {
    log "[verify] Checking $TARGET"
    lsblk -f "$TARGET"
    blkid "$TARGET" || log "No signatures detected (expected clean disk)"
}

#######################################
# Main
#######################################
main() {
    check_env
    validate_target "$@"
    preclean
    lvm_cleanup
    dm_cleanup
    ceph_cleanup
    zfs_cleanup
    metadata_wipe
    reload_kernel
    verify_clean
    log "Disk wipe completed for $TARGET"
}

main "$@"
