~~~
CLONE
git clone https://github.com/TrungLun0112/disk-wipefs.git
cd disk-wipefs
chmod +x disk-wipefs.sh

###############################

disk-wipefs.sh - Advanced Disk Wiping Script

PURPOSE:
    Completely wipe disk metadata, partition tables, RAID, LVM, Ceph, ZFS and residual data

USAGE:
    disk-wipefs.sh [options] [disk1] [disk2] ...
    disk-wipefs.sh all [options]
    disk-wipefs.sh pattern [options]

OPTIONS:
    --auto         Automatic mode, no confirmation prompts
    --manual       Manual mode, ask Y/N for each disk (default)
    --all          Target all available disks (excludes sda by default)
    --force        Allow wiping sda (DANGEROUS!)
    --exclude list Comma-separated list of disks to exclude (e.g. sda,nvme0n1)
    --help         Show this help message

EXAMPLES:
    sudo disk-wipefs.sh sdb nvme0n1                    # Wipe specific disks
    sudo disk-wipefs.sh all --auto                     # Auto wipe all disks except sda
    sudo disk-wipefs.sh sd* --auto                     # Auto wipe all sd* disks
    sudo disk-wipefs.sh all --force --auto             # Wipe ALL disks including sda
    sudo disk-wipefs.sh all --exclude sda,nvme0n1      # Wipe all except specified disks

SUPPORTED DISK TYPES:
    - SATA/SCSI: sd*
    - NVMe: nvme*
    - Virtual: vd*
    - MMC: mmcblk*

EXCLUDED BY DEFAULT:
    - sda (unless --force used)
    - sr* (optical drives)
    - dm* (device mapper)
    - loop* (loop devices)
    - mapper/* (multipath devices)

CAUTION:
    This script will PERMANENTLY DESTROY all data on target disks!
    Use with extreme caution, especially with --force flag.


~~~
