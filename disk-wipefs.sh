#!/usr/bin/env bash
# disk-wipefs.sh v7.6
# Purpose: Clean target disk safely & completely
# Author: bạn & ChatGPT (let go tới v100 :D)

set -euo pipefail

### GLOBAL
TARGET=""
SCRIPT_NAME=$(basename "$0")

### HELP
usage() {
    echo "Usage: $SCRIPT_NAME <disk>"
    echo "Example: $SCRIPT_NAME /dev/sdb"
    exit 1
}

### STEP 0 - Check OS & Tools
check_prereq() {
    echo "[*] Checking OS & required tools..."
    command -v wipefs >/dev/null || { echo "[!] wipefs not found"; exit 1; }
    command -v sgdisk >/dev/null || echo "[!] sgdisk not installed, skip GPT zap"
    command -v dd >/dev/null || echo "[!] dd not installed, skip MBR wipe"
    command -v dmsetup >/dev/null || echo "[!] dmsetup not installed, skip dm removal"
    command -v pvscan >/dev/null || echo "[!] lvm2 not installed, skip LVM deactivate"
    command -v ceph-volume >/dev/null || echo "[!] ceph-volume not installed, skip Ceph zap"
    command -v zpool >/dev/null || echo "[!] zpool not installed, skip ZFS cleanup"
}

### STEP 1 - Validate input
validate_target() {
    [[ $# -lt 1 ]] && usage
    TARGET=$1
    if [[ ! -b $TARGET ]]; then
        echo "[!] $TARGET is not a block device"
        exit 1
    fi
    echo "[*] Target disk: $TARGET"
}

### STEP 2 - Unmount
do_unmount() {
    echo "[*] Unmounting partitions on $TARGET..."
    for p in $(lsblk -ln -o NAME "$TARGET" | tail -n +2); do
        umount -f "/dev/$p" 2>/dev/null || true
    done
}

### STEP 3 - swapoff
do_swapoff() {
    echo "[*] Disabling swap on $TARGET..."
    swapoff "$TARGET"* 2>/dev/null || true
}

### STEP 4 - LVM deactivate
do_lvm() {
    echo "[*] Deactivating LVM on $TARGET..."
    vgchange -an 2>/dev/null || true
    pvremove -ff -y "$TARGET" 2>/dev/null || true
}

### STEP 5 - dmsetup remove
do_dmsetup() {
    echo "[*] Removing dmsetup maps..."
    dmsetup remove_all || true
}

### STEP 6 - Ceph zap
do_ceph() {
    if command -v ceph-volume >/dev/null; then
        echo "[*] Zapping Ceph on $TARGET..."
        ceph-volume lvm zap --destroy "$TARGET" || true
    fi
}

### STEP 7 - ZFS cleanup
do_zfs() {
    if command -v zpool >/dev/null; then
        echo "[*] Cleaning ZFS labels on $TARGET..."
        zpool labelclear -f "$TARGET" || true
    fi
}

### STEP 8 - Wipefs + GPT zap + dd
do_wipe() {
    echo "[*] Wiping filesystem signatures..."
    wipefs -a -f "$TARGET"

    if command -v sgdisk >/dev/null; then
        echo "[*] Zapping GPT on $TARGET..."
        sgdisk --zap-all "$TARGET" || true
    fi

    echo "[*] Zeroing first 10MB on $TARGET..."
    dd if=/dev/zero of="$TARGET" bs=1M count=10 conv=fsync status=progress || true
}

### STEP 9 - Reload kernel
do_reload() {
    echo "[*] Reloading partition table..."
    partprobe "$TARGET" || true
    blockdev --rereadpt "$TARGET" || true
}

### STEP 10 - Verify
do_verify() {
    echo "[*] Final state of $TARGET:"
    lsblk "$TARGET"
}

### MAIN
validate_target "$@"
check_prereq
do_unmount
do_swapoff
do_lvm
do_dmsetup
do_ceph
do_zfs
do_wipe
do_reload
do_verify

echo "[✓] Disk $TARGET wiped successfully."
