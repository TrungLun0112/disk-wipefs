#!/bin/bash
#
# disk-wipefs.sh - Safely clean disks by removing LVM PVs, RAID metadata, Ceph OSD, and filesystem signatures.
#
# Usage:
#   ./disk-wipefs.sh <start_letter> <end_letter>
#
# Example:
#   ./disk-wipefs.sh b e
#   -> will check /dev/sdb ... /dev/sde
#

set -euo pipefail

check_tool() {
    if ! command -v "$1" &>/dev/null; then
        echo "Error: required tool '$1' not found."
        exit 1
    fi
}

for tool in lsblk wipefs pvremove vgremove vgdisplay mdadm sgdisk; do
    check_tool "$tool"
done

START=${1:-}
END=${2:-}

if [[ -z "$START" || -z "$END" ]]; then
    echo "Usage: $0 <start_letter> <end_letter>"
    exit 1
fi

for disk in $(eval echo /dev/sd{$START..$END}); do
    if [[ ! -b $disk ]]; then
        echo "Skipping $disk (not a block device)"
        continue
    fi

    echo "=================================================="
    echo "Checking $disk ..."
    lsblk "$disk"

    # Detect LVM PV
    if pvs --noheadings 2>/dev/null | grep -q "$disk"; then
        echo "Found LVM PV on $disk"
        read -rp "Remove LVM PV from $disk? (y/n): " ans
        if [[ "$ans" == "y" ]]; then
            vgname=$(pvs --noheadings -o vg_name "$disk" | awk '{print $1}')
            if [[ -n "$vgname" ]]; then
                echo "Removing VG $vgname ..."
                vgremove -f "$vgname" || true
            fi
            pvremove -ff -y "$disk"
        fi
    fi

    # Detect RAID member
    if mdadm --examine "$disk" &>/dev/null; then
        echo "Found RAID metadata on $disk"
        read -rp "Remove RAID metadata from $disk? (y/n): " ans
        if [[ "$ans" == "y" ]]; then
            mdadm --zero-superblock "$disk"
        fi
    fi

    # Detect Ceph OSD
    if blkid "$disk" 2>/dev/null | grep -qi ceph; then
        echo "Found Ceph OSD on $disk"
        read -rp "Remove Ceph OSD signature from $disk? (y/n): " ans
        if [[ "$ans" == "y" ]]; then
            dd if=/dev/zero of="$disk" bs=1M count=10 conv=fsync
        fi
    fi

    # Finally, wipe filesystem signatures
    echo "Wiping filesystem signatures on $disk ..."
    wipefs -a -f "$disk"

    # Optionally wipe GPT/MBR
    echo "Clearing partition table on $disk ..."
    sgdisk --zap-all "$disk" || true

    echo "$disk cleanup complete."
    echo "=================================================="
done
