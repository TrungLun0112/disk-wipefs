#!/bin/bash
set -euo pipefail

# Color codes for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

# Default excluded disks (always excluded unless --force is used for sda)
# sr*: CD/DVD drives, dm*: device mapper, loop*: loop devices, mapper*: LVM mappings
DEFAULT_EXCLUDED=("sr*" "dm*" "loop*" "mapper*")
USER_EXCLUDED=()
TARGET_DISKS=()
AUTO_MODE=false
FORCE_MODE=false
MANUAL_MODE=true

# Detect OS and package manager
detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        case $ID in
            ubuntu|debian)
                OS="debian"
                PM="apt-get"
                ;;
            centos|rhel|rocky|almalinux|fedora)
                OS="rhel"
                if command -v dnf >/dev/null; then
                    PM="dnf"
                else
                    PM="yum"
                fi
                ;;
            opensuse*|suse)
                OS="suse"
                PM="zypper"
                ;;
            arch)
                OS="arch"
                PM="pacman"
                ;;
            *)
                log_error "Unsupported OS: $ID"
                exit 1
                ;;
        esac
        log_info "Detected OS: $NAME ($ID)"
    else
        log_error "Cannot detect OS"
        exit 1
    fi
}

# Fix CDROM source list issue on Debian/Ubuntu
fix_cdrom_error() {
    if [[ "$OS" == "debian" ]]; then
        if grep -q "deb cdrom:" /etc/apt/sources.list; then
            log_warn "Fixing CDROM source list..."
            sed -i '/deb cdrom:/s/^/#/' /etc/apt/sources.list
        fi
    fi
}

# Install required packages
install_dependencies() {
    local packages=()
    
    # Check what's missing
    if ! command -v wipefs >/dev/null; then packages+=("util-linux"); fi
    if ! command -v sgdisk >/dev/null; then packages+=("gdisk"); fi
    if ! command -v mdadm >/dev/null; then packages+=("mdadm"); fi
    if ! command -v lvs >/dev/null; then packages+=("lvm2"); fi
    if ! command -v ceph-volume >/dev/null; then packages+=("ceph-common"); fi
    if ! command -v zpool >/dev/null; then packages+=("zfsutils-linux" "zfs-utils"); fi
    if ! command -v partprobe >/dev/null; then packages+=("parted"); fi
    if ! command -v udevadm >/dev/null; then packages+=("systemd" "udev"); fi

    if [[ ${#packages[@]} -eq 0 ]]; then
        log_ok "All required tools are available"
        return 0
    fi

    log_warn "Installing missing packages: ${packages[*]}"
    fix_cdrom_error

    case $OS in
        debian)
            apt-get update
            apt-get install -y "${packages[@]}"
            ;;
        rhel)
            $PM install -y "${packages[@]}"
            ;;
        suse)
            zypper --non-interactive install "${packages[@]}"
            ;;
        arch)
            pacman -Sy --noconfirm "${packages[@]}"
            ;;
    esac

    log_ok "Dependencies installed successfully"
}

# Get all available disks (including sda, but it will be filtered later)
get_all_disks() {
    local disks=()
    local patterns=("sd*" "nvme*" "vd*" "mmcblk*")
    
    for pattern in "${patterns[@]}"; do
        for disk in /dev/$pattern; do
            if [[ -b "$disk" ]]; then
                disks+=("$(basename "$disk")")
            fi
        done
    done
    
    printf '%s\n' "${disks[@]}"
}

# Enhanced disk exclusion check
is_disk_excluded() {
    local disk=$1
    
    # Always exclude special devices regardless of force mode
    for pattern in "${DEFAULT_EXCLUDED[@]}"; do
        if [[ "$disk" == $pattern ]]; then
            log_info "Excluding special device: /dev/$disk"
            return 0
        fi
    done
    
    # Check user excluded patterns
    for pattern in "${USER_EXCLUDED[@]}"; do
        if [[ "$disk" == $pattern ]]; then
            log_info "Excluding user-specified device: /dev/$disk"
            return 0
        fi
    done
    
    # Special handling for sda - only allow with --force
    if [[ "$disk" == "sda" && "$FORCE_MODE" != "true" ]]; then
        log_warn "Excluding /dev/sda (use --force to override)"
        return 0
    fi
    
    return 1
}

# Safe disk pattern expansion with exclusion checking
expand_disk_patterns() {
    local patterns=("$@")
    local expanded=()
    local final_disks=()
    
    for pattern in "${patterns[@]}"; do
        if [[ "$pattern" == "all" ]]; then
            # Get all disks and filter exclusions
            mapfile -t all_disks < <(get_all_disks)
            for disk in "${all_disks[@]}"; do
                if ! is_disk_excluded "$disk"; then
                    expanded+=("$disk")
                fi
            done
        elif [[ $pattern == *"*"* ]]; then
            # Expand wildcard patterns
            for disk in /dev/$pattern; do
                if [[ -b "$disk" ]]; then
                    disk_name=$(basename "$disk")
                    if ! is_disk_excluded "$disk_name"; then
                        expanded+=("$disk_name")
                    fi
                fi
            done
        else
            # Specific disk name
            if [[ -b "/dev/$pattern" ]]; then
                if ! is_disk_excluded "$pattern"; then
                    expanded+=("$pattern")
                else
                    log_warn "Disk /dev/$pattern is excluded, skipping"
                fi
            else
                log_warn "Disk /dev/$pattern not found, skipping"
            fi
        fi
    done
    
    # Remove duplicates and return
    printf '%s\n' "${expanded[@]}" | sort -u
}

# Stop any processes using the disk
stop_disk_processes() {
    local disk=$1
    log_info "Stopping processes using /dev/$disk"
    
    # Kill processes using the disk or its partitions
    for partition in "/dev/$disk" "/dev/${disk}[0-9]*" "/dev/${disk}p[0-9]*"; do
        if ls $partition >/dev/null 2>&1; then
            for dev in $partition; do
                if [[ -b "$dev" ]]; then
                    # Find and kill processes
                    local pids=$(lsof +f -- "$dev" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u)
                    if [[ -n "$pids" ]]; then
                        log_warn "Killing processes using $dev: $pids"
                        kill -9 $pids 2>/dev/null || true
                    fi
                    
                    # Use fuser if available
                    if command -v fuser >/dev/null; then
                        fuser -k -s "$dev" 2>/dev/null || true
                    fi
                fi
            done
        fi
    done
    
    sleep 2
}

# Unmount any filesystems on disk
unmount_disk() {
    local disk=$1
    log_info "Unmounting filesystems on /dev/$disk"
    
    # Unmount all partitions
    for partition in "/dev/${disk}[0-9]*" "/dev/${disk}p[0-9]*"; do
        if ls $partition >/dev/null 2>&1; then
            for part in $partition; do
                if [[ -b "$part" ]]; then
                    local mountpoint=$(findmnt -n -o TARGET "$part" 2>/dev/null || true)
                    if [[ -n "$mountpoint" ]]; then
                        log_warn "Unmounting $part from $mountpoint"
                        umount -lf "$part" 2>/dev/null || true
                    fi
                fi
            done
        fi
    done
    
    # Also try to unmount the disk itself
    local mountpoint=$(findmnt -n -o TARGET "/dev/$disk" 2>/dev/null || true)
    if [[ -n "$mountpoint" ]]; then
        log_warn "Unmounting /dev/$disk from $mountpoint"
        umount -lf "/dev/$disk" 2>/dev/null || true
    fi
    
    sleep 2
}

# Remove LVM signatures
remove_lvm() {
    local disk=$1
    log_info "Removing LVM signatures from /dev/$disk"
    
    # Deactivate any volume groups on this disk
    for vg in $(pvs --noheadings -o vg_name "/dev/$disk" 2>/dev/null | sed 's/^[[:space:]]*//'); do
        if [[ -n "$vg" ]]; then
            log_warn "Deactivating volume group: $vg"
            vgchange -an "$vg" 2>/dev/null || true
            sleep 1
        fi
    done
    
    # Remove physical volumes
    if pvs "/dev/$disk" >/dev/null 2>&1; then
        log_warn "Removing physical volume: /dev/$disk"
        pvremove -ff -y "/dev/$disk" 2>/dev/null || true
    fi
    
    # Wipe LVM signatures
    wipefs -a "/dev/$disk" 2>/dev/null || true
    
    # Additional LVM signature removal
    dd if=/dev/zero of="/dev/$disk" bs=512 count=8 seek=1 conv=notrunc 2>/dev/null || true
}

# Remove MD RAID signatures
remove_mdraid() {
    local disk=$1
    if mdadm --examine "/dev/$disk" 2>/dev/null; then
        log_warn "Removing MD RAID signatures from /dev/$disk"
        mdadm --zero-superblock "/dev/$disk" 2>/dev/null || true
        for md in /dev/md[0-9]*; do
            if [[ -b "$md" ]]; then
                mdadm --stop "$md" 2>/dev/null || true
            fi
        done
    fi
}

# Remove Ceph signatures
remove_ceph() {
    local disk=$1
    if command -v ceph-volume >/dev/null; then
        if ceph-volume lvm list "/dev/$disk" 2>/dev/null | grep -q "osd"; then
            log_warn "Removing Ceph signatures from /dev/$disk"
            ceph-volume lvm zap --destroy "/dev/$disk" 2>/dev/null || true
        fi
    fi
}

# Remove ZFS signatures
remove_zfs() {
    local disk=$1
    if command -v zpool >/dev/null; then
        if zdb -l "/dev/$disk" 2>/dev/null; then
            log_warn "Removing ZFS signatures from /dev/$disk"
            zpool labelclear -f "/dev/$disk" 2>/dev/null || true
        fi
    fi
}

# Wipe partition tables and signatures
wipe_signatures() {
    local disk=$1
    log_info "Wiping all signatures from /dev/$disk"
    
    # Multiple passes to ensure complete wipe
    
    # Pass 1: wipefs for all signatures
    wipefs -a "/dev/$disk" 2>/dev/null || true
    sleep 1
    
    # Pass 2: sgdisk for GPT
    sgdisk --zap-all "/dev/$disk" 2>/dev/null || true
    sleep 1
    
    # Pass 3: dd first 1MB (covers MBR and GPT header)
    dd if=/dev/zero of="/dev/$disk" bs=1M count=1 status=none 2>/dev/null || true
    sleep 1
    
    # Pass 4: dd last 1MB (covers GPT backup)
    local size=$(blockdev --getsize64 "/dev/$disk" 2>/dev/null || echo 0)
    if [[ $size -gt 2097152 ]]; then
        local seek_position=$(( (size - 1048576) / 1048576 ))
        dd if=/dev/zero of="/dev/$disk" bs=1M seek=$seek_position status=none 2>/dev/null || true
    fi
    sleep 1
    
    # Pass 5: Additional wipe for stubborn signatures
    dd if=/dev/zero of="/dev/$disk" bs=512 count=1000 status=none 2>/dev/null || true
}

# Remove partition mappings from kernel (without removing disk itself)
remove_partition_mappings() {
    local disk=$1
    log_info "Removing partition mappings for /dev/$disk"
    
    # Only remove device mapper entries that are actually partitions of this disk
    for dm in $(dmsetup ls | grep -E "${disk}(p)?[0-9]+" | cut -f1); do
        log_warn "Removing device mapper: $dm"
        dmsetup remove "$dm" 2>/dev/null || true
    done
    
    sleep 2
}

# Rescan SCSI bus to rediscover disk
rescan_scsi_bus() {
    local disk=$1
    log_info "Attempting to rescan SCSI bus for /dev/$disk"
    
    # Find the host number for this disk
    local host_path=$(readlink -f "/sys/block/$disk/device" 2>/dev/null | grep -o 'host[0-9]\+' | head -1)
    
    if [[ -n "$host_path" ]]; then
        local host_num=${host_path#host}
        local scan_path="/sys/class/scsi_host/host${host_num}/scan"
        
        if [[ -f "$scan_path" ]]; then
            log_warn "Rescanning SCSI host $host_num"
            echo "- - -" > "$scan_path" 2>/dev/null || true
            sleep 3
        fi
    fi
    
    # Also try generic rescan
    if [[ -d "/sys/block/$disk/device" ]]; then
        echo 1 > "/sys/block/$disk/device/rescan" 2>/dev/null || true
    fi
}

# Reload disk information
reload_disk() {
    local disk=$1
    log_info "Reloading disk information for /dev/$disk"
    
    # First, check if disk still exists
    if [[ ! -b "/dev/$disk" ]]; then
        log_warn "Disk /dev/$disk not found, attempting to rescan"
        rescan_scsi_bus "$disk"
        sleep 2
    fi
    
    # If disk still doesn't exist after rescan, try to rediscover
    if [[ ! -b "/dev/$disk" ]]; then
        log_warn "Disk /dev/$disk still not found, trying device rediscovery"
        udevadm trigger --name-match="/dev/$disk" 2>/dev/null || true
        udevadm settle --timeout=10 2>/dev/null || true
        sleep 3
    fi
    
    # Now try to reload partition table if disk exists
    if [[ -b "/dev/$disk" ]]; then
        # Multiple methods to ensure disk is reloaded
        partprobe "/dev/$disk" 2>/dev/null || true
        blockdev --rereadpt "/dev/$disk" 2>/dev/null || true
        
        # Only attempt rescan if the path exists
        if [[ -d "/sys/block/$disk/device" ]]; then
            echo 1 > "/sys/block/$disk/device/rescan" 2>/dev/null || true
        fi
        
        udevadm settle --timeout=30 2>/dev/null || true
        udevadm trigger --name-match="/dev/$disk" 2>/dev/null || true
        
        sleep 3
        
        log_ok "Disk /dev/$disk successfully reloaded"
    else
        log_error "Disk /dev/$disk could not be rediscovered - may need manual intervention or reboot"
        return 1
    fi
}

# Wipe a single disk
wipe_single_disk() {
    local disk=$1
    
    # Final safety check (should have been handled in expand_disk_patterns, but double-check)
    if is_disk_excluded "$disk"; then
        log_warn "Skipping excluded disk: /dev/$disk"
        return 0
    fi
    
    # Ask for confirmation in manual mode
    if [[ "$AUTO_MODE" == "false" ]]; then
        read -p "Wipe /dev/$disk? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_warn "Skipping /dev/$disk"
            return 0
        fi
    fi
    
    log_info "Starting COMPLETE wipe process for /dev/$disk"
    
    # Step 0: Stop processes using the disk
    stop_disk_processes "$disk"
    
    # Step 1: Unmount any filesystems
    unmount_disk "$disk"
    
    # Step 2: Remove partition mappings (but not the disk itself)
    remove_partition_mappings "$disk"
    
    # Step 3: Remove various signatures (LVM first as it's often the issue)
    remove_lvm "$disk"
    remove_mdraid "$disk"
    remove_ceph "$disk"
    remove_zfs "$disk"
    
    # Step 4: Wipe all signatures and data (multiple passes)
    wipe_signatures "$disk"
    
    # Step 5: Final LVM cleanup (in case anything was missed)
    remove_lvm "$disk"
    
    # Step 6: Reload disk information
    if ! reload_disk "$disk"; then
        log_error "Failed to reload /dev/$disk - disk may need manual recovery"
        return 1
    fi
    
    # Step 7: Final verification
    local remaining_partitions=$(lsblk -nlo NAME "/dev/$disk" 2>/dev/null | grep -v "^${disk}$" | wc -l)
    if [[ $remaining_partitions -gt 0 ]]; then
        log_warn "Partitions still detected on /dev/$disk - performing final cleanup"
        wipe_signatures "$disk"
        reload_disk "$disk"
    fi
    
    # Final check that disk is clean
    if lsblk -nlo NAME "/dev/$disk" 2>/dev/null | grep -q "^${disk}$"; then
        if [[ $(lsblk -nlo NAME "/dev/$disk" 2>/dev/null | grep -v "^${disk}$" | wc -l) -eq 0 ]]; then
            log_ok "Successfully COMPLETELY wiped /dev/$disk - disk is now clean"
        else
            log_warn "Disk /dev/$disk wiped but still shows partitions - may need additional cleanup"
        fi
    else
        log_error "Disk /dev/$disk not found after wipe procedure"
        return 1
    fi
}

# Display usage information
show_help() {
    cat << EOF
Usage: $0 [OPTIONS] [DISK_PATTERNS...]

COMPLETELY wipe disk signatures and data using multiple aggressive methods.

DISK_PATTERNS:
  all                    Wipe all disks (excluding sda by default)
  sd*                    Wipe all SCSI disks matching pattern
  nvme*                  Wipe all NVMe disks matching pattern
  vd*                    Wipe all VirtIO disks matching pattern
  mmcblk*                Wipe all MMC disks matching pattern
  sdb sdc nvme0n1        Specific disk names

OPTIONS:
  --auto                 Run automatically without confirmation
  --manual               Ask for confirmation for each disk (default)
  --force                Allow wiping /dev/sda (DANGEROUS)
  --exclude sda,nvme0n1  Exclude specific disks from wiping
  --help                 Show this help message

DEFAULT EXCLUSIONS (always excluded):
  sr*    (CD/DVD drives)
  dm*    (device mapper devices)
  loop*  (loop devices)
  mapper* (LVM mappings)

Examples:
  # Wipe specific disks
  $0 sdb nvme0n1

  # Wipe all disks automatically (excluding sda and special devices)
  $0 all --auto

  # Wipe all sd* disks with force (including sda)
  $0 sd* --auto --force

  # Wipe all disks except sda and nvme0n1
  $0 all --auto --exclude sda,nvme0n1

WARNING: This will DESTROY ALL DATA on the specified disks!
EOF
}

# Parse command line arguments
parse_arguments() {
    local patterns=()
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --auto)
                AUTO_MODE=true
                MANUAL_MODE=false
                shift
                ;;
            --manual)
                MANUAL_MODE=true
                AUTO_MODE=false
                shift
                ;;
            --force)
                FORCE_MODE=true
                log_warn "FORCE mode enabled - /dev/sda may be wiped!"
                shift
                ;;
            --exclude)
                if [[ -n "${2:-}" ]]; then
                    IFS=',' read -ra USER_EXCLUDED <<< "$2"
                    log_info "User excluded disks: ${USER_EXCLUDED[*]}"
                    shift 2
                else
                    log_error "--exclude requires a comma-separated list"
                    exit 1
                fi
                ;;
            --help)
                show_help
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                patterns+=("$1")
                shift
                ;;
        esac
    done
    
    # If no patterns specified, show help
    if [[ ${#patterns[@]} -eq 0 ]]; then
        log_error "No disk patterns specified"
        show_help
        exit 1
    fi
    
    # Expand disk patterns with exclusion checking
    mapfile -t TARGET_DISKS < <(expand_disk_patterns "${patterns[@]}")
    
    if [[ ${#TARGET_DISKS[@]} -eq 0 ]]; then
        log_error "No valid disks found matching the patterns (after exclusions)"
        exit 1
    fi
}

# Main function
main() {
    log_info "Starting COMPLETE disk wipe procedure"
    
    # Check root privileges
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Detect OS and install dependencies
    detect_os
    install_dependencies
    
    # Parse command line arguments
    parse_arguments "$@"
    
    log_info "Target disks: ${TARGET_DISKS[*]}"
    log_info "Default exclusions: ${DEFAULT_EXCLUDED[*]}"
    if [[ ${#USER_EXCLUDED[@]} -gt 0 ]]; then
        log_info "User exclusions: ${USER_EXCLUDED[*]}"
    fi
    
    if [[ "$AUTO_MODE" == "true" ]]; then
        log_warn "AUTO mode enabled - no confirmation will be asked!"
    else
        log_info "MANUAL mode - confirmation will be asked for each disk"
    fi
    
    # Final warning before proceeding
    echo
    log_warn "WARNING: This operation will DESTROY ALL DATA on the specified disks!"
    log_warn "There is NO UNDO for this operation!"
    log_warn "This is an AGGRESSIVE wipe that will remove LVM, partitions, and all signatures!"
    echo
    
    if [[ "$AUTO_MODE" == "false" ]]; then
        read -p "Are you sure you want to continue? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Operation cancelled by user"
            exit 0
        fi
    fi
    
    # Wipe each disk
    for disk in "${TARGET_DISKS[@]}"; do
        wipe_single_disk "$disk"
        echo
    done
    
    log_ok "COMPLETE disk wipe procedure finished"
    log_info "Use 'lsblk' to verify the results"
    echo
    log_info "Current disk status:"
    lsblk
}

# Run main function with all arguments
main "$@"
