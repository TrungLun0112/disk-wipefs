#!/usr/bin/env bash
# disk-wipefs v7.2
# Purpose: aggressive disk cleaner, scoped per-target (implements #disk_wipefs_checklist v2)
# Authors: ChatGPT & TrungLun0112
# WARNING: destructive. This WILL permanently erase data on target devices.

set -euo pipefail
IFS=$'\n\t'

VERSION="v7.2"

# ---------------- Colors / simple logging ----------------
C_INFO="\033[1;34m"; C_OK="\033[1;32m"; C_WARN="\033[1;33m"; C_ERR="\033[1;31m"; C_RST="\033[0m"
info()  { echo -e "$(date '+%F %T') ${C_INFO}[INFO]${C_RST} $*"; }
ok()    { echo -e "$(date '+%F %T') ${C_OK}[OK]${C_RST} $*"; }
warn()  { echo -e "$(date '+%F %T') ${C_WARN}[WARN]${C_RST} $*"; }
err()   { echo -e "$(date '+%F %T') ${C_ERR}[ERROR]${C_RST} $*" >&2; }

trap 'err "Interrupted by user"; exit 130' INT

# ---------------- Globals & defaults ----------------
FORCE_SDA=0
ALL_MODE=0
TARGET_ARGS=()

# Essential commands this script expects (will abort if missing)
ESSENTIAL=(wipefs sgdisk partprobe blockdev lsblk dd)

# ---------------- Usage ----------------
usage() {
  cat <<EOF
disk-wipefs $VERSION — aggressive, per-target disk cleaner

Usage:
  sudo $0 [--all] [--force] <device1> <device2> ...
Examples:
  sudo $0 sdb
  sudo $0 /dev/sdb
  sudo $0 sd*        # glob patterns supported
  sudo $0 --all      # wipe all disks except /dev/sda by default
  sudo $0 --all --force  # include /dev/sda (DANGEROUS)

Notes:
 - No dry-run, no backup, no logging to file by design.
 - Script will attempt to only operate on the given targets and their partitions.
 - Be careful: destructive operations follow.
EOF
  exit 1
}

# ---------------- 1) Detect OS ----------------
detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
    info "Detected OS: $OS_PRETTY"
  else
    OS_ID="unknown"
    warn "Unable to detect OS"
  fi
}

# ---------------- 2) Check tools ----------------
check_tools() {
  local miss=()
  for cmd in "${ESSENTIAL[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      miss+=("$cmd")
    fi
  done
  if [ ${#miss[@]} -gt 0 ]; then
    err "Missing essential tools: ${miss[*]}. Please install them and re-run."
    exit 2
  fi
  ok "All essential tools present"
}

# ---------------- Helpers to normalize ----------------
normalize_dev() {
  # input may be "sdb" or "/dev/sdb" -> output "/dev/sdb"
  local in="$1"
  if [[ "$in" == /dev/* ]]; then
    echo "$in"
  else
    echo "/dev/${in}"
  fi
}

is_disk_present() {
  # arg: /dev/sdX
  local dev="$1"
  if lsblk -ndo TYPE "$dev" 2>/dev/null | grep -q '^disk$'; then
    return 0
  else
    return 1
  fi
}

# ---------------- 3) Resolve targets ----------------
resolve_targets() {
  local inputs=("$@")
  local resolved=()
  if [ ${#inputs[@]} -eq 0 ]; then
    err "No targets specified"
    usage
  fi

  # single 'all' behavior
  if [ "${inputs[0]}" == "--all" ] || [ "${inputs[0]}" == "all" ]; then
    ALL_MODE=1
    # enumerate disks
    mapfile -t devs < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
    for d in "${devs[@]}"; do
      base=$(basename "$d")
      # skip special devices
      if [[ "$base" =~ ^(sr|loop|ram) ]]; then
        continue
      fi
      if [[ "$base" == "sda" && "$FORCE_SDA" -eq 0 ]]; then
        continue
      fi
      resolved+=("$d")
    done
  else
    # each input may be a glob pattern or device
    for tok in "${inputs[@]}"; do
      # flags already processed earlier; skip them just in case
      if [[ "$tok" == "--force" ]] || [[ "$tok" == "--all" ]]; then
        continue
      fi
      if [[ "$tok" == *"*"* ]]; then
        # convert glob to anchored regex
        re="^${tok//\*/.*}$"
        mapfile -t matches < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print $1}' | grep -E "$re" || true)
        for m in "${matches[@]}"; do resolved+=("/dev/$m"); done
      else
        dev=$(normalize_dev "$tok")
        if is_disk_present "$dev"; then
          resolved+=("$dev")
        else
          err "Target device not present or not a disk: $dev"
          exit 3
        fi
      fi
    done
  fi

  # dedupe while preserving order
  TARGETS=()
  declare -A seen
  for d in "${resolved[@]}"; do
    if [[ -z "${seen[$d]:-}" ]]; then TARGETS+=("$d"); seen[$d]=1; fi
  done

  if [ ${#TARGETS[@]} -eq 0 ]; then
    err "No valid targets resolved"
    exit 4
  fi

  info "Resolved targets:"
  for t in "${TARGETS[@]}"; do info " - $t"; done
}

# ---------------- 4) Validate target (extra checks) ----------------
validate_target() {
  local dev="$1"
  local base
  base=$(basename "$dev")

  if ! is_disk_present "$dev"; then
    err "Not a disk: $dev"
    return 1
  fi
  if [[ "$base" == "sda" ]] && [[ "$FORCE_SDA" -eq 0 ]]; then
    err "$dev is protected by default (use --force to allow wiping sda)"
    return 1
  fi
  # ok
  return 0
}

# ---------------- 5) Pre-clean: unmount partitions & swap ----------------
preclean_unmount_swap() {
  local dev="$1"
  info "[preclean] Unmount partitions of $dev"
  # unmount only partitions belonging to this disk
  mapfile -t parts < <(lsblk -nr -o NAME "$dev" | awk 'NR>1{print "/dev/"$1}' || true)
  for p in "${parts[@]:-}"; do
    if mount | grep -q "^${p} "; then
      info " - umount $p"
      umount -l "$p" 2>/dev/null || umount -f "$p" 2>/dev/null || warn "unable to unmount $p"
    fi
  done

  info "[preclean] swapoff partitions on $dev (if any)"
  mapfile -t swaps < <(lsblk -nr -o NAME,TYPE "$dev" | awk '$2=="swap"{print "/dev/"$1}' || true)
  for s in "${swaps[@]:-}"; do
    info " - swapoff $s"
    swapoff "$s" 2>/dev/null || warn "swapoff failed for $s"
  done
}

# ---------------- 6) LVM: remove PV metadata on target only (best-effort) ----------------
lvm_clean_pvs_on_device() {
  local dev="$1"
  info "[lvm] Checking PVs on $dev"
  if ! command -v pvs >/dev/null 2>&1; then
    warn "pvs not available; skipping LVM PV cleanup"
    return
  fi

  # find PV entries that exactly match device or its partitions
  mapfile -t pvs_list < <(pvs --noheadings -o pv_name 2>/dev/null | awk '{print $1}' || true)
  for pv in "${pvs_list[@]:-}"; do
    if [[ "$pv" == "$dev" ]] || [[ "$pv" == ${dev}* ]]; then
      info " - Found PV: $pv (on $dev). Attempting pvremove (device-scoped)"
      # Try to deactivate VG partialy by removing the PV only (do not vgchange -an globally)
      if command -v pvremove >/dev/null 2>&1; then
        pvremove -ff -y "$pv" 2>/dev/null || warn "pvremove failed on $pv"
      else
        # fallback: wipefs on PV device
        wipefs -a -f "$pv" 2>/dev/null || warn "wipefs on $pv failed"
      fi
    fi
  done
}

# ---------------- 7) mdadm: zero superblocks only on device/its partitions ----------------
mdadm_clean_device() {
  local dev="$1"
  if ! command -v mdadm >/dev/null 2>&1; then
    warn "mdadm not installed; skipping mdadm cleanup"
    return
  fi
  info "[mdadm] Zeroing superblocks on $dev and its partitions (best-effort)"
  # try device and partitions
  targets=("$dev")
  mapfile -t parts < <(lsblk -nr -o NAME "$dev" | awk 'NR>1{print "/dev/"$1}' || true)
  for p in "${parts[@]:-}"; do targets+=("$p"); done
  for t in "${targets[@]}"; do
    mdadm --zero-superblock --force "$t" 2>/dev/null || true
  done
}

# ---------------- 8) Ceph and ZFS: attempt device-scoped cleanup ----------------
ceph_zap_device() {
  local dev="$1"
  if ! command -v ceph-volume >/dev/null 2>&1; then
    warn "ceph-volume not installed; skipping Ceph zap"
    return
  fi
  info "[ceph] Attempting ceph-volume lvm zap on partitions of $dev (best-effort)"
  # zap each partition or whole device
  mapfile -t parts < <(lsblk -nr -o NAME "$dev" | awk 'NR>1{print "/dev/"$1}' || true)
  if [ ${#parts[@]} -eq 0 ]; then parts=("$dev"); fi
  for p in "${parts[@]}"; do
    ceph-volume lvm zap --destroy "$p" 2>/dev/null || warn "ceph-volume zap failed for $p"
  done
}

zfs_labelclear_device() {
  local dev="$1"
  if ! command -v zpool >/dev/null 2>&1; then
    warn "zpool not installed; skipping ZFS labelclear"
    return
  fi
  info "[zfs] Attempting zpool labelclear on partitions of $dev (best-effort)"
  mapfile -t parts < <(lsblk -nr -o NAME "$dev" | awk 'NR>1{print "/dev/"$1}' || true)
  if [ ${#parts[@]} -eq 0 ]; then parts=("$dev"); fi
  for p in "${parts[@]}"; do
    zpool labelclear -f "$p" 2>/dev/null || true
  done
}

# ---------------- 9) Multipath: remove maps referencing this device only ----------------
multipath_clean_device() {
  local dev="$1"
  if ! command -v multipath >/dev/null 2>&1; then
    warn "multipath not installed; skipping multipath cleaning"
    return
  fi
  info "[multipath] Searching maps referencing $dev"
  # look for maps that show /dev/<dev>
  mapfile -t maps < <(multipath -ll 2>/dev/null | awk '/^ /{next} {print $1}' | while read -r m; do multipath -ll "$m" 2>/dev/null | grep -q "/dev/$(basename "$dev")" && echo "$m"; done)
  for m in "${maps[@]:-}"; do
    info " - Removing multipath map $m (best-effort)"
    multipath -f "$m" 2>/dev/null || warn "multipath -f $m failed"
  done
}

# ---------------- 10) Wipe sequence (wipefs, sgdisk, dd head/tail, blkdiscard) ----------------
wipe_sequence() {
  local dev="$1"
  info "[wipe] wipefs -a on $dev"
  wipefs -a -f "$dev" 2>/dev/null || warn "wipefs reported non-zero for $dev"

  info "[wipe] sgdisk --zap-all on $dev"
  if command -v sgdisk >/dev/null 2>&1; then
    sgdisk --zap-all "$dev" 2>/dev/null || warn "sgdisk failed"
  fi

  # wipe partitions too (device + partitions)
  mapfile -t parts < <(lsblk -nr -o NAME "$dev" | awk 'NR>1{print "/dev/"$1}' || true)
  targets=("$dev" "${parts[@]:-}")

  # attempt blkdiscard first (fast, but not supported everywhere)
  if command -v blkdiscard >/dev/null 2>&1; then
    info "[wipe] blkdiscard attempt on $dev (if supported)"
    blkdiscard "$dev" 2>/dev/null || warn "blkdiscard unsupported/failed on $dev"
  fi

  # dd head & tail (10 MB default)
  if command -v blockdev >/dev/null 2>&1; then
    sectors=$(blockdev --getsz "$dev" 2>/dev/null || echo 0)
    if [ "$sectors" -gt 20480 ]; then
      total_mb=$(( sectors / 2048 ))
      head_mb=10
      tail_mb=10
      info "[wipe] dd zero head ${head_mb}MB on $dev"
      dd if=/dev/zero of="$dev" bs=1M count=$head_mb conv=fsync status=none || warn "dd head failed"
      seek=$(( total_mb - tail_mb ))
      if [ "$seek" -gt 0 ]; then
        info "[wipe] dd zero tail ${tail_mb}MB on $dev (seek=${seek})"
        dd if=/dev/zero of="$dev" bs=1M count=$tail_mb seek=$seek conv=fsync status=none || warn "dd tail failed"
      fi
    else
      warn "[wipe] Device too small or blockdev failed to get size; skipping dd head/tail"
    fi
  else
    warn "[wipe] blockdev not available; skipping dd head/tail"
  fi

  # ensure partitions also wiped (wipefs on partitions)
  for p in "${targets[@]:-}"; do
    wipefs -a -f "$p" 2>/dev/null || true
  done
  ok "[wipe] wipe sequence done for $dev"
}

# ---------------- 11) Reload kernel / udev / multipath ----------------
reload_and_verify() {
  local dev="$1"
  local base
  base=$(basename "$dev")
  info "[reload] partprobe / blockdev reread"
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

  if command -v multipath >/dev/null 2>&1; then
    multipath -r 2>/dev/null || true
  fi

  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle --timeout=5 2>/dev/null || true
  fi

  sleep 1
  info "[verify] lsblk for $dev:"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$dev" || true
  info "[verify] wipefs output (should be empty):"
  wipefs "$dev" || true

  # quick LVM check
  if command -v pvs >/dev/null 2>&1; then
    pvs --noheadings -o pv_name 2>/dev/null | grep -F "$(basename "$dev")" >/dev/null 2>&1 && warn "LVM PV referencing ${dev} still present" || ok "No LVM PV found on ${dev}"
  fi
}

# ---------------- Main flow ----------------
main() {
  if [ $# -lt 1 ]; then usage; fi

  # parse basic flags --force and --all (they may be anywhere)
  ARGS=()
  while (( "$#" )); do
    case "$1" in
      --force) FORCE_SDA=1; shift ;;
      --all) ALL_MODE=1; shift ;;
      -h|--help) usage ;;
      *) ARGS+=("$1"); shift ;;
    esac
  done

  detect_os
  check_tools

  # if ALL_MODE, resolve_targets called with 'all'
  if [ "$ALL_MODE" -eq 1 ] && [ ${#ARGS[@]} -eq 0 ]; then
    resolve_targets --all
  else
    resolve_targets "${ARGS[@]}"
  fi

  # iterate targets
  for dev in "${TARGETS[@]}"; do
    # validate
    if ! validate_target "$dev"; then
      warn "Skipping invalid target $dev"
      continue
    fi
    info "=== Processing $dev ==="
    preclean_unmount_swap "$dev"
    lvm_clean_pvs_on_device "$dev"
    mdadm_clean_device "$dev"
    ceph_zap_device "$dev"
    zfs_labelclear_device "$dev"
    multipath_clean_device "$dev"
    wipe_sequence "$dev"
    reload_and_verify "$dev"
    ok "Finished $dev"
  done

  ok "All targets processed. Please inspect outputs (lsblk, wipefs, pvs)."
}

main "$@"
