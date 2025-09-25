#!/usr/bin/env bash
# disk-wipefs.sh v7.4
# Author: Trung + GPT
# Purpose: Nuke disk sạch triệt để (Ceph, ZFS, LVM, Multipath, filesystem...)

set -euo pipefail

DISK="${1:-}"

usage() {
    echo "Usage:"
    echo "  $0 <disk>    # e.g. $0 /dev/sdb"
    echo "  $0 --all     # wipe all disks except /dev/sda"
    exit 1
}

log() { echo -e "[*] $*"; }

normalize_disk() {
    local d="$1"
    [[ "$d" != /dev/* ]] && d="/dev/$d"
    echo "$d"
}

### 1. Unmount all partitions
unmount_partitions() {
    local disk="$1"
    log "Unmounting partitions on $disk..."
    lsblk -nrpo NAME "$disk" | tail -n +2 | while read -r part; do
        if mountpoint=$(findmnt -n -o TARGET "$part" 2>/dev/null || true); then
            if [[ -n "$mountpoint" ]]; then
                umount -fl "$part" || true
                log "  Unmounted $part from $mountpoint"
            fi
        fi
    done
}

### 2. Swapoff
disable_swap() {
    local disk="$1"
    log "Disabling swap on $disk..."
    swapoff -a || true
    lsblk -nrpo NAME,TYPE "$disk" | awk '$2=="part"{print $1}' | while read -r part; do
        swapoff "$part" 2>/dev/null || true
    done
}

### 3. Deactivate LVM
deactivate_lvm() {
    local disk="$1"
    log "Deactivating LVM on $disk..."
    vgchange -an || true
    for lv in $(lvs --noheadings -o lv_path 2>/dev/null || true); do
        lvremove -fy "$lv" || true
    done
    for vg in $(vgs --noheadings -o vg_name 2>/dev/null || true); do
        vgremove -fy "$vg" || true
    done
    pvremove -fy "$disk" 2>/dev/null || true
}

### 4. Remove dmsetup maps
remove_dmsetup() {
    local disk="$1"
    log "Removing device-mapper mappings for $disk..."
    for map in $(dmsetup ls --noheadings 2>/dev/null | awk '{print $1}'); do
        if dmsetup info "$map" 2>/dev/null | grep -q "$(basename "$disk")"; then
            dmsetup remove -f "$map" || true
            log "  Removed DM map: $map"
        fi
    done
}

### 5. Ceph zap
zap_ceph() {
    local disk="$1"
    log "Zapping Ceph OSD metadata on $disk..."
    if command -v ceph-volume >/dev/null 2>&1; then
        ceph-volume lvm zap --destroy "$disk" || true
    fi
}

### 6. ZFS cleanup
zap_zfs() {
    local disk="$1"
    log "Cleaning ZFS labels on $disk..."
    if command -v zpool >/dev/null 2>&1; then
        zpool labelclear -f "$disk" || true
    fi
}

### 7. Wipe signatures
wipe_signatures() {
    local disk="$1"
    log "Wiping signatures on $disk..."
    wipefs -a -f "$disk" || true
    sgdisk --zap-all "$disk" || true
    dd if=/dev/zero of="$disk" bs=1M count=10 conv=fsync status=none || true
}

### 8. Reload kernel partition table
reload_kernel() {
    local disk="$1"
    log "Reloading kernel partition table on $disk..."
    partprobe "$disk" || true
    blockdev --rereadpt "$disk" || true
}

wipe_disk() {
    local disk
    disk=$(normalize_disk "$1")

    [[ ! -b "$disk" ]] && { log "Error: $disk is not a block device"; return 1; }

    log "=== Starting disk wipe for $disk ==="
    unmount_partitions "$disk"
    disable_swap "$disk"
    deactivate_lvm "$disk"
    remove_dmsetup "$disk"
    zap_ceph "$disk"
    zap_zfs "$disk"
    wipe_signatures "$disk"
    reload_kernel "$disk"
    log "=== Done wiping $disk ==="
}

main() {
    if [[ -z "$DISK" ]]; then
        usage
    elif [[ "$DISK" == "--all" ]]; then
        for d in /dev/sd?; do
            [[ "$d" == "/dev/sda" ]] && continue
            wipe_disk "$d"
        done
    else
        wipe_disk "$DISK"
    fi
}

main "$@"
