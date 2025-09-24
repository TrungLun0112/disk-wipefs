#!/usr/bin/env bash
#
# disk-wipefs v2.1
# Safely wipe disk signatures and attempt robust reload of kernel view.
#
# Credits: ChatGPT & TrungLun0112
# Repo: https://github.com/TrungLun0112/disk-wipefs
#
# WARNING: destructive operations. Double-check target devices before running.
#

set -o errexit
set -o nounset
set -o pipefail

# ---------------- Colors ----------------
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
BOLD="\033[1;1m"
RESET="\033[0m"

log()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ---------------- Trap ----------------
trap 'echo -e "\n${RED}[ABORT]${RESET} Script interrupted by user."; exit 130' INT

# ---------------- Globals & defaults ----------------
OS=""
VER=""
FORCE=0
MODE="ask"          # ask/manual or auto
ZAP_CEPH=0
ZAP_ZFS=0
INCLUDE_DM=0
EXCLUDE=()         # list of explicit excludes (names without /dev/)
TARGETS=()         # user provided targets (all / patterns / names)
AUTO_INSTALL=1     # auto-install missing tools when needed

# Tools to check (only essential ones)
ESSENTIAL_TOOLS=(wipefs sgdisk partprobe blockdev)

# ---------------- Helpers ----------------

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS="${ID:-unknown}"
        VER="${VERSION_ID:-unknown}"
        log "Detected OS: ${PRETTY_NAME:-$OS $VER}"
    else
        OS="unknown"
        VER="unknown"
        warn "Unable to detect OS via /etc/os-release"
    fi
}

fix_cdrom_repo_if_needed() {
    # Only on Debian/Ubuntu family when apt complains during install
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        if grep -q "cdrom" /etc/apt/sources.list 2>/dev/null || grep -q "file:/cdrom" /etc/apt/sources.list 2>/dev/null; then
            warn "Found cdrom entries in /etc/apt/sources.list — commenting them out to allow apt operations."
            sudo sed -i 's|^deb cdrom|#deb cdrom|' /etc/apt/sources.list 2>/dev/null || true
            sudo sed -i 's|^deb \[.*\] file:/cdrom|#deb [check-date=no] file:/cdrom|' /etc/apt/sources.list 2>/dev/null || true
            ok "cdrom entries commented."
        fi
    fi
}

need_install() {
    local missing=()
    for t in "${ESSENTIAL_TOOLS[@]}"; do
        if ! command -v "$t" >/dev/null 2>&1; then
            missing+=("$t")
        fi
    done
    # Return array via global MISSING_TOOLS
    MISSING_TOOLS=("${missing[@]}")
    if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
        return 0
    else
        MISSING_TOOLS=()
        return 1
    fi
}

install_missing_tools() {
    if [ ${#MISSING_TOOLS[@]} -eq 0 ]; then
        return
    fi
    warn "Missing tools: ${MISSING_TOOLS[*]}"
    log "Attempting to install missing tools automatically..."

    # If Debian/Ubuntu family and apt needs cdrom fix, fix first
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        fix_cdrom_repo_if_needed
    fi

    case "$OS" in
        ubuntu|debian)
            sudo apt-get update -y || true
            sudo apt-get install -y gdisk parted kpartx lvm2 mdadm || true
            ;;
        centos|rhel|rocky|almalinux)
            sudo yum install -y gdisk parted kpartx lvm2 mdadm || true
            ;;
        fedora)
            sudo dnf install -y gdisk parted kpartx lvm2 mdadm || true
            ;;
        opensuse*|suse)
            sudo zypper refresh || true
            sudo zypper install -y gptfdisk parted kpartx lvm2 mdadm || true
            ;;
        arch)
            sudo pacman -Sy --noconfirm gptfdisk parted kpartx lvm2 mdadm || true
            ;;
        alpine)
            sudo apk add gptfdisk parted kpartx lvm2 mdadm || true
            ;;
        *)
            warn "Auto-install not supported for OS: $OS. Please install: ${MISSING_TOOLS[*]}"
            ;;
    esac

    # re-check
    need_install || ok "Missing tools installed (or available now)."
}

# Check device exists and is a "disk" (not a partition)
device_exists() {
    local dev="$1"     # full path /dev/...
    # accept names like "sdb" or full path "/dev/sdb"
    local name
    if [[ "$dev" =~ ^/dev/ ]]; then
        name=$(basename "$dev")
    else
        name="$dev"
        dev="/dev/$dev"
    fi

    # check sysfs
    if [[ -b "$dev" ]]; then
        # ensure it's a disk, not partition
        # lsblk TYPE column: disk/part/rom/loop
        local typ
        typ=$(lsblk -no TYPE "/dev/$name" 2>/dev/null | head -n1 || echo "")
        if [[ "$typ" == "disk" ]]; then
            return 0
        else
            return 1
        fi
    fi
    return 1
}

# Build list of candidate disks based on user input
# Accept:
#  - all
#  - explicit names: sdb nvme0n1
#  - patterns: sd* nvme*
# Apply excludes in EXCLUDE array
build_target_list() {
    local inputs=("$@")
    local result=()

    if [ ${#inputs[@]} -eq 0 ]; then
        err "No targets specified. Use 'all' or list devices/patterns."
        exit 1
    fi

    if [[ "${inputs[0]}" == "all" ]]; then
        # all disks
        mapfile -t devs < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
        result=("${devs[@]}")
    else
        # expand patterns and explicit names
        for token in "${inputs[@]}"; do
            # skip flags starting with --
            if [[ "$token" == --* ]]; then
                continue
            fi
            # token may be a pattern like sd* (shell-expansion may already expand)
            if [[ "$token" == *"*"* ]]; then
                # use lsblk to match pattern
                mapfile -t matches < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print $1}' | grep -E "^${token//\*/.*}$" || true)
                for m in "${matches[@]}"; do
                    result+=("/dev/$m")
                done
            else
                # if token looks like /dev/.. then accept, else prepend /dev/
                if [[ "$token" =~ ^/dev/ ]]; then
                    result+=("$token")
                else
                    result+=("/dev/$token")
                fi
            fi
        done
    fi

    # apply excludes
    if [ ${#EXCLUDE[@]} -gt 0 ]; then
        local filtered=()
        for d in "${result[@]}"; do
            local base=$(basename "$d")
            local skip=0
            for ex in "${EXCLUDE[@]}"; do
                if [[ "$ex" == "$base" || "$ex" == "/dev/$base" ]]; then
                    skip=1
                    break
                fi
            done
            if [ $skip -eq 0 ]; then
                filtered+=("$d")
            fi
        done
        result=("${filtered[@]}")
    fi

    # optionally filter out device-mapper unless INCLUDE_DM=1
    if [ "$INCLUDE_DM" -ne 1 ]; then
        local filtered2=()
        for d in "${result[@]}"; do
            if [[ "$(basename "$d")" =~ ^dm- ]] || [[ "$d" =~ /dev/mapper/ ]]; then
                warn "Skipping device-mapper device $d (use --include-dm to include)"
                continue
            fi
            filtered2+=("$d")
        done
        result=("${filtered2[@]}")
    fi

    # deduplicate preserving order
    local uniq=()
    declare -A seen=()
    for d in "${result[@]}"; do
        if [ -n "$d" ] && [[ -z "${seen[$d]:-}" ]]; then
            uniq+=("$d")
            seen["$d"]=1
        fi
    done

    TARGETS=("${uniq[@]}")
}

# Strong reload attempts (many methods)
reload_attempts() {
    local dev="$1"
    local base
    base=$(basename "$dev")

    log "Attempting reload: partprobe"
    sudo partprobe "$dev" 2>/dev/null || true

    log "Attempting reload: blockdev --rereadpt"
    sudo blockdev --rereadpt "$dev" 2>/dev/null || true

    # kpartx remove/add
    if command -v kpartx >/dev/null 2>&1; then
        log "Attempting kpartx -d && kpartx -a"
        sudo kpartx -d "$dev" 2>/dev/null || true
        sleep 1
        sudo kpartx -a "$dev" 2>/dev/null || true
    fi

    # udev settle
    if command -v udevadm >/dev/null 2>&1; then
        log "udevadm settle"
        sudo udevadm settle --timeout=5 2>/dev/null || true
    fi

    # per-device rescan
    if [[ -w "/sys/block/$base/device/rescan" ]]; then
        log "Triggering per-device SCSI rescan"
        echo 1 | sudo tee "/sys/block/$base/device/rescan" >/dev/null || true
        sleep 1
    fi

    # global host scan
    for host in /sys/class/scsi_host/host*; do
        if [[ -w "$host/scan" ]]; then
            log "Global SCSI host rescan on $host"
            printf " - - -\n" | sudo tee "$host/scan" >/dev/null || true
        fi
    done

    # multipath cleanup if present
    if command -v multipath >/dev/null 2>&1; then
        log "Refreshing multipath maps"
        sudo multipath -r >/dev/null 2>&1 || true
    fi

    # final udev settle
    if command -v udevadm >/dev/null 2>&1; then
        sudo udevadm settle --timeout=5 2>/dev/null || true
    fi
}

# Wipe single disk robustly
wipe_one_disk() {
    local dev="$1"
    log "Processing $dev"

    if ! device_exists "$dev"; then
        warn "$dev not found or not a disk. Skipping."
        return
    fi

    if [[ "$dev" == "/dev/sda" && "$FORCE" -ne 1 ]]; then
        warn "Skipping /dev/sda by default. Use --force to override."
        return
    fi

    # show current state
    log "Current lsblk:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$dev" || true

    # If device is mounted or busy, warn and try to unmount? we will not auto unmount
    # but we detect mountpoints in partitions
    local mounts
    mounts=$(lsblk -no MOUNTPOINT "$dev" | grep -v '^$' || true)
    if [[ -n "$mounts" ]]; then
        warn "Some partitions on $dev appear mounted. Please unmount before wiping. (${mounts})"
        # still allow proceeding if MODE=auto, but warn user strongly
        if [[ "$MODE" == "ask" ]]; then
            read -rp "Device $dev has mounted partitions. Continue wiping (dangerous)? (y/n): " yn
            [[ "$yn" != "y" ]] && { warn "Skipped $dev"; return; }
        fi
    fi

    # Confirm if manual mode
    if [[ "$MODE" == "ask" ]]; then
        read -rp "Confirm wipe of $dev (all signatures/partition table will be removed) (y/n): " conf
        [[ "$conf" != "y" ]] && { warn "Skipped $dev"; return; }
    fi

    # 1) wipefs signatures
    log "Running wipefs -a on $dev"
    sudo wipefs -a "$dev" || warn "wipefs returned non-zero for $dev"

    # 2) sgdisk zap-all to remove GPT/MBR structures
    if command -v sgdisk >/dev/null 2>&1; then
        log "Running sgdisk --zap-all $dev"
        sudo sgdisk --zap-all "$dev" >/dev/null 2>&1 || warn "sgdisk --zap-all failed or not applicable for $dev"
    fi

    # optional ceph/zfs operations (only if flags set and commands exist)
    if [[ "$ZAP_CEPH" -eq 1 ]] && command -v ceph-volume >/dev/null 2>&1; then
        log "Attempting ceph-volume lvm zap --destroy on $dev"
        sudo ceph-volume lvm zap --destroy "$dev" >/dev/null 2>&1 || warn "ceph-volume zap failed"
    fi

    if [[ "$ZAP_ZFS" -eq 1 ]] && command -v zpool >/dev/null 2>&1; then
        log "Attempting zpool labelclear -f $dev"
        sudo zpool labelclear -f "$dev" >/dev/null 2>&1 || warn "zpool labelclear failed or ZFS tools missing"
    fi

    # 3) optionally write zeros to first 10MB to remove lingering metadata (fast)
    log "Zeroing first 10MB on $dev (fast) to clear headers"
    sudo dd if=/dev/zero of="$dev" bs=1M count=10 oflag=direct,dsync status=none || warn "dd head write failed"

    # 4) attempt many reload methods
    reload_attempts "$dev"

    # 5) check result: are there still partitions?
    sleep 1
    local parts
    parts=$(lsblk -n -o NAME,TYPE "$dev" | awk '$2=="part"{print $1}' || true)
    if [[ -n "$parts" ]]; then
        warn "Device $dev still shows partitions: $parts"
        echo
        echo -e "${YELLOW}Possible reasons:${RESET}"
        echo "- Partitions are mounted or in use by processes."
        echo "- Device is part of LVM / RAID / Ceph / ZFS and needs specialized zap commands."
        echo "- Kernel hasn't fully refreshed partition table; in rare cases reboot may be required."
        echo
        echo -e "${BOLD}Suggested actions:${RESET}"
        echo "- Ensure partitions are unmounted: sudo umount /dev/xxxN"
        echo "- For LVM: sudo lvdisplay; then sudo lvremove/vgremove/pvremove as appropriate"
        echo "- For mdadm RAID: sudo mdadm --examine /dev/xxx; sudo mdadm --zero-superblock /dev/xxx"
        echo "- For Ceph OSD: sudo ceph-volume lvm zap --destroy /dev/xxx  (use --zap-ceph to have script do this)"
        echo "- For ZFS: sudo zpool labelclear -f /dev/xxx (use --zap-zfs to have script do this)"
        echo "- If multipath: sudo systemctl stop multipathd && sudo multipath -F ; consider removing maps"
        echo "- As last resort, reboot the host to flush kernel caches."
        echo
    else
        ok "Device $dev shows no partitions after reload."
    fi

    ok "Finished processing $dev"
}

# ---------------- Parse CLI ----------------
show_help() {
    cat <<EOF
disk-wipefs v2.1 - safe disk wipe helper

Usage:
  ./disk-wipefs.sh [options] target1 target2 ...
Targets:
  all                 - all detected disks (except excluded)
  sd* nvme* vda mmc*  - patterns are supported (shell-style)
  sdb nvme0n1         - explicit device names (no /dev/ prefix needed)
Options:
  --auto              - run in automatic mode (no per-disk prompts)
  --manual            - manual confirm per disk (default)
  --force             - allow wiping /dev/sda
  --exclude NAME      - exclude device NAME (e.g. sda or nvme0n1); can repeat
  --zap-ceph          - attempt ceph-volume zap --destroy on detected OSD disks
  --zap-zfs           - attempt zpool labelclear -f on detected ZFS disks
  --include-dm        - include device-mapper (/dev/dm-*) targets (dangerous)
  --no-install        - do NOT auto-install missing tools; fail if missing
  -h, --help          - show this help

Examples:
  ./disk-wipefs.sh all --exclude sda
  ./disk-wipefs.sh sd* --auto
  ./disk-wipefs.sh sdb nvme0n1 --zap-ceph
EOF
}

# parse args
ARGS=()
while (( "$#" )); do
    case "$1" in
        --auto) MODE="auto"; shift ;;
        --manual) MODE="ask"; shift ;;
        --force) FORCE=1; shift ;;
        --zap-ceph) ZAP_CEPH=1; shift ;;
        --zap-zfs) ZAP_ZFS=1; shift ;;
        --include-dm) INCLUDE_DM=1; shift ;;
        --exclude) shift; EXCLUDE+=("$1"); shift ;;
        --no-install) AUTO_INSTALL=0; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done

if [ ${#ARGS[@]} -eq 0 ]; then
    err "No target specified. Use 'all' or provide device names/patterns. See --help."
    exit 1
fi

detect_os

# check essential tools, install only if missing and AUTO_INSTALL=1
if need_install; then
    if [ "$AUTO_INSTALL" -eq 1 ]; then
        install_missing_tools
    else
        err "Missing required tools: ${MISSING_TOOLS[*]}. Rerun with --no-install disabled or install them manually."
        exit 1
    fi
else
    ok "All required tools are present. Proceeding without installs."
fi

# build target list
build_target_list "${ARGS[@]}"

if [ ${#TARGETS[@]} -eq 0 ]; then
    err "No target disks resolved after processing patterns/excludes."
    exit 1
fi

log "Final target disks:"
for d in "${TARGETS[@]}"; do
    echo "  - $d"
done

# main loop
for d in "${TARGETS[@]}"; do
    wipe_one_disk "$d"
done

ok "All done."

# End of script
