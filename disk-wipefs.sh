#!/bin/bash
#
# disk-wipefs.sh - Advanced Disk Wiping Script
# Purpose: Completely wipe disk metadata, partition tables, RAID, LVM, Ceph, ZFS and residual data
# Author: System Administrator
# Version: 1.0
#
# Usage:
#   ./disk-wipefs.sh [options] [disk1] [disk2] ...
#   ./disk-wipefs.sh all [--auto] [--force] [--exclude list]
#   ./disk-wipefs.sh sd* [--auto]
#
# Options:
#   --auto         : Automatic mode, no confirmation prompts
#   --manual       : Manual mode, ask Y/N for each disk (default)
#   --all          : Target all available disks (excludes sda by default)
#   --force        : Allow wiping sda (DANGEROUS!)
#   --exclude list : Comma-separated list of disks to exclude (e.g. sda,nvme0n1)
#   --help         : Show this help message
#
# Examples:
#   sudo ./disk-wipefs.sh sdb nvme0n1        # Wipe specific disks
#   sudo ./disk-wipefs.sh all --auto         # Auto wipe all disks except sda
#   sudo ./disk-wipefs.sh sd* --auto         # Auto wipe all sd* disks
#   sudo ./disk-wipefs.sh all --force --auto # Wipe ALL disks including sda
#

# Color codes for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
SCRIPT_NAME=$(basename "$0")
LOG_PREFIX="[$(date +'%Y-%m-%d %H:%M:%S')]"
AUTO_MODE=false
MANUAL_MODE=true
FORCE_SDA=false
ALL_DISKS=false
EXCLUDE_LIST=""
TARGET_DISKS=()
REQUIRED_TOOLS=("wipefs" "sgdisk" "blockdev" "partprobe" "udevadm" "lsblk" "dd")
OPTIONAL_TOOLS=("mdadm" "pvremove" "vgremove" "lvremove" "ceph-volume" "zpool")

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} ${LOG_PREFIX} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} ${LOG_PREFIX} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} ${LOG_PREFIX} $1" >&2
}

log_ok() {
    echo -e "${GREEN}[OK]${NC} ${LOG_PREFIX} $1"
}

log_step() {
    echo -e "${PURPLE}[STEP]${NC} ${LOG_PREFIX} $1"
}

# Help function
show_help() {
    cat << EOF
$(basename "$0") - Advanced Disk Wiping Script

PURPOSE:
    Completely wipe disk metadata, partition tables, RAID, LVM, Ceph, ZFS and residual data

USAGE:
    $SCRIPT_NAME [options] [disk1] [disk2] ...
    $SCRIPT_NAME all [options]
    $SCRIPT_NAME pattern [options]

OPTIONS:
    --auto         Automatic mode, no confirmation prompts
    --manual       Manual mode, ask Y/N for each disk (default)
    --all          Target all available disks (excludes sda by default)
    --force        Allow wiping sda (DANGEROUS!)
    --exclude list Comma-separated list of disks to exclude (e.g. sda,nvme0n1)
    --help         Show this help message

EXAMPLES:
    sudo $SCRIPT_NAME sdb nvme0n1                    # Wipe specific disks
    sudo $SCRIPT_NAME all --auto                     # Auto wipe all disks except sda
    sudo $SCRIPT_NAME sd* --auto                     # Auto wipe all sd* disks
    sudo $SCRIPT_NAME all --force --auto             # Wipe ALL disks including sda
    sudo $SCRIPT_NAME all --exclude sda,nvme0n1      # Wipe all except specified disks

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

EOF
}

# Detect OS distribution
detect_os() {
    log_step "Detecting operating system..."
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_LIKE="$ID_LIKE"
    elif [ -f /etc/redhat-release ]; then
        OS_ID="rhel"
        OS_VERSION=$(grep -o '[0-9]\+' /etc/redhat-release | head -1)
    elif [ -f /etc/debian_version ]; then
        OS_ID="debian"
        OS_VERSION=$(cat /etc/debian_version)
    else
        log_error "Cannot detect operating system"
        return 1
    fi
    
    log_info "Detected OS: $OS_ID $OS_VERSION"
    
    # Set package manager based on OS
    case "$OS_ID" in
        ubuntu|debian)
            PKG_MGR="apt-get"
            PKG_UPDATE="apt-get update"
            PKG_INSTALL="apt-get install -y"
            ;;
        centos|rhel|rocky|almalinux)
            PKG_MGR="yum"
            PKG_UPDATE="yum makecache"
            PKG_INSTALL="yum install -y"
            ;;
        fedora)
            PKG_MGR="dnf"
            PKG_UPDATE="dnf makecache"
            PKG_INSTALL="dnf install -y"
            ;;
        opensuse*|sles)
            PKG_MGR="zypper"
            PKG_UPDATE="zypper refresh"
            PKG_INSTALL="zypper install -y"
            ;;
        arch|manjaro)
            PKG_MGR="pacman"
            PKG_UPDATE="pacman -Sy"
            PKG_INSTALL="pacman -S --noconfirm"
            ;;
        *)
            log_warn "Unknown OS: $OS_ID, will attempt generic package installation"
            PKG_MGR="unknown"
            ;;
    esac
    
    return 0
}

# Fix CD-ROM sources for Ubuntu/Debian
fix_cdrom_sources() {
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        if [ -f /etc/apt/sources.list ]; then
            if grep -q "^deb cdrom:" /etc/apt/sources.list; then
                log_step "Fixing CD-ROM entries in /etc/apt/sources.list..."
                sed -i 's/^deb cdrom:/#deb cdrom:/' /etc/apt/sources.list
                log_ok "CD-ROM entries commented out"
            fi
        fi
    fi
}

# Check if tool is installed
is_tool_installed() {
    command -v "$1" >/dev/null 2>&1
}

# Install missing tools
install_missing_tools() {
    log_step "Checking required tools..."
    
    local missing_tools=()
    local missing_packages=()
    
    # Check required tools
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! is_tool_installed "$tool"; then
            missing_tools+=("$tool")
        fi
    done
    
    # Check optional tools and add to missing if not found
    for tool in "${OPTIONAL_TOOLS[@]}"; do
        if ! is_tool_installed "$tool"; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -eq 0 ]; then
        log_ok "All required tools are available"
        return 0
    fi
    
    log_warn "Missing tools: ${missing_tools[*]}"
    log_step "Installing missing packages..."
    
    # Fix CD-ROM sources before package installation
    fix_cdrom_sources
    
    # Map tools to packages based on OS
    case "$OS_ID" in
        ubuntu|debian)
            for tool in "${missing_tools[@]}"; do
                case "$tool" in
                    wipefs|blockdev|partprobe|udevadm|lsblk) missing_packages+=("util-linux") ;;
                    sgdisk) missing_packages+=("gdisk") ;;
                    mdadm) missing_packages+=("mdadm") ;;
                    pvremove|vgremove|lvremove) missing_packages+=("lvm2") ;;
                    ceph-volume) missing_packages+=("ceph-common") ;;
                    zpool) missing_packages+=("zfsutils-linux") ;;
                    dd) missing_packages+=("coreutils") ;;
                esac
            done
            ;;
        centos|rhel|rocky|almalinux|fedora)
            for tool in "${missing_tools[@]}"; do
                case "$tool" in
                    wipefs|blockdev|partprobe|udevadm|lsblk) missing_packages+=("util-linux") ;;
                    sgdisk) missing_packages+=("gdisk") ;;
                    mdadm) missing_packages+=("mdadm") ;;
                    pvremove|vgremove|lvremove) missing_packages+=("lvm2") ;;
                    ceph-volume) missing_packages+=("ceph-common") ;;
                    zpool) missing_packages+=("zfs") ;;
                    dd) missing_packages+=("coreutils") ;;
                esac
            done
            ;;
        opensuse*|sles)
            for tool in "${missing_tools[@]}"; do
                case "$tool" in
                    wipefs|blockdev|partprobe|udevadm|lsblk) missing_packages+=("util-linux") ;;
                    sgdisk) missing_packages+=("gptfdisk") ;;
                    mdadm) missing_packages+=("mdadm") ;;
                    pvremove|vgremove|lvremove) missing_packages+=("lvm2") ;;
                    ceph-volume) missing_packages+=("ceph-common") ;;
                    zpool) missing_packages+=("zfs") ;;
                    dd) missing_packages+=("coreutils") ;;
                esac
            done
            ;;
        arch|manjaro)
            for tool in "${missing_tools[@]}"; do
                case "$tool" in
                    wipefs|blockdev|partprobe|udevadm|lsblk) missing_packages+=("util-linux") ;;
                    sgdisk) missing_packages+=("gptfdisk") ;;
                    mdadm) missing_packages+=("mdadm") ;;
                    pvremove|vgremove|lvremove) missing_packages+=("lvm2") ;;
                    ceph-volume) missing_packages+=("ceph") ;;
                    zpool) missing_packages+=("zfs-utils") ;;
                    dd) missing_packages+=("coreutils") ;;
                esac
            done
            ;;
    esac
    
    # Remove duplicates
    missing_packages=($(printf "%s\n" "${missing_packages[@]}" | sort -u))
    
    if [ ${#missing_packages[@]} -gt 0 ]; then
        log_info "Updating package cache..."
        $PKG_UPDATE 2>/dev/null || log_warn "Package cache update failed"
        
        log_info "Installing packages: ${missing_packages[*]}"
        if $PKG_INSTALL "${missing_packages[@]}" 2>/dev/null; then
            log_ok "Packages installed successfully"
        else
            log_warn "Some packages may not be available in repositories"
        fi
    fi
    
    return 0
}

# Get list of available disks
get_available_disks() {
    local disks=()
    
    # Find disks matching supported patterns: sd*, nvme*, vd*, mmcblk*
    for disk in /dev/sd* /dev/nvme*n* /dev/vd* /dev/mmcblk*; do
        if [ -b "$disk" ]; then
            disk_name=$(basename "$disk")
            # Skip excluded patterns by default
            if [[ "$disk_name" =~ ^sr[0-9]*$ ]] || \
               [[ "$disk_name" =~ ^dm-[0-9]*$ ]] || \
               [[ "$disk_name" =~ ^loop[0-9]*$ ]] || \
               [[ "$disk_name" =~ mapper ]]; then
                continue
            fi
            
            # Skip sda unless --force is used
            if [[ "$disk_name" == "sda" ]] && [[ "$FORCE_SDA" != true ]]; then
                continue
            fi
            
            disks+=("$disk_name")
        fi
    done 2>/dev/null
    
    printf "%s\n" "${disks[@]}" | sort
}

# Check if disk is in exclude list
is_excluded() {
    local disk="$1"
    if [ -z "$EXCLUDE_LIST" ]; then
        return 1
    fi
    
    IFS=',' read -ra EXCLUDED_DISKS <<< "$EXCLUDE_LIST"
    for excluded in "${EXCLUDED_DISKS[@]}"; do
        if [[ "$disk" == "$excluded" ]]; then
            return 0
        fi
    done
    return 1
}

# Expand wildcard patterns
expand_pattern() {
    local pattern="$1"
    local expanded=()
    
    case "$pattern" in
        sd*)
            for disk in /dev/sd*; do
                if [ -b "$disk" ]; then
                    disk_name=$(basename "$disk")
                    if [[ ! "$disk_name" =~ ^sr[0-9]*$ ]]; then
                        expanded+=("$disk_name")
                    fi
                fi
            done
            ;;
        nvme*)
            for disk in /dev/nvme*n*; do
                if [ -b "$disk" ]; then
                    expanded+=($(basename "$disk"))
                fi
            done
            ;;
        vd*)
            for disk in /dev/vd*; do
                if [ -b "$disk" ]; then
                    expanded+=($(basename "$disk"))
                fi
            done
            ;;
        mmcblk*)
            for disk in /dev/mmcblk*; do
                if [ -b "$disk" ]; then
                    disk_name=$(basename "$disk")
                    if [[ ! "$disk_name" =~ p[0-9]*$ ]]; then  # Exclude partitions
                        expanded+=("$disk_name")
                    fi
                fi
            done
            ;;
        *)
            if [ -b "/dev/$pattern" ]; then
                expanded+=("$pattern")
            fi
            ;;
    esac
    
    printf "%s\n" "${expanded[@]}" | sort -u
}

# Unmount all partitions on a disk
unmount_disk_partitions() {
    local disk="/dev/$1"
    log_step "Unmounting all partitions on $disk..."
    
    # Get all mounted partitions for this disk
    local partitions=$(lsblk -rno NAME,MOUNTPOINT "$disk" 2>/dev/null | awk '$2 != "" && $2 != "/" {print "/dev/"$1}')
    
    if [ -n "$partitions" ]; then
        while IFS= read -r partition; do
            log_info "Unmounting $partition..."
            umount "$partition" 2>/dev/null || umount -l "$partition" 2>/dev/null
        done <<< "$partitions"
    fi
    
    # Additional force unmount attempts
    swapoff "${disk}"* 2>/dev/null || true
}

# Remove LVM structures
remove_lvm() {
    local disk="/dev/$1"
    log_step "Checking and removing LVM structures on $disk..."
    
    if ! is_tool_installed "pvremove"; then
        log_warn "LVM tools not available, skipping LVM cleanup"
        return 0
    fi
    
    # Check if disk has LVM physical volumes
    local pvs=$(pvs --noheadings -o pv_name 2>/dev/null | grep -E "${disk}[0-9]*" || true)
    
    if [ -n "$pvs" ]; then
        while IFS= read -r pv; do
            pv=$(echo "$pv" | xargs)  # Trim whitespace
            log_info "Found LVM PV: $pv"
            
            # Get VG name for this PV
            local vg=$(pvs --noheadings -o vg_name "$pv" 2>/dev/null | xargs)
            
            if [ -n "$vg" ] && [ "$vg" != "" ]; then
                # Remove all LVs in the VG
                log_info "Removing logical volumes in VG: $vg"
                lvremove -f "$vg" 2>/dev/null || true
                
                # Remove VG
                log_info "Removing volume group: $vg"
                vgremove -f "$vg" 2>/dev/null || true
            fi
            
            # Remove PV
            log_info "Removing physical volume: $pv"
            pvremove -f "$pv" 2>/dev/null || true
            
        done <<< "$pvs"
        
        log_ok "LVM cleanup completed"
    fi
}

# Remove RAID superblocks
remove_raid() {
    local disk="/dev/$1"
    log_step "Checking and removing RAID superblocks on $disk..."
    
    if ! is_tool_installed "mdadm"; then
        log_warn "mdadm not available, skipping RAID cleanup"
        return 0
    fi
    
    # Zero RAID superblocks on disk and all its partitions
    mdadm --zero-superblock "${disk}" 2>/dev/null || true
    mdadm --zero-superblock "${disk}"* 2>/dev/null || true
    
    log_ok "RAID superblock cleanup completed"
}

# Remove Ceph OSD
remove_ceph() {
    local disk="/dev/$1"
    log_step "Checking and removing Ceph OSD structures on $disk..."
    
    if ! is_tool_installed "ceph-volume"; then
        log_warn "ceph-volume not available, skipping Ceph cleanup"
        return 0
    fi
    
    # Try to zap Ceph OSD
    ceph-volume lvm zap --destroy "${disk}" 2>/dev/null || true
    
    log_ok "Ceph cleanup completed"
}

# Remove ZFS labels
remove_zfs() {
    local disk="/dev/$1"
    log_step "Checking and removing ZFS labels on $disk..."
    
    if ! is_tool_installed "zpool"; then
        log_warn "ZFS tools not available, skipping ZFS cleanup"
        return 0
    fi
    
    # Try to clear ZFS labels
    zpool labelclear -f "${disk}" 2>/dev/null || true
    
    # Also try partitions
    for part in "${disk}"*; do
        if [ -b "$part" ]; then
            zpool labelclear -f "$part" 2>/dev/null || true
        fi
    done 2>/dev/null || true
    
    log_ok "ZFS cleanup completed"
}

# Wipe partition tables and metadata
wipe_partition_tables() {
    local disk="/dev/$1"
    log_step "Wiping partition tables and metadata on $disk..."
    
    # Use wipefs to clear filesystem signatures
    if is_tool_installed "wipefs"; then
        log_info "Clearing filesystem signatures..."
        wipefs -a "$disk" 2>/dev/null || true
        wipefs -a "${disk}"* 2>/dev/null || true
    fi
    
    # Use sgdisk to zap GPT structures
    if is_tool_installed "sgdisk"; then
        log_info "Zapping GPT structures..."
        sgdisk --zap-all "$disk" 2>/dev/null || true
    fi
    
    log_ok "Partition table cleanup completed"
}

# Write zeros to beginning and end of disk
zero_disk_residuals() {
    local disk="/dev/$1"
    log_step "Zeroing residual data at beginning and end of $disk..."
    
    # Get disk size in bytes
    local disk_size=$(blockdev --getsize64 "$disk" 2>/dev/null)
    
    if [ -n "$disk_size" ] && [ "$disk_size" -gt 0 ]; then
        # Zero first 10MB
        log_info "Zeroing first 10MB..."
        dd if=/dev/zero of="$disk" bs=1M count=10 conv=fsync 2>/dev/null || true
        
        # Zero last 10MB
        log_info "Zeroing last 10MB..."
        local skip_blocks=$(((disk_size - 10485760) / 1048576))  # (size - 10MB) / 1MB
        dd if=/dev/zero of="$disk" bs=1M count=10 seek="$skip_blocks" conv=fsync 2>/dev/null || true
    else
        log_warn "Could not determine disk size, skipping residual data cleanup"
    fi
    
    log_ok "Residual data cleanup completed"
}

# Reload disk tables
reload_disk_tables() {
    local disk="/dev/$1"
    log_step "Reloading disk tables and triggering udev events..."
    
    # Re-read partition tables
    if is_tool_installed "blockdev"; then
        blockdev --rereadpt "$disk" 2>/dev/null || true
    fi
    
    if is_tool_installed "partprobe"; then
        partprobe "$disk" 2>/dev/null || true
    fi
    
    # Trigger udev events
    if is_tool_installed "udevadm"; then
        udevadm trigger --subsystem-match=block 2>/dev/null || true
        udevadm settle 2>/dev/null || true
    fi
    
    log_ok "Disk tables reloaded"
}

# Main disk wiping function
wipe_disk() {
    local disk="$1"
    local disk_path="/dev/$disk"
    
    if [ ! -b "$disk_path" ]; then
        log_error "Block device $disk_path does not exist"
        return 1
    fi
    
    log_info "Starting wipe process for disk: $disk"
    echo -e "${CYAN}========================================${NC}"
    
    # Step 1: Unmount partitions
    unmount_disk_partitions "$disk"
    
    # Step 2: Remove LVM structures
    remove_lvm "$disk"
    
    # Step 3: Remove RAID superblocks
    remove_raid "$disk"
    
    # Step 4: Remove Ceph OSD
    remove_ceph "$disk"
    
    # Step 5: Remove ZFS labels
    remove_zfs "$disk"
    
    # Step 6: Wipe partition tables and metadata
    wipe_partition_tables "$disk"
    
    # Step 7: Zero residual data
    zero_disk_residuals "$disk"
    
    # Step 8: Reload disk tables
    reload_disk_tables "$disk"
    
    echo -e "${CYAN}========================================${NC}"
    log_ok "Disk $disk has been successfully wiped!"
    
    return 0
}

# Confirm disk wipe
confirm_wipe() {
    local disk="$1"
    
    if [ "$AUTO_MODE" = true ]; then
        return 0
    fi
    
    echo -e "${YELLOW}WARNING: This will PERMANENTLY DESTROY all data on /dev/$disk${NC}"
    echo -e "Disk info:"
    lsblk "/dev/$disk" 2>/dev/null || echo "  Unable to show disk info"
    echo ""
    read -p "Are you sure you want to wipe /dev/$disk? (y/N): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                exit 0
                ;;
            --auto)
                AUTO_MODE=true
                MANUAL_MODE=false
                ;;
            --manual)
                AUTO_MODE=false
                MANUAL_MODE=true
                ;;
            --force)
                FORCE_SDA=true
                ;;
            --all)
                ALL_DISKS=true
                ;;
            --exclude)
                EXCLUDE_LIST="$2"
                shift
                ;;
            --*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            all)
                ALL_DISKS=true
                ;;
            *)
                # Check if it's a pattern or specific disk
                if [[ "$1" =~ \* ]]; then
                    # It's a pattern, expand it
                    while IFS= read -r disk; do
                        if [ -n "$disk" ]; then
                            TARGET_DISKS+=("$disk")
                        fi
                    done < <(expand_pattern "$1")
                else
                    # It's a specific disk
                    TARGET_DISKS+=("$1")
                fi
                ;;
        esac
        shift
    done
}

# Main function
main() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    # Parse arguments
    parse_arguments "$@"
    
    # Show help if no arguments
    if [ ${#TARGET_DISKS[@]} -eq 0 ] && [ "$ALL_DISKS" != true ]; then
        show_help
        exit 1
    fi
    
    log_info "Starting disk wipe script..."
    
    # Detect OS and install missing tools
    detect_os || exit 1
    install_missing_tools || exit 1
    
    # Determine target disks
    local final_disks=()
    
    if [ "$ALL_DISKS" = true ]; then
        log_info "Targeting all available disks..."
        while IFS= read -r disk; do
            if [ -n "$disk" ] && ! is_excluded "$disk"; then
                final_disks+=("$disk")
            fi
        done < <(get_available_disks)
    else
        # Use specified disks
        for disk in "${TARGET_DISKS[@]}"; do
            # Remove /dev/ prefix if present
            disk=$(basename "$disk")
            
            if [ -b "/dev/$disk" ]; then
                if ! is_excluded "$disk"; then
                    final_disks+=("$disk")
                else
                    log_warn "Disk $disk is in exclude list, skipping"
                fi
            else
                log_warn "Disk /dev/$disk does not exist, skipping"
            fi
        done
    fi
    
    # Check if we have disks to process
    if [ ${#final_disks[@]} -eq 0 ]; then
        log_error "No valid disks found to wipe"
        exit 1
    fi
    
    # Show summary
    echo ""
    log_info "========== WIPE SUMMARY =========="
    log_info "Mode: $([ "$AUTO_MODE" = true ] && echo "Automatic" || echo "Manual")"
    log_info "Force SDA: $([ "$FORCE_SDA" = true ] && echo "Yes" || echo "No")"
    [ -n "$EXCLUDE_LIST" ] && log_info "Excluded: $EXCLUDE_LIST"
    log_info "Target disks (${#final_disks[@]}): ${final_disks[*]}"
    echo ""
    
    if [ "$AUTO_MODE" != true ]; then
        read -p "Continue with disk wiping? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Operation cancelled by user"
            exit 0
        fi
    fi
    
    # Process each disk
    local success_count=0
    local total_count=${#final_disks[@]}
    
    for disk in "${final_disks[@]}"; do
        echo ""
        log_info "Processing disk $disk ($(($success_count + 1))/$total_count)..."
        
        if confirm_wipe "$disk"; then
            if wipe_disk "$disk"; then
                ((success_count++))
            else
                log_error "Failed to wipe disk $disk"
            fi
        else
            log_info "Skipped disk $disk"
        fi
    done
    
    echo ""
    log_info "========== FINAL SUMMARY =========="
    log_info "Successfully wiped: $success_count/$total_count disks"
    
    if [ "$success_count" -gt 0 ]; then
        echo ""
        log_info "Updated disk layout:"
        lsblk 2>/dev/null || log_warn "Could not display disk layout"
    fi
    
    log_ok "Disk wiping process completed!"
    
    return 0
}

# Run main function with all arguments
main "$@"
