#!/usr/bin/env bash
#
# disk-wipefs v2.3
# Author: ChatGPT & TrungLun0112
# Repo: https://github.com/TrungLun0112/disk-wipefs
#
# WARNING: destructive tool. Double-check targets before running.
#

set -euo pipefail

# ------------ Colors / logging ------------
RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; BLUE="\033[1;34m"; RESET="\033[0m"
log_info(){ echo -e "$(date '+%F %T') ${GREEN}[INFO]${RESET} $*"; }
log_warn(){ echo -e "$(date '+%F %T') ${YELLOW}[WARN]${RESET} $*"; }
log_err(){ echo -e "$(date '+%F %T') ${RED}[ERROR]${RESET} $*" >&2; }
log_step(){ echo -e "\n${BLUE}===== $* =====${RESET}"; }

# ------------ Globals / defaults ------------
MODE="ask"            # ask/manual or auto
FORCE=0               # allow /dev/sda only if --force
NO_INSTALL=0          # if set, do not auto-install missing tools
INCL_DM=0             # include device-mapper targets
ZAP_CEPH=0
ZAP_ZFS=0
DRYRUN=0
EXCLUDE=()            # user excludes (names without /dev/)
USER_TARGETS=()       # targets from CLI (patterns/names/all)
TARGETS=()            # resolved /dev/... list
OS_ID=""              # linux distro id from /etc/os-release

# Essential tools we prefer to have
ESSENTIAL_TOOLS=(wipefs sgdisk partprobe blockdev lsblk kpartx mdadm lvm pvdisplay pvremove vgdisplay lvdisplay)

# ------------ Safety: require root ------------
if [[ $EUID -ne 0 ]]; then
  log_err "Please run as root (sudo)."
  exit 1
fi

# ------------ Helper: usage ------------
usage() {
  cat <<EOF
disk-wipefs v2.3 - safe but aggressive disk signature cleaner

Usage:
  sudo ./disk-wipefs.sh [options] <targets...>

Targets:
  all               - all detected disks (sd*, nvme*, vd*, mmcblk*)
  sdb nvme0n1       - explicit devices (you can omit /dev/)
  sd* nvme*         - shell-style patterns (script expands)
Options:
  --auto            - run without prompting each disk
  --manual          - prompt for each disk (default)
  --force           - allow wiping /dev/sda (dangerous)
  --exclude NAME    - exclude device NAME (e.g. sda or nvme0n1). Repeatable
  --include-dm      - include /dev/dm-* and /dev/mapper/* targets
  --zap-ceph        - if Ceph OSD metadata detected, run ceph-volume zap --destroy
  --zap-zfs         - if ZFS label detected, run zpool labelclear -f
  --no-install      - do NOT auto-install missing tools; fail if missing
  --dry-run         - show actions only, do not execute destructive commands
  -h, --help        - show this help

Examples:
  sudo ./disk-wipefs.sh all --exclude sda --auto
  sudo ./disk-wipefs.sh sdb nvme0n1
  sudo ./disk-wipefs.sh sd* --dry-run

EOF
  exit 1
}

# ------------ Parse args ------------
while (( "$#" )); do
  case "$1" in
    --auto) MODE="auto"; shift ;;
    --manual) MODE="ask"; shift ;;
    --force) FORCE=1; shift ;;
    --exclude) shift; EXCLUDE+=("$1"); shift ;;
    --include-dm) INCL_DM=1; shift ;;
    --zap-ceph) ZAP_CEPH=1; shift ;;
    --zap-zfs) ZAP_ZFS=1; shift ;;
    --no-install) NO_INSTALL=1; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    -h|--help) usage ;;
    *) USER_TARGETS+=("$1"); shift ;;
  esac
done

if [ ${#USER_TARGETS[@]} -eq 0 ]; then
  log_err "No targets specified."
  usage
fi

# ------------ Detect OS (reliable) ------------
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  log_info "Detected OS: ${PRETTY_NAME:-$OS_ID}"
else
  OS_ID="unknown"
  log_warn "/etc/os-release not found; OS detection limited"
fi

# ------------ Fix cdrom repo (only when we intend to install) ------------
fix_cdrom_repo_if_needed(){
  if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
    if grep -qE '(^deb .+cdrom|file:/cdrom)' /etc/apt/sources.list 2>/dev/null || grep -qE 'cdrom' /etc/apt/sources.list.d/* 2>/dev/null; then
      log_warn "Found cdrom entries in apt sources; commenting them to allow apt operations."
      sed -i.bak -E 's|(^deb .+cdrom)|#\1|' /etc/apt/sources.list 2>/dev/null || true
      sed -i.bak -E 's|(^deb .+file:/cdrom)|#\1|' /etc/apt/sources.list 2>/dev/null || true
      log_info "cdrom entries commented (backup in sources.list.bak)."
    fi
  fi
}

# ------------ Check missing tools and optionally install ------------
missing_tools=()
check_missing_tools(){
  missing_tools=()
  for t in "${ESSENTIAL_TOOLS[@]}"; do
    if ! command -v "$t" &>/dev/null; then
      missing_tools+=("$t")
    fi
  done
  if [ ${#missing_tools[@]} -gt 0 ]; then
    log_warn "Missing tools detected: ${missing_tools[*]}"
    return 0
  else
    log_info "All essential tools present."
    return 1
  fi
}

install_missing_tools(){
  if [ "$NO_INSTALL" -eq 1 ]; then
    log_err "Missing tools and auto-install disabled (--no-install). Install manually: ${missing_tools[*]}"
    exit 1
  fi

  fix_cdrom_repo_if_needed

  log_info "Attempting to install missing tools: ${missing_tools[*]}"
  case "$OS_ID" in
    ubuntu|debian)
      apt-get update -y || true
      apt-get install -y gdisk kpartx lvm2 mdadm || true
      ;;
    rhel|centos|rocky|almalinux)
      yum install -y gdisk kpartx lvm2 mdadm || true
      ;;
    fedora)
      dnf install -y gdisk kpartx lvm2 mdadm || true
      ;;
    sles|opensuse)
      zypper install -y gptfdisk kpartx lvm2 mdadm || true
      ;;
    arch)
      pacman -Sy --noconfirm gptfdisk kpartx lvm2 mdadm || true
      ;;
    alpine)
      apk add gptfdisk kpartx lvm2 mdadm || true
      ;;
    *)
      log_err "Unsupported OS for auto-install. Please install: ${missing_tools[*]}"
      exit 1
      ;;
  esac

  # re-check
  check_missing_tools || log_info "Missing tools installed or available now."
}

# ------------ Build target list (expand patterns, handle 'all') ------------
resolve_targets(){
  local inputs=("$@")
  local result=()
  if [[ "${inputs[0]}" == "all" ]]; then
    mapfile -t devs < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
    result=("${devs[@]}")
  else
    for tok in "${inputs[@]}"; do
      # skip flags if any slipped
      if [[ "$tok" == --* ]]; then continue; fi
      # if contains wildcard *
      if [[ "$tok" == *"*"* ]]; then
        # convert shell glob to regex: sd* -> ^sd.*$
        local re="^${tok//\*/.*}$"
        mapfile -t matches < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print $1}' | grep -E "$re" || true)
        for m in "${matches[@]}"; do
          result+=("/dev/$m")
        done
      else
        # accept /dev/ or name
        if [[ "$tok" =~ ^/dev/ ]]; then
          result+=("$tok")
        else
          result+=("/dev/$tok")
        fi
      fi
    done
  fi

  # apply default excludes (sda, sr*, loop*, dm-*, mapper/*) unless include-dm
  local filtered=()
  for d in "${result[@]}"; do
    base=$(basename "$d")
    # user excludes
    skip=0
    for ex in "${EXCLUDE[@]}"; do
      if [[ "$ex" == "$base" || "$ex" == "$d" ]]; then skip=1; break; fi
    done
    if [ $skip -eq 1 ]; then
      log_info "User exclude: skipping $d"
      continue
    fi
    # default excludes
    if [[ "$base" == "sda" && "$FORCE" -eq 0 ]]; then
      log_info "Default skip: $d (system disk). Use --force to override."
      continue
    fi
    if [[ "$base" =~ ^sr ]] || [[ "$base" =~ ^loop ]] || [[ "$base" =~ ^ram ]]; then
      log_info "Skipping special device $d"
      continue
    fi
    if [[ "$base" =~ ^dm- || "$d" =~ /dev/mapper/ ]] && [[ "$INCL_DM" -eq 0 ]]; then
      log_info "Skipping device-mapper $d (use --include-dm to include)"
      continue
    fi
    # accept nvme (it has p1 partitions - but we pass whole nvme0n1)
    result_dev="$d"
    # ensure device exists and is disk
    if ! lsblk -ndo TYPE "$result_dev" 2>/dev/null | grep -q "^disk$"; then
      log_warn "Resolved target $d is not present or not a disk; skipping"
      continue
    fi
    filtered+=("$result_dev")
  done

  # dedupe preserving order
  declare -A seen
  TARGETS=()
  for x in "${filtered[@]}"; do
    if [[ -z "${seen[$x]:-}" ]]; then
      TARGETS+=("$x")
      seen[$x]=1
    fi
  done

  if [ ${#TARGETS[@]} -eq 0 ]; then
    log_err "No valid target disks after resolution. Exiting."
    exit 1
  fi
}

# ------------ Utility: remove dm devices that reference disk (best-effort) ------------
remove_dm_using_disk(){
  local diskbase="$1"   # e.g. sdb
  for dm in /sys/block/dm-*; do
    [ -e "$dm" ] || continue
    if ls "$dm/slaves" 2>/dev/null | grep -qx "$diskbase"; then
      dmname=$(cat "$dm/dm/name" 2>/dev/null || true)
      if [ -n "$dmname" ]; then
        log_info "Removing device-mapper /dev/mapper/$dmname"
        dmsetup remove -f "/dev/mapper/$dmname" 2>/dev/null || true
      fi
    fi
  done
}

# ------------ Core operations for a single disk ------------
process_disk(){
  local dev="$1"   # /dev/sdx or /dev/nvme0n1
  local base=$(basename "$dev")
  log_step "Start processing $dev"

  # exist & is disk
  if ! lsblk -ndo TYPE "$dev" 2>/dev/null | grep -q "^disk$"; then
    log_warn "$dev is not present or not a disk; skipping"
    return
  fi

  # check mounted partitions
  local mounts
  mounts=$(lsblk -nr -o NAME,MOUNTPOINT "$dev" | awk '$2!=""{print "/dev/"$1" -> "$2}' || true)
  if [[ -n "$mounts" ]]; then
    log_warn "Found mounted partitions on $dev:"
    echo "$mounts"
    if [[ "$MODE" == "ask" ]]; then
      read -rp "Auto-unmount all partitions on $dev before wiping? (y/n): " ans
      [[ "$ans" != "y" ]] && { log_warn "Skipping $dev (user chose not to unmount)"; return; }
    else
      log_info "Auto-unmounting partitions (auto mode)..."
    fi
    # unmount partitions
    for part in $(lsblk -ln -o NAME "$dev" | grep -v "^$base$"); do
      p="/dev/$part"
      if mount | grep -q "$p"; then
        if [ "$DRYRUN" -eq 1 ]; then
          log_info "[DRYRUN] Would unmount $p"
        else
          umount -l "$p" 2>/dev/null || umount -f "$p" 2>/dev/null || true
          log_info "Unmounted $p"
        fi
      fi
    done
  fi

  # swapoff partitions on this disk (if any)
  local swaps
  swaps=$(lsblk -nr -o NAME,TYPE "$dev" | awk '$2=="swap"{print "/dev/"$1}' || true)
  if [[ -n "$swaps" ]]; then
    log_info "Found swap on $dev: $swaps"
    for s in $swaps; do
      if [ "$DRYRUN" -eq 1 ]; then
        log_info "[DRYRUN] Would swapoff $s"
      else
        swapoff "$s" 2>/dev/null || true
        log_info "swapoff $s"
      fi
    done
  fi

  # LVM deep-clean: find PV lines referencing this disk (includes partitions like sdb1)
  if command -v pvs >/dev/null 2>&1; then
    mapfile -t pv_lines < <(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v b="$base" '$1 ~ b{print $0}' || true)
    if [ ${#pv_lines[@]} -gt 0 ]; then
      log_info "Detected LVM PV(s) on $dev (or its partitions). Will attempt deep LVM cleanup."
      for line in "${pv_lines[@]}"; do
        pv=$(echo "$line" | awk '{print $1}')
        vg=$(echo "$line" | awk '{print $2}')
        log_info "PV: $pv -> VG: $vg"
        if [ "$DRYRUN" -eq 1 ]; then
          log_info "[DRYRUN] Would deactivate and remove LVs in VG $vg and remove VG & PV $pv"
        else
          # deactivate VG
          vgchange -an "$vg" 2>/dev/null || true
          # remove LVs in that VG
          mapfile -t lvs_in_vg < <(lvs --noheadings -o lv_path "$vg" 2>/dev/null | awk '{print $1}' || true)
          for lv in "${lvs_in_vg[@]}"; do
            [ -n "$lv" ] && lvremove -ff -y "$lv" 2>/dev/null || true
          done
          # remove vg
          vgremove -ff -y "$vg" 2>/dev/null || true
          # remove pv
          pvremove -ff -y "$pv" 2>/dev/null || true
          log_info "Removed VG $vg and PV $pv (best-effort)"
        fi
      done
    fi
  fi

  # mdadm zero superblock for device and partitions
  if command -v mdadm >/dev/null 2>&1; then
    log_info "Zeroing mdadm superblocks (device + partitions)"
    for target in "$dev" $(lsblk -ln -o NAME "$dev" | awk 'NR>1{print "/dev/"$1}' || true); do
      if [ "$DRYRUN" -eq 1 ]; then
        log_info "[DRYRUN] mdadm --zero-superblock $target"
      else
        mdadm --zero-superblock --force "$target" 2>/dev/null || true
      fi
    done
  fi

  # Ceph / ZFS optional zaps
  if [ "$ZAP_CEPH" -eq 1 ] && command -v ceph-volume >/dev/null 2>&1; then
    if [ "$DRYRUN" -eq 1 ]; then
      log_info "[DRYRUN] ceph-volume lvm zap --destroy $dev"
    else
      ceph-volume lvm zap --destroy "$dev" 2>/dev/null || true
      log_info "Attempted Ceph zap on $dev"
    fi
  fi
  if [ "$ZAP_ZFS" -eq 1 ] && command -v zpool >/dev/null 2>&1; then
    if [ "$DRYRUN" -eq 1 ]; then
      log_info "[DRYRUN] zpool labelclear -f $dev"
    else
      zpool labelclear -f "$dev" 2>/dev/null || true
      log_info "Attempted ZFS labelclear on $dev"
    fi
  fi

  # wipefs + sgdisk zap-all
  if [ "$DRYRUN" -eq 1 ]; then
    log_info "[DRYRUN] wipefs -a $dev"
    log_info "[DRYRUN] sgdisk --zap-all $dev"
  else
    wipefs -a "$dev" 2>/dev/null || log_warn "wipefs returned non-zero for $dev"
    if command -v sgdisk >/dev/null 2>&1; then
      sgdisk --zap-all "$dev" 2>/dev/null || log_warn "sgdisk zap-all returned non-zero for $dev"
    fi
    log_info "wipefs and sgdisk executed on $dev"
  fi

  # residual dd head+tail (fast)
  if [ "$DRYRUN" -eq 1 ]; then
    log_info "[DRYRUN] dd zero head/tail on $dev (10MB)"
  else
    if command -v blockdev >/dev/null 2>&1; then
      sectors=$(blockdev --getsz "$dev" 2>/dev/null || echo 0)
      if [ "$sectors" -gt 20480 ]; then
        total_mb=$(( sectors / 2048 ))
        log_info "Zeroing 10MB head and tail on $dev (size ~${total_mb}MB)"
        dd if=/dev/zero of="$dev" bs=1M count=10 conv=fsync status=none || log_warn "dd head failed"
        # tail
        dd if=/dev/zero of="$dev" bs=1M count=10 seek=$(( total_mb - 10 )) conv=fsync status=none || log_warn "dd tail failed"
      fi
    fi
  fi

  # remove dm nodes referencing this disk (best-effort) if include-dm or if safe
  if [ "$INCL_DM" -eq 1 ]; then
    log_info "Removing device-mapper nodes referencing $base (best-effort)"
    remove_dm_using_disk "$base"
  fi

  # aggressive reload attempts
  log_info "Reloading kernel view for $dev (partprobe/blockdev/kpartx/udev/host rescan)"
  partprobe "$dev" 2>/dev/null || true
  blockdev --rereadpt "$dev" 2>/dev/null || true
  if command -v kpartx >/dev/null 2>&1; then
    kpartx -d "$dev" 2>/dev/null || true
    sleep 1
    kpartx -a "$dev" 2>/dev/null || true
  fi
  if [ -w "/sys/block/$base/device/rescan" ]; then
    echo 1 > "/sys/block/$base/device/rescan" 2>/dev/null || true
  fi
  for host in /sys/class/scsi_host/host*; do
    if [ -w "$host/scan" ]; then
      printf " - - -\n" > "$host/scan" 2>/dev/null || true
    fi
  done
  if command -v multipath >/dev/null 2>&1; then
    multipath -r 2>/dev/null || true
  fi
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle --timeout=5 2>/dev/null || true
  fi

  # final check
  sleep 1
  local parts
  parts=$(lsblk -n -o NAME,TYPE "$dev" | awk '$2=="part"{print $1}' || true)
  local pvleft
  pvleft=$(pvs --noheadings -o pv_name 2>/dev/null | grep "$base" || true)
  if [[ -n "$parts" || -n "$pvleft" ]]; then
    log_warn "After cleanup, $dev still shows:"
    [ -n "$parts" ] && echo "  - partitions: $parts"
    [ -n "$pvleft" ] && echo "  - LVM PV entries: $pvleft"
    echo
    echo -e "${YELLOW}Possible reasons:${RESET}"
    echo "- Some process / service still holds the device (use lsof to check)."
    echo "- Device is part of multipath/device-mapper that must be removed separately."
    echo "- Kernel cache didn't fully flush; try manual: 'echo 1 > /sys/block/${base}/device/rescan' or reboot as last resort."
    echo
    echo -e "${BLUE}Suggested next steps:${RESET}"
    echo "- Stop services using the device, unmount, then retry."
    echo "- For LVM: run 'lvs', 'vgdisplay', 'lvremove', 'vgremove', 'pvremove'."
    echo "- For mdadm: run 'mdadm --examine' and 'mdadm --zero-superblock'."
    echo "- For Ceph: consider 'ceph-volume lvm zap --destroy /dev/XXX' (use --zap-ceph)."
    echo "- For ZFS: 'zpool labelclear -f /dev/XXX' (use --zap-zfs)."
  else
    log_info "$dev appears clean (no partitions or PVs detected)."
  fi

  log_step "Finished $dev"
}

# ------------ Main flow ------------
check_missing_tools
if [ ${#missing_tools[@]} -gt 0 ]; then
  if [ "$NO_INSTALL" -eq 0 ]; then
    install_missing_tools
  else
    log_err "Missing tools: ${missing_tools[*]}. Rerun without --no-install or install them manually."
    exit 1
  fi
fi

resolve_targets "${USER_TARGETS[@]}"

log_step "Final target list"
for t in "${TARGETS[@]}"; do echo "  - $t"; done

# Ask global mode if not specified
if [[ "$MODE" != "auto" && "$MODE" != "ask" ]]; then
  read -rp "Choose mode: [auto/manual] (default manual): " mm
  [[ "$mm" == "auto" ]] && MODE="auto" || MODE="ask"
fi

# Loop and perform
for dev in "${TARGETS[@]}"; do
  if [[ "$MODE" == "ask" ]]; then
    read -rp "Process $dev ? (y/n): " ans
    [[ "$ans" != "y" ]] && { log_info "Skipping $dev"; continue; }
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    log_info "[DRYRUN] Would process $dev"
  else
    process_disk "$dev"
  fi
done

log_step "All targets processed. Done."
