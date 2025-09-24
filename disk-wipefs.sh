#!/usr/bin/env bash
#
# disk-wipefs.sh - Powerful disk wipe helper for Linux
# Credits: ChatGPT & TrungLun0112
# Repo: https://github.com/TrungLun0112/disk-wipefs
#

#######################################
# CONFIG: Colors for logs
#######################################
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

#######################################
# Trap Ctrl+C
#######################################
trap 'echo -e "${RED}[ABORT]${RESET} Script interrupted by user (Ctrl+C). Exiting..."; exit 130' INT

#######################################
# Logging functions
#######################################
log_info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*"; }
log_success() { echo -e "${GREEN}[OK]${RESET} $*"; }
log_check()   { echo -e "${YELLOW}[CHECK]${RESET} $*"; }
log_step()    { echo -e "${GREEN}[STEP]${RESET} $*"; }

#######################################
# Fix invalid cdrom repository (Ubuntu/Debian)
#######################################
fix_cdrom_repo() {
    if [ -f /etc/apt/sources.list ]; then
        if grep -q "cdrom" /etc/apt/sources.list; then
            log_warn "Found invalid 'cdrom' repository. Fixing..."
            sudo sed -i 's|^deb cdrom|#deb cdrom|' /etc/apt/sources.list
            sudo sed -i 's|^deb \[.*\] file:/cdrom|#deb [check-date=no] file:/cdrom|' /etc/apt/sources.list
            log_info "Disabled cdrom repository. Running apt update..."
            sudo apt-get update -y || true
        else
            log_info "No cdrom repo found."
        fi
    fi
}

#######################################
# Check and install missing dependencies
#######################################
install_deps() {
    log_step "Checking required tools..."
    PKGS=("util-linux" "mdadm" "lvm2" "parted" "kpartx" "scsitools" "zfsutils-linux" "ceph-volume")
    MISSING=()

    for pkg in "${PKGS[@]}"; do
        if ! command -v wipefs >/dev/null 2>&1 && [ "$pkg" = "util-linux" ]; then
            MISSING+=("util-linux")
        elif ! dpkg -s "$pkg" >/dev/null 2>&1 2>/dev/null; then
            MISSING+=("$pkg")
        fi
    done

    if [ ${#MISSING[@]} -gt 0 ]; then
        log_warn "Missing packages: ${MISSING[*]}"
        log_info "Script will auto install missing packages..."
        for pkg in "${MISSING[@]}"; do
            log_info "Installing $pkg..."
            sudo apt-get install -y "$pkg" || true
        done
    else
        log_success "All required tools already installed."
    fi
}

#######################################
# Reload disk changes
#######################################
reload_disks() {
    local disk=$1
    log_check "Reloading disk tables for $disk"
    sudo partprobe "$disk" || true
    sudo blockdev --rereadpt "$disk" || true
    sudo kpartx -u "$disk" || true
    for host in /sys/class/scsi_host/host*; do
        echo "- - -" | sudo tee "$host/scan" >/dev/null
    done
    log_success "Reload complete for $disk"
}

#######################################
# Wipe a single disk
#######################################
wipe_disk() {
    local disk=$1
    if [[ "$disk" == "/dev/sda" && "$FORCE" != "1" ]]; then
        log_warn "Skipping $disk (system disk). Use --force to override."
        return
    fi

    log_step "Wiping $disk"
    sudo wipefs -a "$disk"
    sudo sgdisk --zap-all "$disk" || true
    sudo dd if=/dev/zero of="$disk" bs=1M count=10 oflag=direct,dsync status=none || true
    reload_disks "$disk"
    log_success "Disk $disk wiped successfully."
}

#######################################
# Main
#######################################
FORCE=0
MODE="ask"
DISKS=()

# Parse args
for arg in "$@"; do
    case $arg in
        --auto) MODE="auto"; shift ;;
        --manual) MODE="ask"; shift ;;
        --force) FORCE=1; shift ;;
        all) DISKS+=("all"); shift ;;
        *) DISKS+=("$arg"); shift ;;
    esac
done

# Fix cdrom repo first
fix_cdrom_repo

# Install deps
install_deps

# Build disk list
if [[ " ${DISKS[*]} " =~ " all " ]]; then
    log_step "Detecting all available disks..."
    MAP=$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
    DISKS=($MAP)
    log_info "Disks found: ${DISKS[*]}"
fi

# Run wiping
for disk in "${DISKS[@]}"; do
    if [ "$MODE" = "ask" ]; then
        read -rp "Do you want to wipe $disk? (y/n): " yn
        case $yn in
            [Yy]*) wipe_disk "$disk" ;;
            *) log_info "Skipping $disk" ;;
        esac
    else
        wipe_disk "$disk"
    fi
done

log_success "All tasks completed."
