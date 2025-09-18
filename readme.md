git clone https://github.com/TrungLun0112/disk-wipefs.git
cd disk-wipefs
chmod +x disk_cleaner.sh

./disk_cleaner.sh b e

rong ví dụ trên:

Script sẽ quét từ /dev/sdb → /dev/sde.

Mỗi ổ trước khi xoá sẽ có confirm (y/n) để tránh nhầm lẫn.

Nếu muốn quét toàn bộ từ /dev/sdb → /dev/sdz:

./disk_cleaner.sh b z


Các “dấu vết” thường gặp trên ổ đĩa

Ổ đĩa từng dùng trong môi trường server có thể chứa nhiều metadata “ẩn”, gây lỗi khi cài đặt lại hoặc tái sử dụng. Script này xử lý tự động các trường hợp phổ biến:

Partition table

GPT / MBR

Xử lý: wipefs -a + sgdisk --zap-all

RAID superblock

Metadata của mdadm (RAID software)

Xử lý: mdadm --zero-superblock

LVM metadata

Physical Volume (PV), Volume Group (VG), Logical Volume (LV)

Xử lý: pvremove, vgremove, lvremove

Ceph OSD

Metadata của Ceph cluster

Xử lý: ceph-volume lvm zap --destroy

ZFS labels

Thông tin ZFS pool

Xử lý: zpool labelclear -f

Residual data

Nhiều hệ thống (RAID, ZFS, Ceph) lưu metadata ở đầu và cuối đĩa

Xử lý: dd if=/dev/zero ghi đè 10MB đầu và cuối
