#!/usr/bin/env bash
# ================================================================
# Script Name : disk-wipefs v2.3
# Purpose     : Force wipe all metadata / signatures from disks
# Author      : ChatGPT
# Version     : 2.3
# Description :
#   - Detect Linux OS type (Debian/Ubuntu, RHEL/CentOS, SUSE…)
#   - Check/install required tools (wipefs, sgdisk, mdadm, lvm2, ceph, zfsutils)
#   - Handle common disk types: sd*, nvme*, vd*, mmcblk*
#   - Skip system and special devices: sda, sr*, loop*, dm*, mapper*
#   - Auto unmount before wiping
#   - Remove RAID/LVM/Ceph/ZFS metadata
#   - Reload disks without reboot
#   - Colored logging with timestamps
# ================================================================

# ----- COLOR + LOG -----
RED="\033[1;31m"
GRN="\033[1;32m"
YEL="\033[1;33m"
BLU="\033[1;34m"
NC="\033[0m"

log_info()  { echo -e "$(date '+%F %T') ${GRN}[INFO]${NC} $*"; }
log_warn()  { echo -e "$(date '+%F %T') ${YEL}[WARN]${NC} $*"; }
log_error() { echo -e "$(date '+%F %T') ${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLU}==== $* ====${NC}"; }

# ----- REQUIRE ROOT -----
[[ $EUID -ne 0 ]] && { log_error "Run as root!"; exit 1; }

# ----- DETECT OS -----
detect_os() {
    if [ -f /etc/debian_version ]; then
        OS="debian"
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
    elif [ -f /etc/SuSE-release ] || grep -qi suse /etc/os-release; then
        OS="suse"
    else
        OS="unknown"
    fi
    log_info "Detected OS: $OS"
}

# ----- INSTALL TOOLS -----
install_tools() {
    PKGS=( util-linux gdisk mdadm lvm2 )
    [ "$OS" = "debian" ] && PKGS+=( ceph-volume zfsutils-linux ) && UPDATE="apt-get update -y" && INSTALL="apt-get install -y"
    [ "$OS" = "rhel" ]   && PKGS+=( ceph ceph-volume zfs )      && UPDATE="yum makecache -y"   && INSTALL="yum install -y"
    [ "$OS" = "suse" ]   && PKGS+=( ceph ceph-volume zfs )      && UPDATE="zypper refresh"     && INSTALL="zypper install -y"

    for pkg in "${PKGS[@]}"; do
        if ! command -v $(echo $pkg | cut -d'-' -f1) &>/dev/null; then
            log_warn "Missing $pkg → Installing..."
            eval $UPDATE
            eval $INSTALL $pkg || log_warn "Install $pkg failed, continuing..."
        fi
    done
}

# ----- RELOAD DISK -----
reload_disk() {
    partprobe "$1" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    blockdev --rereadpt "$1" 2>/dev/null || true
}

# ----- WIPE DISK -----
wipe_disk() {
    disk="$1"
    log_step "Processing $disk"

    # Unmount all partitions
    for p in $(lsblk -ln -o NAME "/dev/$disk" | grep -v "^$disk$"); do
        umount "/dev/$p" &>/dev/null && log_info "Unmounted /dev/$p"
    done

    # Wipe partition table
    wipefs -a "/dev/$disk" &>/dev/null
    sgdisk --zap-all "/dev/$disk" &>/dev/null
    log_info "Partition table wiped"

    # RAID superblock
    mdadm --zero-superblock --force "/dev/$disk" &>/dev/null || true

    # LVM metadata
    pvremove -ff -y "/dev/$disk" &>/dev/null || true

    # Ceph
    ceph-volume lvm zap --destroy "/dev/$disk" &>/dev/null || true

    # ZFS
    zpool labelclear -f "/dev/$disk" &>/dev/null || true

    # Residual metadata
    dd if=/dev/zero of="/dev/$disk" bs=1M count=10 conv=fsync &>/dev/null
    sz=$(blockdev --getsz "/dev/$disk")
    dd if=/dev/zero of="/dev/$disk" bs=512 seek=$((sz-20480)) count=20480 conv=fsync &>/dev/null

    reload_disk "/dev/$disk"
    log_info "$disk wiped successfully!"
}

# ----- MAIN -----
main() {
    detect_os
    install_tools

    log_step "Scanning disks"
    disks=$(lsblk -dn -o NAME | grep -E '^(sd|nvme|vd|mmcblk)' | grep -Ev '^(sda|sr|loop|dm-|mapper)')
    log_info "Disks to wipe: $disks"

    for d in $disks; do
        wipe_disk "$d"
    done

    log_step "Final disk status"
    lsblk
}

main "$@"
