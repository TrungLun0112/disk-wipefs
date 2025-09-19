#!/usr/bin/env bash
# disk-wipefs.sh
# Clean disks (LVM PV, RAID metadata, Ceph signature, filesystems, GPT/MBR)
# and reload device/partition state immediately after cleaning.
#
# Usage:
#   ./disk-wipefs.sh <start_letter> <end_letter>
# Example:
#   ./disk-wipefs.sh b e   # operates on /dev/sdb .. /dev/sde
# Tác giả: TrungLun0112
# Repo: https://github.com/TrungLun0112/disk-wipefs

set -o errexit
set -o nounset
set -o pipefail

# ---------- helper functions ----------
has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

run_if() {
    # run command if available (do not exit on failure)
    if has_cmd "$1"; then
        shift
        "$@" || true
    fi
}

confirm() {
    local prompt="${1:-Are you sure? (y/n): }"
    read -rp "$prompt" ans
    case "$ans" in
        y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

# Remove device-mapper devices that use the given underlying disk (e.g. sdb)
remove_dm_using_disk() {
    local diskname="$1"   # e.g. sdb
    # iterate dm devices under /sys/block/dm-*
    for dm in /sys/block/dm-*; do
        [ -e "$dm" ] || continue
        # check slaves directory for presence of diskname
        if [ -d "$dm/slaves" ]; then
            if ls "$dm/slaves" 2>/dev/null | grep -qx "$diskname"; then
                # get mapper name
                if [ -f "$dm/dm/name" ]; then
                    dmname=$(cat "$dm/dm/name")
                    mapper_dev="/dev/mapper/$dmname"
                    if [ -e "$mapper_dev" ]; then
                        echo "  -> Removing device-mapper $mapper_dev which references $diskname"
                        if has_cmd dmsetup; then
                            dmsetup remove -f "$mapper_dev" || true
                        else
                            echo "     (dmsetup not found; skipping)"
                        fi
                    fi
                fi
            fi
        fi
    done
}

# Try to reload partition table and mappings for a given disk (/dev/sdX)
reload_disk_now() {
    local dev="$1"        # /dev/sdX
    local base=$(basename "$dev")  # sdX
    echo "  -> Reloading partition table and device mappings for $dev ..."

    # 1) Ask kernel to reread partition table
    if has_cmd partprobe; then
        partprobe "$dev" || true
    fi

    if has_cmd blockdev; then
        blockdev --rereadpt "$dev" || true
    fi

    # 2) kpartx update/remove/add
    if has_cmd kpartx; then
        # remove stale partition mappings, then try to add updated ones
        kpartx -d "$dev" >/dev/null 2>&1 || true
        udevadm settle --timeout=2 2>/dev/null || true
        kpartx -a "$dev" >/dev/null 2>&1 || true
    fi

    # 3) udev settle to ensure /dev entries created/removed
    if has_cmd udevadm; then
        udevadm settle --timeout=5 || true
    fi

    # 4) try SCSI device rescan (per-device and global)
    if [ -w "/sys/block/$base/device/rescan" ]; then
        echo 1 > "/sys/block/$base/device/rescan" || true
    fi

    # global SCSI host rescan (best-effort)
    for host in /sys/class/scsi_host/host*; do
        if [ -w "$host/scan" ]; then
            printf " - - -\n" > "$host/scan" || true
        fi
    done

    # 5) remove device-mapper objects which reference this disk (best-effort)
    remove_dm_using_disk "$base"

    # 6) wait and settle udev again
    if has_cmd udevadm; then
        udevadm settle --timeout=5 || true
    fi

    echo "  -> Reload attempts finished for $dev."
}

# ---------- main ----------
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <start_letter> <end_letter>"
    echo "Example: $0 b e   # will operate on /dev/sdb .. /dev/sde"
    exit 1
fi

START="$1"
END="$2"

# iterate letters from START..END
for letter in $(eval echo {$START..$END}); do
    DEVICE="/dev/sd${letter}"

    echo "========================================================"
    echo "Processing: $DEVICE"
    if [ ! -b "$DEVICE" ]; then
        echo "  -> $DEVICE does not exist or is not a block device. Skipping."
        continue
    fi

    # show current info
    if has_cmd lsblk; then
        lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$DEVICE"
    fi

    # detect LVM PV on the device
    if has_cmd pvs && pvs --noheadings -o pv_name 2>/dev/null | grep -qw "$DEVICE"; then
        echo "  -> Detected LVM PV on $DEVICE"
        if confirm "  Remove LVM PV and associated VG/LVs on $DEVICE? (y/n): "; then
            # find VG name(s) associated to this PV
            vgs_for_dev=$(pvs --noheadings -o vg_name "$DEVICE" 2>/dev/null | awk '{print $1}' | uniq || true)
            for vg in $vgs_for_dev; do
                if [ -n "$vg" ]; then
                    echo "    Removing LVs and VG: $vg"
                    if has_cmd lvremove; then
                        # remove all LVs in VG
                        lvremove -ff "/dev/$vg"* >/dev/null 2>&1 || true
                        vgremove -ff "$vg" >/dev/null 2>&1 || true
                    fi
                fi
            done
            if has_cmd pvremove; then
                pvremove -ff "$DEVICE" >/dev/null 2>&1 || true
            fi
            echo "  -> LVM cleanup done for $DEVICE"
        else
            echo "  -> Skipping LVM removal for $DEVICE"
        fi
    fi

    # detect RAID metadata
    if has_cmd mdadm && mdadm --examine "$DEVICE" >/dev/null 2>&1; then
        echo "  -> Detected mdadm RAID metadata on $DEVICE"
        if confirm "  Zero mdadm superblock on $DEVICE? (y/n): "; then
            mdadm --zero-superblock --force "$DEVICE" || true
            echo "  -> mdadm superblock zeroed."
        else
            echo "  -> Skipped mdadm zero."
        fi
    fi

    # detect Ceph signature via blkid
    if has_cmd blkid && blkid "$DEVICE" 2>/dev/null | grep -qi ceph; then
        echo "  -> Detected Ceph signature on $DEVICE"
        if confirm "  Overwrite small region to remove Ceph header on $DEVICE? (y/n): "; then
            dd if=/dev/zero of="$DEVICE" bs=1M count=10 conv=fsync status=none || true
            echo "  -> Wrote zero to beginning of $DEVICE"
        else
            echo "  -> Skipped Ceph scrub."
        fi
    fi

    # detect generic filesystem signature
    if has_cmd wipefs; then
        sigs=$(wipefs "$DEVICE" 2>/dev/null || true)
        if [ -n "$sigs" ]; then
            echo "  -> Filesystem/signature detected by wipefs:"
            echo "$sigs"
            if confirm "  wipefs -a on $DEVICE? (y/n): "; then
                wipefs -a -f "$DEVICE" || true
                echo "  -> wipefs finished on $DEVICE"
            else
                echo "  -> Skipped wipefs on $DEVICE"
            fi
        else
            echo "  -> No wipefs signatures found on $DEVICE"
        fi
    else
        echo "  -> wipefs not available, skipping wipefs step"
    fi

    # clear partition table (sgdisk)
    if has_cmd sgdisk; then
        if confirm "  Zap GPT/MBR partition table on $DEVICE using sgdisk? (y/n): "; then
            sgdisk --zap-all "$DEVICE" >/dev/null 2>&1 || true
            echo "  -> sgdisk zap-all executed"
        else
            echo "  -> Skipped sgdisk"
        fi
    fi

    # optionally zero small head/tail sections
    if confirm "  Zero 10MB at start and 10MB at end of $DEVICE? (recommended to remove any remaining metadata) (y/n): "; then
        # write head
        dd if=/dev/zero of="$DEVICE" bs=1M count=10 conv=fsync status=none || true
        # calculate seek for tail
        if has_cmd blockdev; then
            sectors=$(blockdev --getsz "$DEVICE" 2>/dev/null || echo 0)
            if [ "$sectors" -gt 20480 ]; then
                # sectors are 512B, so convert to 1M blocks: total_mb = sectors*512 / (1024*1024) ~= sectors/2048
                total_mb=$(( sectors / 2048 ))
                tail_seek=$(( total_mb - 10 ))
                if [ "$tail_seek" -gt 0 ]; then
                    dd if=/dev/zero of="$DEVICE" bs=1M count=10 seek="$tail_seek" conv=fsync status=none || true
                fi
            fi
        fi
        echo "  -> Head and tail zeroing attempted."
    else
        echo "  -> Skipped head/tail zeroing."
    fi

    # attempt a robust reload of kernel view / udev
    reload_disk_now "$DEVICE"

    echo "Finished processing $DEVICE"
    echo
done

echo "All done."
