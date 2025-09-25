#!/usr/bin/env bash
# disk-wipefs.sh v7.1
# Purpose: Wipe disk sạch sẽ, chỉ target disk được chỉ định
# Credits: ChatGPT & TrungLun0112

set -euo pipefail

VERSION="7.1"
LOG_PREFIX="$(date '+%Y-%m-%d %H:%M:%S') [INFO]"

# ===== Helpers =====
info()  { echo "${LOG_PREFIX} $*"; }
ok()    { echo "$(date '+%Y-%m-%d %H:%M:%S') [OK] $*"; }
err()   { echo "$(date '+%Y-%m-%d %H:%M:%S') [ERR] $*" >&2; exit 1; }

# ===== Usage =====
usage() {
  echo "Usage: $0 <disk> (ví dụ: $0 sdb)"
  exit 1
}

# ===== Main =====
[ $# -ne 1 ] && usage
DISK="$1"
TARGET="/dev/${DISK}"

info "disk-wipefs v${VERSION} starting"
info "Credits: ChatGPT & TrungLun0112"

# Check OS
OS=$(lsb_release -d 2>/dev/null | awk -F"\t" '{print $2}')
info "Detected OS: ${OS:-Unknown}"

# Check tools
for t in lsblk umount swapoff wipefs sgdisk dd blkdiscard pvs vgs vgchange mdadm zpool multipath; do
    command -v $t >/dev/null 2>&1 || err "Thiếu tool: $t"
done
ok "All essential tools present"

# Validate disk
[ ! -b "$TARGET" ] && err "Disk $TARGET không tồn tại hoặc không hợp lệ"
ok "Target $TARGET hợp lệ"

# 1. Unmount partitions thuộc target
info "Unmount partitions của $DISK ..."
mount | grep "^/dev/${DISK}" | awk '{print $1}' | xargs -r umount -f

# 2. Tắt swap trên target
info "Tắt swap liên quan $DISK ..."
swapoff ${TARGET}?* 2>/dev/null || true

# 3. Deactivate LVM chỉ target
info "Deactivate LVM trên $DISK ..."
for pv in $(pvs --noheadings -o pv_name 2>/dev/null | grep "^/dev/${DISK}"); do
    vg=$(pvs --noheadings -o vg_name $pv 2>/dev/null | xargs)
    [ -n "$vg" ] && vgchange -an "$vg"
    wipefs -a -f "$pv" || true
done

# 4. mdadm superblock chỉ target
info "Zero RAID superblock trên $DISK ..."
mdadm --zero-superblock ${TARGET}?* 2>/dev/null || true

# 5. ZFS labelclear chỉ target
info "Clear ZFS label trên $DISK ..."
for part in $(ls ${TARGET}?* 2>/dev/null || true); do
    zpool labelclear -f "$part" 2>/dev/null || true
done

# 6. Multipath flush nếu có target
info "Flush multipath trên $DISK ..."
for mp in $(multipath -ll 2>/dev/null | grep "/dev/${DISK}" | awk '{print $1}'); do
    multipath -f "$mp" || true
done

# 7. wipefs
info "Running wipefs ..."
wipefs -a -f "$TARGET"

# 8. Zap GPT/MBR
info "Zap GPT/MBR ..."
sgdisk --zap-all "$TARGET" || true

# 9. Zero head & tail
info "Zero head & tail ..."
dd if=/dev/zero of="$TARGET" bs=1M count=10 conv=fsync status=none
dd if=/dev/zero of="$TARGET" bs=1M count=10 seek=$(( $(blockdev --getsz "$TARGET") / 2048 - 10 )) conv=fsync status=none || true

# 10. Discard blocks (nếu hỗ trợ)
info "Discard blocks (nếu hỗ trợ) ..."
blkdiscard "$TARGET" 2>/dev/null || true

# 11. Reload kernel view
info "Reload kernel view ..."
partprobe "$TARGET" 2>/dev/null || true

ok "Disk $TARGET wiped sạch sẽ"
ok "Wipe completed. Run 'lsblk' để verify."
