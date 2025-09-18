#!/bin/bash
# Usage: ./disk_cleaner.sh b z
# Quét từ /dev/sdb -> /dev/sdz (có confirm y/n từng ổ)

start=$1
end=$2

for letter in $(eval echo {$start..$end}); do
    disk="/dev/sd$letter"
    size=$(blockdev --getsz $disk)   # tổng sector
    echo ""
    echo ">>> Phát hiện ổ $disk"
    read -p "Bạn có muốn xoá dữ liệu trên $disk không? (y/n): " confirm

    if [[ "$confirm" != "y" ]]; then
        echo "   -> Bỏ qua $disk"
        continue
    fi

    echo ">>> Đang xử lý $disk ..."

    # 1. LVM
    if pvs --noheadings -o pv_name 2>/dev/null | grep -qw "$disk"; then
        vg=$(pvs --noheadings -o vg_name $disk | xargs)
        lvremove -y $vg >/dev/null 2>&1
        vgremove -y $vg >/dev/null 2>&1
        pvremove -y $disk >/dev/null 2>&1
        echo "   -> Xoá LVM PV + VG + LV"
    fi

    # 2. RAID
    if mdadm --examine $disk >/dev/null 2>&1; then
        mdadm --zero-superblock $disk >/dev/null 2>&1
        echo "   -> Xoá RAID superblock"
    fi

    # 3. Ceph OSD
    if command -v ceph-volume >/dev/null 2>&1; then
        if ceph-volume lvm list $disk >/dev/null 2>&1; then
            ceph-volume lvm zap $disk --destroy >/dev/null 2>&1
            echo "   -> Xoá Ceph OSD metadata"
        fi
    fi

    # 4. ZFS label
    if command -v zpool >/dev/null 2>&1; then
        zpool labelclear -f $disk >/dev/null 2>&1
        echo "   -> Xoá ZFS label"
    fi

    # 5. Wipefs & GPT/MBR
    wipefs -a -f $disk >/dev/null 2>&1
    sgdisk --zap-all $disk >/dev/null 2>&1
    echo "   -> Xoá GPT/MBR"

    # 6. Xoá đầu & cuối đĩa
    dd if=/dev/zero of=$disk bs=1M count=10 conv=fdatasync >/dev/null 2>&1
    dd if=/dev/zero of=$disk bs=1M count=10 seek=$((size/2048 - 10)) conv=fdatasync >/dev/null 2>&1
    echo "   -> Đã xoá 10MB đầu và 10MB cuối"

    echo ">>> Hoàn tất $disk"
done
