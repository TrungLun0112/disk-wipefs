#!/usr/bin/env bash
# ==========================================================
# disk-wipefs v7.0
# Credits: ChatGPT & TrungLun0112
# Mục tiêu: Wipe sạch sẽ disk được chỉ định, không tự động
# ==========================================================

set -euo pipefail
IFS=$'\n\t'

VERSION="v7.0"

# Màu log
C_INFO="\033[1;34m"
C_OK="\033[1;32m"
C_WARN="\033[1;33m"
C_ERR="\033[1;31m"
C_RST="\033[0m"

log()   { echo -e "$(date '+%F %T') ${C_INFO}[INFO]${C_RST} $*"; }
ok()    { echo -e "$(date '+%F %T') ${C_OK}[OK]${C_RST} $*"; }
warn()  { echo -e "$(date '+%F %T') ${C_WARN}[WARN]${C_RST} $*"; }
error() { echo -e "$(date '+%F %T') ${C_ERR}[ERR]${C_RST} $*" >&2; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Script phải chạy với quyền root"
        exit 1
    fi
}

# ==========================================================
# Detect OS
# ==========================================================
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_PRETTY=$PRETTY_NAME
        OS_ID=$ID
        log "Detected OS: $OS_PRETTY"
    else
        OS_ID="unknown"
        warn "Không xác định được OS"
    fi
}

# ==========================================================
# Check tool
# ==========================================================
check_tools() {
    local essential=(wipefs sgdisk partprobe blockdev lsblk dd)
    local missing=()
    for t in "${essential[@]}"; do
        if ! command -v "$t" >/dev/null 2>&1; then
            missing+=("$t")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Thiếu tool: ${missing[*]}"
        case "$OS_ID" in
            ubuntu|debian)
                apt-get update -y
                apt-get install -y "${missing[@]}"
                ;;
            centos|rhel|rocky|almalinux)
                yum install -y "${missing[@]}"
                ;;
            *)
                error "Không biết cách cài tool trên OS này"
                exit 1
                ;;
        esac
    else
        ok "All essential tools present"
    fi
}

# ==========================================================
# Validate input
# ==========================================================
validate_target() {
    local tgt="$1"
    if [[ ! -b /dev/$tgt ]]; then
        error "Target /dev/$tgt không tồn tại"
        exit 1
    fi
    case "$tgt" in
        sda|sr*|dm*|loop*|mapper/*)
            error "Target /dev/$tgt bị block (system/optical/virtual)"
            exit 1
            ;;
    esac
    ok "Target /dev/$tgt hợp lệ"
}

# ==========================================================
# Pre-clean: unmount, swapoff, deactivate LVM/RAID
# ==========================================================
preclean() {
    local dev="$1"
    log "Unmount partitions của $dev ..."
    umount -fl "/dev/${dev}"* 2>/dev/null || true

    log "Tắt swap liên quan $dev ..."
    swapoff "/dev/${dev}"* 2>/dev/null || true

    log "Deactivate LVM ..."
    vgchange -an 2>/dev/null || true
    lvremove -fy "/dev/${dev}"* 2>/dev/null || true
    pvremove -ff -y "/dev/${dev}"* 2>/dev/null || true

    log "Zero RAID superblock ..."
    mdadm --zero-superblock --force "/dev/$dev" 2>/dev/null || true

    log "Flush multipath ..."
    multipath -f "/dev/$dev" 2>/dev/null || true
}

# ==========================================================
# Wipe disk
# ==========================================================
wipe_disk() {
    local dev="$1"
    log "Running wipefs ..."
    wipefs -a -f "/dev/$dev" || true

    log "Zap GPT/MBR ..."
    sgdisk --zap-all "/dev/$dev" || true

    log "Zero head & tail ..."
    local size; size=$(blockdev --getsz "/dev/$dev")
    local sector; sector=$(blockdev --getss "/dev/$dev")
    dd if=/dev/zero of="/dev/$dev" bs=1M count=10 conv=fdatasync >/dev/null 2>&1 || true
    dd if=/dev/zero of="/dev/$dev" bs="$sector" seek=$((size-10240)) count=10240 conv=fdatasync >/dev/null 2>&1 || true

    log "Discard blocks (nếu hỗ trợ) ..."
    blkdiscard "/dev/$dev" 2>/dev/null || true

    log "Reload kernel view ..."
    partprobe "/dev/$dev" || true
    udevadm settle || true
    ok "Disk /dev/$dev wiped sạch sẽ"
}

# ==========================================================
# Main
# ==========================================================
require_root
log "disk-wipefs $VERSION starting"
log "Credits: ChatGPT & TrungLun0112"

detect_os
check_tools

if [[ $# -lt 1 ]]; then
    error "Usage: $0 <disk> | --all"
    exit 1
fi

if [[ "$1" == "--all" ]]; then
    for d in $(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}' | grep -v -E '^(sda|sr|dm|loop|mapper)'); do
        validate_target "$d"
        preclean "$d"
        wipe_disk "$d"
    done
else
    tgt="$1"
    validate_target "$tgt"
    preclean "$tgt"
    wipe_disk "$tgt"
fi

ok "Wipe completed. Run 'lsblk' để verify."
