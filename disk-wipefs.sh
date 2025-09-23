#!/usr/bin/env bash
#
# disk-wipefs.sh - Safe disk wiping script using wipefs
#
# Author: ChatGPT & TrungLun0112
# Repo:   https://github.com/TrungLun0112
#
# This script safely wipes partition/signature info from disks.
# It auto-installs required dependencies to ensure smooth execution
# across most Linux distributions.
#

set -euo pipefail

# ========== CONFIG ==========
REQUIRED_PKGS=(gdisk mdadm lvm2 kpartx)
SKIP_DEFAULT="/dev/sda"

# ========== FUNCTIONS ==========

log() { echo -e "[INFO] $*"; }
err() { echo -e "[ERROR] $*" >&2; }

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO=$ID
    else
        DISTRO="unknown"
    fi
    echo "$DISTRO"
}

install_packages() {
    local distro pkgmgr

    distro=$(detect_distro)
    log "Detected distro: $distro"

    case "$distro" in
        ubuntu|debian)
            pkgmgr="apt"
            sudo apt update -y
            for p in "${REQUIRED_PKGS[@]}"; do
                log "Installing $p..."
                sudo apt install -y "$p" || true
            done
            ;;
        centos|rhel|rocky|almalinux)
            pkgmgr="yum"
            for p in "${REQUIRED_PKGS[@]}"; do
                log "Installing $p..."
                sudo yum install -y "$p" || true
            done
            ;;
        fedora)
            pkgmgr="dnf"
            for p in "${REQUIRED_PKGS[@]}"; do
                log "Installing $p..."
                sudo dnf install -y "$p" || true
            done
            ;;
        opensuse*|sles)
            pkgmgr="zypper"
            log "Refreshing repo..."
            sudo zypper refresh
            log "Installing required packages..."
            sudo zypper install -y gptfdisk mdadm lvm2 multipath-tools || true
            ;;
        arch)
            pkgmgr="pacman"
            sudo pacman -Sy --noconfirm gptfdisk mdadm lvm2 multipath-tools || true
            ;;
        alpine)
            pkgmgr="apk"
            for p in gptfdisk mdadm lvm2 multipath-tools; do
                log "Installing $p..."
                sudo apk add "$p" || true
            done
            ;;
        *)
            err "Unsupported distro: $distro"
            err "Please manually install: ${REQUIRED_PKGS[*]}"
            ;;
    esac
}

list_disks() {
    lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}'
}

wipe_disk() {
    local disk="$1"

    if [[ "$disk" == "$SKIP_DEFAULT" && "${FORCE:-0}" -ne 1 ]]; then
        log "Skipping $disk (default protection). Use --force to override."
        return
    fi

    log "Wiping signatures on $disk..."
    sudo wipefs -a -f "$disk"

    log "Reloading partition table for $disk..."
    sudo partprobe "$disk" || sudo udevadm trigger --subsystem-match=block
}

# ========== MAIN ==========

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE=1
fi

log "Checking and installing required packages..."
install_packages

log "Listing available disks..."
DISKS=$(list_disks)
echo "$DISKS"

for d in $DISKS; do
    wipe_disk "$d"
done

log "Done. All eligible disks have been wiped."
