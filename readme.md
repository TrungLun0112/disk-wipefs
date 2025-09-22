```
Cài git make:
apt install git make gcc -y

Clone nó:
git clone https://github.com/TrungLun0112/disk-wipefs.git
cd disk-wipefs
chmod +x disk-wipefs.sh
```

# 🧹 disk-wipefs

A powerful and safe disk wipe utility script.  
Written by **ChatGPT** & **TrungLun0112**.  
👉 Repo: [disk-wipefs](https://github.com/TrungLun0112/disk-wipefs)

---

## ⚠️ Warning

This script is **destructive**.  
It will erase all filesystem / RAID / LVM / Ceph / ZFS traces from the selected disks.  
Use it **only if you are 100% sure** you want to wipe the disks.  
Always double-check the target devices before running.

---

## ✨ Features

- Verbose logging with colors and clear step-by-step actions.
- Confirmation mode (`--manual`) or fully automatic mode (`--auto`).
- Skip dangerous devices by default:
  - `/dev/sda` (system disk, unless `--force` is given).
  - `/dev/loop*`, `/dev/sr*` (optical / loop devices).
  - `/dev/dm-*`, `/dev/mapper/*` (device-mapper).
- Support for:
  - **Ceph OSD zap** (`--zap-ceph`).
  - **ZFS label clear** (`--zap-zfs`).
- Disk reload after wipe:
  - `partprobe`, `blockdev --rereadpt`, `kpartx -u`, and SCSI rescan.
- Pattern matching (e.g., `sd*`, `nvme*`, `vd*`, `mmcblk*`).
- Exclude disks when running `all` (e.g., `-sda`, `-nvme0n1`).
- Trap `Ctrl+C` to exit safely with a warning message.

---

## 🚀 Usage

```bash
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
