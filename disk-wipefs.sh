#!/bin/bash
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case $level in
        "INFO")  echo -e "${BLUE}[INFO] ${timestamp}: ${message}${NC}" ;;
        "WARN")  echo -e "${YELLOW}[WARN] ${timestamp}: ${message}${NC}" ;;
        "ERROR") echo -e "${RED}[ERROR] ${timestamp}: ${message}${NC}" ;;
        "OK")    echo -e "${GREEN}[OK] ${timestamp}: ${message}${NC}" ;;
    esac
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root (use sudo)."
        exit 1
    fi
}

# Detect OS and package manager
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        log "INFO" "Detected OS: $OS"
    else
        log "ERROR" "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi
}

# Check and install required tools
check_install_tools() {
    local tools=("wipefs" "sgdisk" "mdadm" "pvremove" "vgremove" "lvremove" "partprobe" "blockdev" "udevadm")
    local missing_tools=()
    local pkg_manager=""
    local install_cmd=""

    # Determine package manager
    case $OS in
        ubuntu|debian)
            pkg_manager="apt"
            install_cmd="apt install -y"
            ;;
        centos|rhel|rocky|alma)
            pkg_manager="yum"
            install_cmd="yum install -y"
            ;;
        fedora)
            pkg_manager="dnf"
            install_cmd="dnf install -y"
            ;;
        suse|opensuse*)
            pkg_manager="zypper"
            install_cmd="zypper install -y"
            ;;
        arch)
            pkg_manager="pacman"
            install_cmd="pacman -S --noconfirm"
            ;;
        *)
            log "ERROR" "Unsupported OS: $OS"
            exit 1
            ;;
    esac

    # Check for missing tools
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
        fi
    done

    # Check for ceph-volume and zfsutils
    if ! command -v ceph-volume &>/dev/null; then
        missing_tools+=("ceph-volume")
    fi
    if ! command -v zpool &>/dev/null; then
        missing_tools+=("zfsutils")
    fi

    # Install missing tools
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log "INFO" "Missing tools: ${missing_tools[*]}. Installing..."

        # Fix CDROM issue for apt-based systems
        if [[ $pkg_manager == "apt" ]]; then
            log "INFO" "Checking and fixing CDROM in /etc/apt/sources.list..."
            sed -i '/cdrom/s/^/#/' /etc/apt/sources.list || log "WARN" "Failed to fix CDROM sources."
            apt update || { log "ERROR" "Failed to run apt update."; exit 1; }
        fi

        # Install packages
        case $OS in
            ubuntu|debian)
                $install_cmd util-linux parted mdadm lvm2 ceph zfsutils-linux
                ;;
            centos|rhel|rocky|alma)
                $install_cmd util-linux parted mdadm lvm2 cephadm zfsutils
                ;;
            fedora)
                $install_cmd util-linux parted mdadm lvm2 ceph zfs
                ;;
            suse|opensuse*)
                $install_cmd util-linux parted mdadm lvm2 ceph zfsutils
                ;;
            arch)
                $install_cmd util-linux parted mdadm lvm2 ceph zfsutils
                ;;
        esac
        log "OK" "Required tools installed."
    else
        log "INFO" "All required tools are already installed."
    fi
}

# Wipe disk function
wipe_disk() {
    local disk=$1
    log "INFO" "Processing disk: /dev/$disk"

    # Unmount any partitions
    for part in /dev/"$disk"[0-9]*; do
        if [[ -e "$part" ]]; then
            if mountpoint -q "$part"; then
                log "INFO" "Unmounting $part"
                umount "$part" || log "WARN" "Failed to unmount $part"
            fi
        done
    done

    # Wipe filesystem signatures
    log "INFO" "Wiping filesystem signatures on /dev/$disk"
    wipefs -a "/dev/$disk" || log "WARN" "Failed to wipe filesystem signatures on /dev/$disk"

    # Wipe partition table
    log "INFO" "Wiping partition table on /dev/$disk"
    sgdisk --zap-all "/dev/$disk" || log "WARN" "Failed to wipe partition table on /dev/$disk"

    # Wipe RAID superblock
    if mdadm --examine "/dev/$disk" &>/dev/null; then
        log "INFO" "Wiping RAID superblock on /dev/$disk"
        mdadm --zero-superblock "/dev/$disk" || log "WARN" "Failed to wipe RAID superblock on /dev/$disk"
    fi

    # Wipe LVM metadata
    if pvdisplay "/dev/$disk" &>/dev/null; then
        log "INFO" "Wiping LVM metadata on /dev/$disk"
        lvremove -f /dev/*/* || true
        vgremove -f /dev/* || true
        pvremove -f "/dev/$disk" || log "WARN" "Failed to wipe LVM metadata on /dev/$disk"
    fi

    # Wipe Ceph OSD
    if ceph-volume lvm list "/dev/$disk" &>/dev/null; then
        log "INFO" "Wiping Ceph OSD on /dev/$disk"
        ceph-volume lvm zap --destroy "/dev/$disk" || log "WARN" "Failed to wipe Ceph OSD on /dev/$disk"
    fi

    # Wipe ZFS labels
    if zpool import -d "/dev/$disk" &>/dev/null; then
        log "INFO" "Wiping ZFS labels on /dev/$disk"
        zpool labelclear -f "/dev/$disk" || log "WARN" "Failed to wipe ZFS labels on /dev/$disk"
    fi

    # Wipe residual data (10MB at start and end)
    log "INFO" "Wiping 10MB at start and end of /dev/$disk"
    dd if=/dev/zero of="/dev/$disk" bs=1M count=10 status=none || log "WARN" "Failed to wipe start of /dev/$disk"
    dd if=/dev/zero of="/dev/$disk" bs=1M count=10 seek=$(( $(blockdev --getsize64 "/dev/$disk") / 1048576 - 10 )) status=none || log "WARN" "Failed to wipe end of /dev/$disk"

    # Reload disk table
    log "INFO" "Reloading disk table for /dev/$disk"
    partprobe "/dev/$disk" || log "WARN" "Failed to run partprobe on /dev/$disk"
    blockdev --rereadpt "/dev/$disk" || log "WARN" "Failed to run blockdev --rereadpt on /dev/$disk"
    udevadm trigger || log "WARN" "Failed to run udevadm trigger"
    log "OK" "Disk /dev/$disk wiped successfully."
}

# Get list of disks to process
get_disks() {
    local pattern=$1
    local exclude_list=$2
    local disks=()

    # Get all disks matching pattern
    if [[ "$pattern" == "all" ]]; then
        mapfile -t disks < <(ls /dev/{sd*,nvme*,vd*,mmcblk*} 2>/dev/null | grep -vE 'sda|sr|dm|loop|mapper' | sed 's|/dev/||')
    else
        mapfile -t disks < <(ls /dev/$pattern 2>/dev/null | grep -vE 'sda|sr|dm|loop|mapper' | sed 's|/dev/||')
    fi

    # Apply exclude list
    if [[ -n "$exclude_list" ]]; then
        local filtered_disks=()
        IFS=',' read -ra exclude_arr <<< "$exclude_list"
        for disk in "${disks[@]}"; do
            local skip=false
            for exclude in "${exclude_arr[@]}"; do
                if [[ "$disk" == "$exclude" ]]; then
                    skip=true
                    break
                fi
            done
            [[ "$skip" == false ]] && filtered_disks+=("$disk")
        done
        disks=("${filtered_disks[@]}")
    fi

    echo "${disks[@]}"
}

# Display help
show_help() {
    cat << EOF
Usage: $0 [options] [disk1 disk2 ... | pattern | all]

Options:
  --auto           Run automatically without confirmation for each disk.
  --manual         Prompt for confirmation for each disk (default).
  --all            Wipe all disks (excludes sda unless --force specified).
  --force          Allow wiping sda (dangerous).
  --exclude <list> Comma-separated list of disks to exclude (e.g., sda,nvme0n1).
  --help           Show this help message.

Examples:
  Wipe specific disks: sudo $0 sdb nvme0n1
  Wipe all disks (except sda): sudo $0 all --auto
  Wipe disks matching pattern: sudo $0 sd*
  Wipe all disks including sda: sudo $0 all --force --auto
EOF
    exit 0
}

# Main function
main() {
    check_root
    detect_os
    check_install_tools

    local mode="manual"
    local force_sda=false
    local exclude_list=""
    local disks=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --auto) mode="auto"; shift ;;
            --manual) mode="manual"; shift ;;
            --force) force_sda=true; shift ;;
            --exclude) exclude_list="$2"; shift 2 ;;
            --help) show_help ;;
            *) disks+=("$1"); shift ;;
        esac
    done

    # Default to all disks if no disks or pattern specified
    if [[ ${#disks[@]} -eq 0 ]]; then
        disks=("all")
    fi

    # Process each disk or pattern
    for pattern in "${disks[@]}"; do
        local disk_list=($(get_disks "$pattern" "$exclude_list"))
        if [[ ${#disk_list[@]} -eq 0 ]]; then
            log "WARN" "No disks found matching pattern: $pattern"
            continue
        fi

        for disk in "${disk_list[@]}"; do
            # Skip sda unless --force is specified
            if [[ "$disk" == "sda" && "$force_sda" == "false" ]]; then
                log "WARN" "Skipping sda (use --force to wipe sda)."
                continue
            fi

            # Check if disk exists
            if [[ ! -e "/dev/$disk" ]]; then
                log "ERROR" "Disk /dev/$disk does not exist."
                continue
            fi

            # Confirm wipe in manual mode
            if [[ "$mode" == "manual" ]]; then
                read -p "Wipe /dev/$disk? (y/N): " confirm
                [[ "$confirm" != "y" && "$confirm" != "Y" ]] && continue
            fi

            wipe_disk "$disk"
        done
    done

    log "OK" "Disk wiping process completed. Check results with lsblk."
}

# Run main
main "$@"
