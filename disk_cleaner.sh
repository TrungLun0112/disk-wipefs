#!/bin/bash
# Disk Cleaner Script - Xóa sạch dấu vết LVM, RAID, Ceph OSD, filesystem trên các ổ đĩa
# Tác giả: TrungLun0112
# Repo: https://github.com/TrungLun0112/disk-wipefs

# Kiểm tra tham số
if [ $# -ne 2 ]; then
    echo "Usage: $0 <start_letter> <end_letter>"
    echo "Ví dụ: $0 b z   # kiểm tra từ /dev/sdb đến /dev/sdz"
    exit 1
fi

START=$1
END=$2

for DRIVE in $(eval echo {$START..$END}); do
    DEV="/dev/sd$DRIVE"
    if [ ! -b "$DEV" ]; then
        echo "❌ Bỏ qua $DEV (không tồn tại)"
        continue
    fi

    echo "🔍 Kiểm tra ổ đĩa: $DEV"

    CLEAN=false

    # Kiểm tra LVM PV
    if pvs "$DEV" &>/dev/null; then
        echo "  -> Phát hiện LVM PV trên $DEV"
        vg=$(pvs --noheadings -o vg_name "$DEV" | awk '{print $1}')
        if [ -n "$vg" ]; then
            echo "  -> Xóa VG: $vg"
            vgremove -ff "$vg"
        fi
        pvremove -ff "$DEV"
        CLEAN=true
    fi

    # Kiểm tra RAID
    if mdadm --examine "$DEV" &>/dev/null; then
        echo "  -> Phát hiện RAID member trên $DEV"
        mdadm --zero-superblock --force "$DEV"
        CLEAN=true
    fi

    # Kiểm tra Ceph OSD
    if blkid "$DEV" | grep -qi ceph; then
        echo "  -> Phát hiện Ceph OSD trên $DEV"
        dd if=/dev/zero of="$DEV" bs=1M count=10 conv=fsync
        CLEAN=true
    fi

    # Kiểm tra filesystem thông thường
    if blkid "$DEV" | grep -q 'TYPE='; then
        echo "  -> Phát hiện filesystem trên $DEV"
        CLEAN=true
    fi

    if [ "$CLEAN" = true ]; then
        read -p "⚠️ Bạn có chắc muốn xóa sạch $DEV? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "  -> Đang wipefs $DEV ..."
            wipefs -a -f "$DEV"
            echo "✅ Đã làm sạch $DEV"
        else
            echo "⏭️ Bỏ qua $DEV"
        fi
    else
        echo "ℹ️ Không phát hiện dấu vết đặc biệt trên $DEV"
    fi

    echo "--------------------------------------"
done
