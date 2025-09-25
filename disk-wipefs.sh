#!/usr/bin/env bash
# disk-wipefs.sh v7.3
# Author: Trung + GPT
# Purpose: Nuke disk sạch triệt để (Ceph, ZFS, LVM, Multipath, filesystem...)

set -euo pipefail

DISK="${1:-}"
[[ -z "$DISK" ]] && { echo "Usage: $0 /dev/sdX"; exit 1; }

log() { echo -e "[*] $*"; }

### 1. Unmount all partitions
unmount_partitions() {
    log "Unmounting partitions on $DISK..."
    lsblk -nrpo NAME "$DISK" | while read -r part; do
        mountpoint=$(findmnt -n -o TARGET "$part" 2>/dev/null || true)
        if [[ -n "$mountpoint" ]]; then
            umount -fl "$part" || true
            log "  Unmounted $part from $mountpoint"
        fi
    done
}

### 2. Swapoff
disable_swap() {
    log "Disabling swap on $DISK..."
    swapoff -a || true
    lsblk -nrpo NAME,TYPE "$DISK" | grep part | while read -r part type; do
        swapoff "$part" 2>/dev/null || true
    done
}

### 3. Deactivate LVM (LV, VG, PV)
deactivate_lvm() {
    log "Deactivating LVM on $DISK..."
    vgchange -an || true
    pvs --noheadings -o pv_name 2>/dev/null | grep -w "$DISK" || true
    for vg in $(vgs --noheadings -o vg_name 2>/dev/null); do
        vgremove -fy "$vg" || true
    done
    for lv in $(lvs --noheadings -o lv_path 2>/dev/null); do
        lvremove -fy "$lv" || true
    done
    pvremove -fy "$DISK" 2>/dev/null || true
}

### 4. Remove device-mapper maps
remove_dmsetup() {
    log "Removing device-mapper mappings for $DISK..."
    dmsetup ls --tree 2>/dev/null | grep "$(basename "$DISK")" || true
    for map in $(dmsetup ls --noheadings 2>/dev/null | awk '{print $1}'); do
        if dmsetup info "$map" | grep -q "$(basename "$DISK")"; then
            dmsetup remove -f "$map" || true
            log "  Removed DM map: $map"
        fi
    done
}

### 5. Ceph zap
zap_ceph() {
    log "Zapping Ceph OSD metadata on $DISK..."
    if command -v ceph-volume >/dev/null 2>&1; then
        ceph-volume lvm zap --destroy "$DISK" || true
    fi
}

### 6. ZFS cleanup
zap_zfs() {
    log "Cleaning ZFS labels on $DISK..."
    if command -v zpool >/dev/null 2>&1; then
        zpool labelclear -f "$DISK" || true
    fi
}

### 7. Wipe signatures
wipe_signatures() {
    log "Wiping signatures on $DISK..."
    wipefs -a -f "$DISK" || true
    sgdisk --zap-all "$DISK" || true
    dd if=/dev/zero of="$DISK" bs=1M count=10 conv=fsync status=progress || true
}

### 8. Reload kernel partition table
reload_kernel() {
    log "Reloading kernel partition table..."
    partprobe "$DISK" || true
    blockdev --rereadpt "$DISK" || true
}

main() {
    log "=== Starting disk wipe for $DISK ==="
    unmount_partitions
    disable_swap
    deactivate_lvm
    remove_dmsetup
    zap_ceph
    zap_zfs
    wipe_signatures
    reload_kernel
    log "=== Done wiping $DISK ==="
}

main "$@"
