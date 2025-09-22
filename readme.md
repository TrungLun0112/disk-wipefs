```
Cài git make:
apt install git make gcc -y

Clone nó:
git clone https://github.com/TrungLun0112/disk-wipefs.git
cd disk-wipefs
chmod +x disk-wipefs.sh

# Wipe specific disks
./disk-wipefs.sh sdb nvme0n1 vda

# Wipe all disks except exclusions
./disk-wipefs.sh all -sda -nvme0n1

# Pattern matching
./disk-wipefs.sh sd* nvme* vd* mmcblk*

# Auto mode (no confirmation)
./disk-wipefs.sh --auto sdb sdc

# Manual mode (default, confirm each)
./disk-wipefs.sh --manual sdb sdc

# Force wipe /dev/sda
./disk-wipefs.sh --force sda

# With Ceph/ZFS cleanup
./disk-wipefs.sh --zap-ceph --zap-zfs nvme0n1

```
