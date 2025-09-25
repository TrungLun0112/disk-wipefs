#!/usr/bin/env bash
# disk-wipefs.sh v7.6-fixed
# Purpose: Clean target disk(s) completely (LVM/Ceph/ZFS/dm/etc), scoped per-target
# Authors: TrungLun0112 + ChatGPT
# WARNING: destructive. This script WILL permanently erase data on target devices.

set -euo pipefail
IFS=$'\n\t'

VERSION="v7.6-fixed"

# ---------------- Logging helpers ----------------
C_INFO="\033[1;34m"; C_OK="\033[1;32m"; C_WARN="\033[1;33m"; C_ERR="\033[1;31m"; C_RST="\033[0m"
info()  { echo -e "$(date '+%F %T') ${C_INFO}[INFO]${C_RST} $*"; }
ok()    { echo -e "$(date '+%F %T') ${C_OK}[OK]${C_RST} $*"; }
warn()  { echo -e "$(date '+%F %T') ${C_WARN}[WARN]${C_RST} $*"; }
err()   { echo -e "$(date '+%F %T') ${C_ERR}[ERROR]${C_RST} $*" >&2; }

trap 'err "Interrupted by user"; exit 130' INT

# ---------------- Globals ----------------
FORCE_SDA=0
ALL_MODE=0
TARGETS=()

# Essential commands (script will warn if missing and skip relevant steps)
ESSENTIAL=(wipefs dd partprobe blockdev lsblk)
RECOMMENDED=(sgdisk pvremove lvremove vgremove pvs lvs vgs mdadm dmsetup multipath ceph-volume zpool blkdiscard kpartx udevadm)

usage(){
  cat <<EOF
disk-wipefs $VERSION  — Aggressive disk cleaner (per-target)

Usage:
  sudo $0 <disk1> [disk2 ...]   # disk can be 'sdb' or '/dev/sdb' or glob 'sd*'
  sudo $0 --all [--force]       # wipe all /dev/sd? except /dev/sda by default
Options:
  --force   : allow wiping /dev/sda (DANGEROUS)
  --all     : wipe all discovered /dev/sd? (respect --force for sda)
  -h|--help : show this help

Notes:
 - No dry-run, no backups. Destructive tool.
 - Script scopes every action to the target device(s) only (no global vgchange -an).
EOF
  exit 1
}

# ---------------- Normalize & resolve ----------------
normalize_dev() {
  # accept "sdb" or "/dev/sdb" -> return "/dev/sdb"
  local in="$1"
  if [[ "$in" == /dev/* ]]; then
    echo "$in"
  else
    echo "/dev/$in"
  fi
}

is_block_device() {
  local dev="$1"
  [[ -b "$dev" ]]
}

# resolve patterns like sd* -> list matching /dev/sd?
expand_and_resolve_targets() {
  local args=("$@")
  local resolved=()
  if [ ${#args[@]} -eq 0 ]; then
    err "No targets specified"
    usage
  fi

  # support --all flag handled earlier
  for tok in "${args[@]}"; do
    if [[ "$tok" == *"*"* ]]; then
      # expand glob against /dev listing
      for n in $(ls /dev 2>/dev/null | grep -E "^${tok}$" || true); do
        resolved+=("/dev/$n")
      done
      # also try matching sd* pattern specifically
      for n in $(ls /dev | grep -E "^${tok}$" 2>/dev/null || true); do
        resolved+=("/dev/$n")
      done
    else
      resolved+=("$(normalize_dev "$tok")")
    fi
  done

  # dedupe and validate
  declare -A seen
  TARGETS=()
  for d in "${resolved[@]}"; do
    [[ -z "$d" ]] && continue
    # skip non-block devices
    if ! is_block_device "$d"; then
      warn "Skipping $d: not a block device"
      continue
    fi
    base=$(basename "$d")
    # skip special devices always
    if [[ "$base" =~ ^(loop|ram|sr|fd) ]]; then
      warn "Skipping special device $d"
      continue
    fi
    # protect sda unless forced
    if [[ "$base" == "sda" ]] && [[ "$FORCE_SDA" -eq 0 ]]; then
      warn "Skipping $d (system disk). Use --force to override."
      continue
    fi
    if [[ -z "${seen[$d]:-}" ]]; then TARGETS+=("$d"); seen[$d]=1; fi
  done

  if [ ${#TARGETS[@]} -eq 0 ]; then
    err "No valid targets resolved after validation"
    exit 2
  fi
}

# ---------------- Pre-check tools ----------------
check_tools() {
  info "Checking required commands..."
  local miss=()
  for cmd in "${ESSENTIAL[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then miss+=("$cmd"); fi
  done
  if [ ${#miss[@]} -gt 0 ]; then
    err "Missing essential commands: ${miss[*]}. Please install them and re-run."
    exit 3
  fi
  ok "Essential tools present"
}

# ---------------- Per-target safe-clean functions ----------------
preclean_unmount_swap() {
  local dev="$1"
  info "[preclean] Unmount partitions of $dev"
  mapfile -t parts < <(lsblk -nr -o NAME "$dev" | awk 'NR>1{print "/dev/"$1}' || true)
  for p in "${parts[@]:-}"; do
    if mount | grep -q "^${p} "; then
      info " - umount $p"
      umount -l "$p" 2>/dev/null || umount -f "$p" 2>/dev/null || warn "Failed to unmount $p"
    fi
  done

  info "[preclean] swapoff for $dev (if any)"
  mapfile -t swaps < <(lsblk -nr -o NAME,TYPE "$dev" | awk '$2=="swap"{print "/dev/"$1}' || true)
  for s in "${swaps[@]:-}"; do
    info " - swapoff $s"
    swapoff "$s" 2>/dev/null || warn "swapoff failed for $s"
  done
}

lvm_cleanup_scoped() {
  local dev="$1"
  info "[lvm] Scanning PVs on $dev (device-scoped)"
  if ! command -v pvs &>/dev/null; then
    warn "pvs not available; skipping LVM cleanup"
    return
  fi

  mapfile -t pvs_list < <(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk '{print $1 "|" $2}' || true)
  for entry in "${pvs_list[@]:-}"; do
    pv=$(echo "$entry" | cut -d'|' -f1)
    vg=$(echo "$entry" | cut -d'|' -f2)
    if [[ "$pv" == "$dev" ]] || [[ "$pv" == ${dev}* ]]; then
      info " - PV $pv belongs to VG $vg"
      # find LVs that use this PV
      mapfile -t lv_list < <(lvs --noheadings -o lv_name,lv_path -S vg_name="$vg" 2>/dev/null | awk '{print $1 "|" $2}' || true)
      for lv_entry in "${lv_list[@]:-}"; do
        lv_name=$(echo "$lv_entry" | cut -d'|' -f1)
        lv_path=$(echo "$lv_entry" | cut -d'|' -f2)
        # only remove LVs that look like Ceph/osd by heuristic, to avoid removing system LVs
        if echo "$lv_name" | grep -Ei 'osd|ceph' >/dev/null 2>&1; then
          info "   - Attempt lvremove /dev/$vg/$lv_name (heuristic match)"
          lvremove -ff "/dev/$vg/$lv_name" 2>/dev/null && info "     lvremove OK: /dev/$vg/$lv_name" || warn "     lvremove FAILED: /dev/$vg/$lv_name"
        else
          info "   - Skipping LV $lv_path (not matched by heuristic)"
        fi
      done
      # attempt to remove pv from vg (device-scoped)
      if command -v vgreduce &>/dev/null; then
        vgreduce "$vg" "$pv" 2>/dev/null || true
      fi
      # try pvremove on the pv
      if command -v pvremove &>/dev/null; then
        pvremove -ff "$pv" 2>/dev/null && info "     pvremove OK: $pv" || warn "     pvremove FAILED: $pv"
      fi
    fi
  done
}

mdadm_zero_scoped() {
  local dev="$1"
  if ! command -v mdadm &>/dev/null; then
    warn "mdadm not found; skipping mdadm cleanup"
    return
  fi
  info "[mdadm] zero-superblock on $dev and partitions (scoped)"
  local targets=("$dev")
  mapfile -t parts < <(lsblk -nr -o NAME "$dev" | awk 'NR>1{print "/dev/"$1}' || true)
  for p in "${parts[@]:-}"; do targets+=("$p"); done
  for t in "${targets[@]}"; do
    mdadm --zero-superblock --force "$t" 2>/dev/null || true
  done
}

remove_dm_maps_scoped() {
  local dev="$1"
  if ! command -v dmsetup &>/dev/null; then
    warn "dmsetup not found; skipping dm removal"
    return
  fi
  info "[dm] Removing device-mapper maps referencing $(basename "$dev")"
  maplist=$(dmsetup ls --noheadings 2>/dev/null | awk '{print $1}' || true)
  for m in $maplist; do
    if dmsetup info "$m" 2>/dev/null | grep -q "$(basename "$dev")"; then
      info " - dmsetup remove -f $m"
      dmsetup remove -f "$m" 2>/dev/null && info "   removed $m" || warn "   failed to remove $m"
    fi
  done
}

ceph_zap_scoped() {
  local dev="$1"
  if ! command -v ceph-volume &>/dev/null; then
    warn "ceph-volume not present; skipping Ceph zap"
    return
  fi
  info "[ceph] Attempting ceph-volume lvm zap --destroy on partitions of $dev"
  mapfile -t parts < <(lsblk -nr -o NAME "$dev" | awk 'NR>1{print "/dev/"$1}' || true)
  if [ ${#parts[@]} -eq 0 ]; then parts=("$dev"); fi
  for p in "${parts[@]}"; do
    ceph-volume lvm zap --destroy "$p" 2>/dev/null && info " - ceph-volume zap OK: $p" || warn " - ceph-volume zap failed for $p"
  done
}

zfs_labelclear_scoped() {
  local dev="$1"
  if ! command -v zpool &>/dev/null; then
    warn "zpool not present; skipping ZFS labelclear"
    return
  fi
  info "[zfs] Attempt zpool labelclear on partitions of $dev"
  mapfile -t parts < <(lsblk -nr -o NAME "$dev" | awk 'NR>1{print "/dev/"$1}' || true)
  if [ ${#parts[@]} -eq 0 ]; then parts=("$dev"); fi
  for p in "${parts[@]}"; do
    zpool labelclear -f "$p" 2>/dev/null && info " - zpool labelclear OK: $p" || warn " - zpool labelclear failed for $p"
  done
}

wipe_sequence_scoped() {
  local dev="$1"
  info "[wipe] wipefs -a on $dev"
  wipefs -a -f "$dev" 2>/dev/null || warn "wipefs returned non-zero for $dev"

  info "[wipe] sgdisk --zap-all on $dev (if available)"
  if command -v sgdisk &>/dev/null; then sgdisk --zap-all "$dev" 2>/dev/null || warn "sgdisk failed"; fi

  # blkdiscard if supported
  if command -v blkdiscard &>/dev/null; then
    info "[wipe] blkdiscard attempt on $dev"
    blkdiscard "$dev" 2>/dev/null || warn "blkdiscard unsupported/failed on $dev"
  fi

  # dd head/tail (10MB)
  if command -v blockdev &>/dev/null; then
    sectors=$(blockdev --getsz "$dev" 2>/dev/null || echo 0)
    if [ "$sectors" -gt 20480 ]; then
      total_mb=$(( sectors / 2048 ))
      head_mb=10; tail_mb=10
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

  # ensure partitions also wiped
  mapfile -t parts < <(lsblk -nr -o NAME "$dev" | awk 'NR>1{print "/dev/"$1}' || true)
  targets=("$dev" "${parts[@]:-}")
  for p in "${targets[@]:-}"; do
    wipefs -a -f "$p" 2>/dev/null || true
  done
  ok "[wipe] done for $dev"
}

reload_and_verify_scoped() {
  local dev="$1"
  local base
  base=$(basename "$dev")
  info "[reload] partprobe / blockdev reread for $dev"
  partprobe "$dev" 2>/dev/null || true
  blockdev --rereadpt "$dev" 2>/dev/null || true

  if command -v kpartx &>/dev/null; then
    kpartx -d "$dev" 2>/dev/null || true
    sleep 1
    kpartx -a "$dev" 2>/dev/null || true
  fi

  if [ -w "/sys/block/$base/device/rescan" ]; then
    echo 1 > "/sys/block/$base/device/rescan" 2>/dev/null || true
  fi

  if command -v multipath &>/dev/null; then multipath -r 2>/dev/null || true; fi
  if command -v udevadm &>/dev/null; then udevadm settle --timeout=5 2>/dev/null || true; fi

  sleep 1
  info "[verify] lsblk for $dev:"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$dev" || true
  info "[verify] wipefs output (should be empty):"
  wipefs "$dev" || true

  if command -v pvs &>/dev/null; then
    if pvs --noheadings -o pv_name 2>/dev/null | grep -F "$(basename "$dev")" >/dev/null 2>&1; then
      warn "LVM PV referencing ${dev} still present"
    else
      ok "No LVM PV found on ${dev}"
    fi
  fi
}

# ---------------- Main flow ----------------
main() {
  if [ $# -eq 0 ]; then usage; fi

  ARGS=()
  while (( "$#" )); do
    case "$1" in
      --force) FORCE_SDA=1; shift ;;
      --all) ALL_MODE=1; shift ;;
      -h|--help) usage ;;
      *) ARGS+=("$1"); shift ;;
    esac
  done

  # if --all requested
  if [ "$ALL_MODE" -eq 1 ]; then
    # enumerate disks, skip special, skip sda unless forced
    mapfile -t devs < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
    INPUTS=()
    for d in "${devs[@]}"; do
      base=$(basename "$d")
      if [[ "$base" == "sda" && "$FORCE_SDA" -eq 0 ]]; then
        warn "Skipping /dev/sda by default"
        continue
      fi
      INPUTS+=("$d")
    done
  else
    INPUTS=("${ARGS[@]}")
  fi

  # resolve targets (normalize & validate)
  expand_and_resolve_targets "${INPUTS[@]}"
  check_tools

  info "Targets to process:"
  for t in "${TARGETS[@]}"; do info " - $t"; done

  for dev in "${TARGETS[@]}"; do
    info "=== Processing $dev ==="
    preclean_unmount_swap "$dev"
    lvm_cleanup_scoped "$dev"
    mdadm_zero_scoped "$dev"
    remove_dm_maps_scoped "$dev"
    ceph_zap_scoped "$dev"
    zfs_labelclear_scoped "$dev"
    wipe_sequence_scoped "$dev"
    reload_and_verify_scoped "$dev"
    ok "Finished $dev"
  done

  ok "All requested targets processed. Verify with 'lsblk', 'wipefs', 'pvs'."
}

main "$@"
