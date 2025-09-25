#!/usr/bin/env bash
# disk-wipefs.sh v7.5
# Safely wipe a disk clean (LVM, Ceph, ZFS, signatures...)

set -euo pipefail

DISK=""
WIPE_ALL=false

log() { echo -e "[*] $1"; }
err() { echo -e "[!] $1" >&2; }

usage() {
    echo "Usage: $0 <disk> | --all"
    echo "Example: $0 sdb"
    echo "         $0 --all   # wipe all except system disk (sda)"
    exit 1
}

# === CHECK FUNCTIONS ===
check_root() { [[ $EUID -ne 0 ]] && { err "Run as root!"; exit 1; }; }
check_tools() {
    for t in lsblk umount swapoff vgchange lvremove dmsetup wipefs sgdisk dd partprobe; do
        command -v $t &>/dev/null || { err "Missing tool: $t"; exit 1; }
    done
}

# === CORE ACTIONS ===
unmount_partitions() {
    local d=$1
    log "Unmounting partitions on /dev/$d..."
    lsblk -ln "/dev/$d" | awk '$6=="part"{print $1}' | while read -r part; do
        mountpoint=$(lsblk -no MOUNTPOINT "/dev/$part" || true)
        [[ -n "$mountpoint" ]] && umount -f "/dev/$part" || true
    done
}

disable_swap() {
    local d=$1
    log "Disabling swap on /dev/$d..."
    swapoff -a || true
    sed -i.bak "/$d/d" /etc/fstab
}

deactivate_lvm() {
    local d=$1
    log "Deactivating LVM on /dev/$d..."
    pvs --noheadings -o vg_name "/dev/$d" 2>/dev/null | sort -u | while read -r vg; do
        [[ -n "$vg" ]] || continue
        lvchange -an "$vg" || true
        vgremove -ff "$vg" || true
    done
}

remove_dmsetup() {
    local d=$1
    log "Removing device-mapper maps for /dev/$d..."
    dmsetup ls --tree | grep "$d" | awk '{print $1}' | while read -r map; do
        dmsetup remove -f "$map" || true
    done
}

zap_ceph() {
    local d=$1
    log "Zapping Ceph OSD metadata on /dev/$d..."
    if command -v ceph-volume &>/dev/null; then
        ceph-volume lvm zap --destroy "/dev/$d" || true
    else
        log "ceph-volume not installed, skipping..."
    fi
}

zap_zfs() {
    local d=$1
    log "Cleaning ZFS labels on /dev/$d..."
    if command -v zpool &>/dev/null; then
        zpool labelclear -f "/dev/$d" || true
    else
        log "zpool not installed, skipping..."
    fi
}

wipe_signatures() {
    local d=$1
    log "Wiping signatures on /dev/$d..."
    wipefs -a -f "/dev/$d" || true
    sgdisk --zap-all "/dev/$d" || true
    dd if=/dev/zero of="/dev/$d" bs=1M count=10 oflag=direct,dsync status=none || true
}

reload_kernel() {
    local d=$1
    log "Reloading kernel partition table on /dev/$d..."
    partprobe "/dev/$d" || true
}

wipe_disk() {
    local d=$1
    [[ ! -b /dev/$d ]] && { err "/dev/$d not found"; return 1; }
    [[ "$d" == "sda" ]] && { err "Skipping system disk /dev/sda"; return 1; }

    log "=== Starting disk wipe for /dev/$d ==="
    unmount_partitions "$d"
    disable_swap "$d"
    deactivate_lvm "$d"
    remove_dmsetup "$d"
    zap_ceph "$d"
    zap_zfs "$d"
    wipe_signatures "$d"
    reload_kernel "$d"
    log "=== Done wiping /dev/$d ==="
}

# === MAIN ===
check_root
check_tools

if [[ $# -eq 0 ]]; then
    usage
fi

if [[ "$1" == "--all" ]]; then
    WIPE_ALL=true
else
    DISK=$1
fi

if $WIPE_ALL; then
    for d in $(lsblk -dn -o NAME | grep -v "^sda$"); do
        wipe_disk "$d"
    done
else
    wipe_disk "$DISK"
fi
