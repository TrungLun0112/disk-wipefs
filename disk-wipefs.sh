#!/bin/bash
# ============================================================
#  disk-wipefs.sh - Advanced Disk Cleaner with Verbose Logging
#  Author: ChatGPT (OpenAI) & TrungLun0112
#  Repo: https://github.com/TrungLun0112/disk-wipefs
#
#  Features:
#   - Detect and clean LVM PV, RAID, Ceph OSD signatures
#   - Wipe filesystem signatures with wipefs
#   - Reload disk partitions using multiple methods (partprobe, blockdev, kpartx, SCSI rescan)
#   - Supports manual (confirm y/n) or auto (no prompt) mode
#   - Colorful verbose logs
#   - Trap for Ctrl+C
#
#  Usage:
#    ./disk-wipefs.sh <start_letter> [end_letter] [--auto|--manual]
#    Example:
#      ./disk-wipefs.sh b d        # clean sdb to sdd, ask confirm each disk
#      ./disk-wipefs.sh f --auto   # clean sdf only, no confirm
#
# ============================================================

# ========== COLORS ==========
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
NC="\033[0m" # No Color

# ========== TRAP ==========
trap 'echo -e "\n${RED}[EXIT] Script interrupted by user (Ctrl+C).${NC}"; exit 1' INT

# ========== FUNCTIONS ==========

log_info()   { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()  { echo -e "${RED}[ERROR]${NC} $1"; }
log_success(){ echo -e "${GREEN}[OK]${NC} $1"; }

check_disk() {
    local dev=$1
    log_info "Checking disk /dev/$dev ..."
    pvs /dev/$dev &>/dev/null && log_warn "/dev/$dev is LVM PV"
    mdadm --examine /dev/$dev &>/dev/null && log_warn "/dev/$dev is part of RAID"
    ceph-volume lvm list /dev/$dev &>/dev/null && log_warn "/dev/$dev may be a Ceph OSD"
}

clean_disk() {
    local dev=$1
    log_info "Cleaning disk /dev/$dev ..."

    # Deactivate LVM if present
    pvs /dev/$dev &>/dev/null && {
        log_info "Removing LVM PV from /dev/$dev ..."
        vgchange -an >/dev/null 2>&1
        pvremove -ff -y /dev/$dev >/dev/null 2>&1
    }

    # Zero RAID superblock
    mdadm --examine /dev/$dev &>/dev/null && {
        log_info "Wiping RAID metadata from /dev/$dev ..."
        mdadm --zero-superblock /dev/$dev >/dev/null 2>&1
    }

    # Zap GPT/MBR partition table
    log_info "Zapping partition table on /dev/$dev ..."
    sgdisk --zap-all /dev/$dev >/dev/null 2>&1

    # Wipe filesystem signatures
    log_info "Wiping filesystem signatures on /dev/$dev ..."
    wipefs -a /dev/$dev >/dev/null 2>&1

    # Reload disk partitions
    reload_disk $dev

    log_success "/dev/$dev cleaned successfully."
}

reload_disk() {
    local dev=$1
    log_info "Reloading disk /dev/$dev ..."
    partprobe /dev/$dev >/dev/null 2>&1
    blockdev --rereadpt /dev/$dev >/dev/null 2>&1
    kpartx -u /dev/$dev >/dev/null 2>&1
    for host in /sys/class/scsi_host/host*; do
        echo "- - -" > $host/scan
    done
    log_success "Disk /dev/$dev reloaded."
}

# ========== MAIN SCRIPT ==========

if [[ $# -lt 1 ]]; then
    log_error "Usage: $0 <start_letter> [end_letter] [--auto|--manual]"
    exit 1
fi

start_letter=$1
end_letter=${2:-$1}   # if only 1 arg -> start=end
mode="ask"

# Check mode flag
[[ "$2" == "--auto" || "$3" == "--auto" ]] && mode="auto"
[[ "$2" == "--manual" || "$3" == "--manual" ]] && mode="ask"

# If mode not chosen, ask user
if [[ $mode == "ask" && "$2" != "--manual" && "$3" != "--manual" ]]; then
    echo -e "${YELLOW}Choose mode:${NC}"
    echo "  1) Auto (no confirm, wipe all)"
    echo "  2) Manual (confirm each disk)"
    read -p "Enter choice [1-2]: " choice
    [[ "$choice" == "1" ]] && mode="auto" || mode="ask"
fi

log_info "Running in mode: $mode"
log_info "Target disks: from s$start_letter to s$end_letter"

for dev in $(eval echo {${start_letter}..${end_letter}}); do
    if [[ $mode == "ask" ]]; then
        check_disk sd$dev
        read -p "Do you want to clean /dev/sd$dev? (y/n): " ans
        [[ $ans == "y" ]] && clean_disk sd$dev || log_warn "Skipped /dev/sd$dev"
    else
        check_disk sd$dev
        clean_disk sd$dev
    fi
done

log_success "All tasks completed."
