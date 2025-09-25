#!/usr/bin/env bash
#
# disk-wipefs v2.6  — Strong, "do-everything" disk metadata cleaner
# Author: ChatGPT & TrungLun0112
# Repo: https://github.com/TrungLun0112/disk-wipefs
#
# WARNING: destructive. This will attempt to remove ANY metadata (LVM, mdadm, Ceph, ZFS,
# multipath, partition tables ...). Use --dry-run first. Default skips /dev/sda unless --force used.
#

set -euo pipefail
IFS=$'\n\t'

VERSION="v2.6"

# ----------------------- Defaults / Globals -----------------------
DRYRUN=0
MODE="manual"          # manual or auto
YES_ALL=0
FORCE_SDA=0
NO_INSTALL=0
INCLUDE_DM=0
QUIET=0
NOCOLOR=0
LOGFILE=""
TIMEOUT=0               # seconds to wait for user input
EXCLUDE_LIST=()
PATTERN_LIST=()
USER_INPUT=()
TARGETS=()
OS_ID=""
VERBOSE=1

# Essential tools (we expect at least core ones)
ESSENTIAL=(wipefs sgdisk partprobe blockdev lsblk)
# Recommended (we will call if available or try to install)
RECOMMENDED=(mdadm lvm2 kpartx dmsetup multipath ceph-volume zpool dd blkdiscard udevadm)

# ----------------------- Colors & logging -----------------------
if [ "$NOCOLOR" -eq 0 ]; then
  C_INFO="\033[1;34m"  # blue
  C_OK="\033[1;32m"    # green
  C_WARN="\033[1;33m"  # yellow
  C_ERR="\033[1;31m"   # red
  C_RST="\033[0m"
else
  C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_RST=""
fi

log() {
  [ "$QUIET" -eq 0 ] && echo -e "$(date '+%F %T') ${C_INFO}[INFO]${C_RST} $*" | tee -a "$LOGFILE" 2>/dev/null || true
}
ok() {
  [ "$QUIET" -eq 0 ] && echo -e "$(date '+%F %T') ${C_OK}[OK]${C_RST} $*" | tee -a "$LOGFILE" 2>/dev/null || true
}
warn() {
  [ "$QUIET" -eq 0 ] && echo -e "$(date '+%F %T') ${C_WARN}[WARN]${C_RST} $*" | tee -a "$LOGFILE" 2>/dev/null || true
}
err() {
  echo -e "$(date '+%F %T') ${C_ERR}[ERROR]${C_RST} $*" | tee -a "$LOGFILE" >&2 || true
}

# ----------------------- Helpers -----------------------
run_cmd() {
  # wrapper: logs & respects DRYRUN
  if [ "$DRYRUN" -eq 1 ]; then
    log "[DRYRUN] $*"
  else
    if [ "$VERBOSE" -eq 1 ]; then
      log "RUN: $*"
    fi
    eval "$@"
  fi
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    err "This script must be run as root (sudo)."
    exit 1
  fi
}

usage() {
  cat <<EOF
disk-wipefs $VERSION  - Aggressive disk metadata cleaner (LVM / mdadm / Ceph / ZFS / multipath)

Usage:
  sudo $0 [options] <targets...>

Targets:
  all                  - all detected disks (sd*, nvme*, vd*, mmcblk*), default skip sda
  sdb nvme0n1          - explicit devices (omit /dev/ if you like)
  sd* nvme*            - shell-style glob patterns (script expands)

Options:
  --auto               - automatic mode (no per-disk prompt)
  --manual             - manual mode (default)
  -y, --yes            - assume Yes to all prompts (implies --auto)
  --dry-run            - show actions only, do not execute destructive commands
  --force              - allow wiping /dev/sda (dangerous)
  --exclude x,y        - comma-separated device names to exclude (e.g. sda,nvme0n1)
  --pattern p1,p2      - comma-separated shell patterns (e.g. sd*,nvme*)
  --no-install         - do NOT auto-install missing tools; fail if missing
  --include-dm         - include device-mapper (/dev/dm-*, /dev/mapper/*) as targets
  --log-file /path     - write output to file (appends)
  --no-color           - disable colored output
  --quiet              - minimal output
  --timeout N          - prompt timeout in seconds (0 = wait forever)
  -h, --help           - show this help

Examples:
  sudo $0 sdb
  sudo $0 all --auto
  sudo $0 sd* --dry-run
  sudo $0 nvme0n1 --log-file /tmp/wipe.log --auto

EOF
  exit 1
}

# ----------------------- Parse args -----------------------
if [ $# -eq 0 ]; then usage; fi

while (( "$#" )); do
  case "$1" in
    --auto) MODE="auto"; shift ;;
    --manual) MODE="manual"; shift ;;
    -y|--yes) YES_ALL=1; MODE="auto"; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    --force) FORCE_SDA=1; shift ;;
    --no-install) NO_INSTALL=1; shift ;;
    --include-dm) INCLUDE_DM=1; shift ;;
    --log-file) LOGFILE="$2"; shift 2 ;;
    --no-color) NOCOLOR=1; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_RST=""; shift ;;
    --quiet) QUIET=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --exclude) IFS=',' read -r -a EXCLUDE_LIST <<< "$2"; shift 2 ;;
    --pattern) IFS=',' read -r -a PATTERN_LIST <<< "$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) usage ;;
    all) USER_INPUT+=("all"); shift ;;
    *) USER_INPUT+=("$1"); shift ;;
  esac
done

# ----------------------- Init -----------------------
require_root
log "disk-wipefs $VERSION starting"
log "Credits: ChatGPT & TrungLun0112 - https://github.com/TrungLun0112/disk-wipefs"

# detect OS
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  PRETTY="${PRETTY_NAME:-$OS_ID}"
  log "Detected OS: $PRETTY"
else
  OS_ID="unknown"
  warn "Cannot reliably detect OS"
fi

# ----------------------- Tool checks & optional install -----------------------
MISSING=()
check_tools() {
  MISSING=()
  for t in "${ESSENTIAL[@]}"; do
    if ! command -v "$t" &>/dev/null; then
      MISSING+=("$t")
    fi
  done
  if [ ${#MISSING[@]} -gt 0 ]; then
    warn "Missing essential tools: ${MISSING[*]}"
    return 0
  fi
  ok "All essential tools present"
  return 1
}

install_tools() {
  if [ ${#MISSING[@]} -eq 0 ]; then return; fi
  if [ "$NO_INSTALL" -eq 1 ]; then
    err "Missing tools: ${MISSING[*]} and --no-install set. Aborting."
    exit 1
  fi

  # Fix cdrom entries for apt if present (Ubuntu/Debian)
  if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
    if grep -qi 'cdrom' /etc/apt/sources.list 2>/dev/null || ls /etc/apt/sources.list.d/* 2>/dev/null | xargs grep -Iq 'cdrom' 2>/dev/null; then
      warn "Commenting out cdrom entries in apt sources to allow package installs."
      sed -i.bak -E 's|(^deb .+cdrom)|#\1|' /etc/apt/sources.list 2>/dev/null || true
    fi
  fi

  log "Installing missing tools (best-effort)..."
  case "$OS_ID" in
    ubuntu|debian)
      run_cmd "apt-get update -y || true"
      run_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y gdisk kpartx lvm2 mdadm || true"
      ;;
    rhel|centos|rocky|almalinux)
      run_cmd "yum install -y gdisk kpartx lvm2 mdadm || true"
      ;;
    fedora)
      run_cmd "dnf install -y gdisk kpartx lvm2 mdadm || true"
      ;;
    sles|opensuse)
      run_cmd "zypper install -y gptfdisk kpartx lvm2 mdadm || true"
      ;;
    arch)
      run_cmd "pacman -Sy --noconfirm gptfdisk kpartx lvm2 mdadm || true"
      ;;
    alpine)
      run_cmd "apk add gptfdisk kpartx lvm2 mdadm || true"
      ;;
    *)
      warn "Auto-install not supported on OS=$OS_ID. Please install: ${MISSING[*]}"
      exit 1
      ;;
  esac

  check_tools || ok "Tools now available (or partially available)"
}

# ----------------------- Resolve targets -----------------------
resolve_targets() {
  local inputs=("${USER_INPUT[@]}")
  # merge PATTERN_LIST
  for p in "${PATTERN_LIST[@]:-}"; do inputs+=("$p"); done

  local cand=()
  if [ ${#inputs[@]} -eq 1 ] && [ "${inputs[0]}" == "all" ]; then
    mapfile -t devs < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
    cand=("${devs[@]}")
  else
    for tok in "${inputs[@]}"; do
      if [[ "$tok" == *"*"* ]]; then
        local re="^${tok//\*/.*}$"
        mapfile -t match < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print $1}' | grep -E "$re" || true)
        for m in "${match[@]}"; do cand+=("/dev/$m"); done
      else
        if [[ "$tok" =~ ^/dev/ ]]; then cand+=("$tok"); else cand+=("/dev/$tok"); fi
      fi
    done
  fi

  # filter excludes + defaults
  declare -A seen
  TARGETS=()
  for d in "${cand[@]}"; do
    [ -z "$d" ] && continue
    base=$(basename "$d")
    # user excludes
    skip=0
    for ex in "${EXCLUDE_LIST[@]:-}"; do
      if [[ "$ex" == "$base" || "$ex" == "$d" ]]; then skip=1; break; fi
    done
    [ $skip -eq 1 ] && { log "User exclude skip: $d"; continue; }

    # skip sda by default
    if [[ "$base" == "sda" && "$FORCE_SDA" -eq 0 ]]; then
      log "Default skip /dev/sda (use --force to override)"
      continue
    fi
    # skip sr*, loop, ram
    if [[ "$base" =~ ^sr ]] || [[ "$base" =~ ^loop ]] || [[ "$base" =~ ^ram ]]; then
      log "Skipping special device $d"
      continue
    fi
    # skip dm/mapper unless included
    if ([[ "$base" =~ ^dm- ]] || [[ "$d" =~ /dev/mapper/ ]]) && [ "$INCLUDE_DM" -eq 0 ]; then
      log "Skipping device-mapper $d (use --include-dm to include)"
      continue
    fi
    # ensure it's a disk
    if ! lsblk -ndo TYPE "$d" 2>/dev/null | grep -q '^disk$'; then
      warn "Resolved $d is not present or not a disk; skipping"
      continue
    fi
    # dedupe
    if [[ -z "${seen[$d]:-}" ]]; then TARGETS+=("$d"); seen[$d]=1; fi
  done

  if [ ${#TARGETS[@]} -eq 0 ]; then
    err "No valid targets after resolution"
    exit 1
  fi
}

# ----------------------- Low-level helpers -----------------------
remove_dm_refs_for_base() {
  local base="$1"
  if ! command -v dmsetup &>/dev/null; then return; fi
  for dm in /sys/block/dm-*; do
    [ -e "$dm" ] || continue
    if ls "$dm/slaves" 2>/dev/null | grep -qx "$base"; then
      dmname=$(cat "$dm/dm/name" 2>/dev/null || true)
      if [ -n "$dmname" ]; then
        warn "Removing dm node /dev/mapper/$dmname (best-effort)"
        run_cmd "dmsetup remove -f \"/dev/mapper/$dmname\"" || true
      fi
    fi
  done
  run_cmd "dmsetup remove_all || true" || true
}

reload_disk_strong() {
  local dev="$1"; base=$(basename "$dev")
  run_cmd "partprobe \"$dev\" || true"
  run_cmd "blockdev --rereadpt \"$dev\" || true"
  if command -v kpartx &>/dev/null; then
    run_cmd "kpartx -d \"$dev\" || true"
    sleep 1
    run_cmd "kpartx -a \"$dev\" || true"
  fi
  if [ -w "/sys/block/$base/device/rescan" ]; then
    if [ "$DRYRUN" -eq 1 ]; then
      log "[DRYRUN] echo 1 > /sys/block/$base/device/rescan"
    else
      echo 1 > "/sys/block/$base/device/rescan" 2>/dev/null || true
    fi
  fi
  for host in /sys/class/scsi_host/host*; do
    if [ -w "$host/scan" ]; then
      if [ "$DRYRUN" -eq 1 ]; then
        log "[DRYRUN] printf ' - - -\\n' > $host/scan"
      else
        printf " - - -\n" > "$host/scan" 2>/dev/null || true
      fi
    fi
  done
  if command -v multipath &>/dev/null; then run_cmd "multipath -r || true"; fi
  if command -v udevadm &>/dev/null; then run_cmd "udevadm settle --timeout=5 || true"; fi
}

# ----------------------- LVM deep clean -----------------------
lvm_deep_clean_for_device() {
  local dev="$1"; local base=$(basename "$dev")
  if ! command -v pvs &>/dev/null; then
    warn "pvs not available; skipping LVM deep-clean"
    return
  fi

  mapfile -t pv_lines < <(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v b="$base" '$1 ~ b{print $1" "$2}' || true)
  if [ ${#pv_lines[@]} -eq 0 ]; then
    log "No LVM PVs referencing $dev"
    return
  fi

  for line in "${pv_lines[@]}"; do
    pv=$(echo "$line" | awk '{print $1}')
    vg=$(echo "$line" | awk '{print $2}')
    log "LVM: PV=$pv VG=$vg — deactivating & removing (best-effort)"
    if [ "$DRYRUN" -eq 1 ]; then
      log "[DRYRUN] vgchange -an $vg"
      log "[DRYRUN] lvremove -ff -y (all LVs in $vg)"
      log "[DRYRUN] vgremove -ff -y $vg"
      log "[DRYRUN] pvremove -ff -y $pv"
    else
      vgchange -an "$vg" 2>/dev/null || true
      mapfile -t lvlist < <(lvs --noheadings -o lv_path "$vg" 2>/dev/null | awk '{print $1}' || true)
      for lv in "${lvlist[@]}"; do
        [ -n "$lv" ] && run_cmd "lvremove -ff -y \"$lv\" || true"
      done
      run_cmd "vgremove -ff -y \"$vg\" || true"
      run_cmd "pvremove -ff -y \"$pv\" || true"
      ok "Removed VG $vg and PV $pv (best-effort)"
    fi
  done
}

# ----------------------- Ceph & ZFS attempts (default ON) -----------------------
ceph_zap_if_any() {
  local dev="$1"
  if command -v ceph-volume &>/dev/null; then
    if [ "$DRYRUN" -eq 1 ]; then
      log "[DRYRUN] ceph-volume lvm zap --destroy $dev"
    else
      log "Attempting ceph-volume lvm zap --destroy $dev (best-effort)"
      ceph-volume lvm zap --destroy "$dev" 2>/dev/null || warn "ceph-volume zap failed or not applicable"
    fi
  else
    warn "ceph-volume not found; skipping Ceph OSD zap (install ceph-volume to enable)"
  fi
}

zfs_labelclear_if_any() {
  local dev="$1"
  if command -v zpool &>/dev/null; then
    if [ "$DRYRUN" -eq 1 ]; then
      log "[DRYRUN] zpool labelclear -f $dev"
    else
      log "Attempting zpool labelclear -f $dev (best-effort)"
      zpool labelclear -f "$dev" 2>/dev/null || warn "zpool labelclear failed or not applicable"
    fi
  else
    warn "zpool not found; skipping ZFS labelclear"
  fi
}

# ----------------------- Process one disk -----------------------
process_disk() {
  local dev="$1"; local base=$(basename "$dev")
  log "=== Processing $dev ==="

  if ! lsblk -ndo TYPE "$dev" 2>/dev/null | grep -q '^disk$'; then
    warn "$dev is not present or not a disk; skipping"
    return
  fi

  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$dev" || true

  if [ "$MODE" = "manual" ] && [ "$YES_ALL" -eq 0 ]; then
    if [ "$TIMEOUT" -gt 0 ]; then
      read -t "$TIMEOUT" -rp "Wipe $dev ? (y/N): " _u || _u="n"
    else
      read -rp "Wipe $dev ? (y/N): " _u
    fi
    if [[ ! "$_u" =~ ^[Yy]$ ]]; then
      log "User skipped $dev"
      return
    fi
  fi

  # Unmount partitions (lazy then force)
  for part in $(lsblk -ln -o NAME "$dev" | awk 'NR>1{print $1}' || true); do
    p="/dev/$part"
    if mount | grep -q "$p"; then
      if [ "$DRYRUN" -eq 1 ]; then
        log "[DRYRUN] umount -l $p"
      else
        umount -l "$p" 2>/dev/null || umount -f "$p" 2>/dev/null || warn "Failed to unmount $p"
        ok "Unmounted $p"
      fi
    fi
  done

  # swapoff if any
  mapfile -t swap_parts < <(lsblk -nr -o NAME,TYPE "$dev" | awk '$2=="swap"{print "/dev/"$1}' || true)
  for s in "${swap_parts[@]}"; do
    if [ "$DRYRUN" -eq 1 ]; then
      log "[DRYRUN] swapoff $s"
    else
      swapoff "$s" 2>/dev/null || true
      ok "swapoff $s"
    fi
  done

  # LVM deep-clean
  lvm_deep_clean_for_device "$dev"

  # remove dm refs best-effort
  remove_dm_refs_for_base "$base"

  # Ceph & ZFS (default: attempt)
  ceph_zap_if_any "$dev"
  zfs_labelclear_if_any "$dev"

  # mdadm zero superblock on device and partitions
  if command -v mdadm &>/dev/null; then
    for t in "$dev" $(lsblk -ln -o NAME "$dev" | awk 'NR>1{print "/dev/"$1}' || true); do
      if [ "$DRYRUN" -eq 1 ]; then
        log "[DRYRUN] mdadm --zero-superblock --force $t"
      else
        mdadm --zero-superblock --force "$t" 2>/dev/null || true
      fi
    done
    ok "mdadm superblocks zeroed (best-effort)"
  fi

  # wipefs + sgdisk --zap-all
  if [ "$DRYRUN" -eq 1 ]; then
    log "[DRYRUN] wipefs -a $dev"
    log "[DRYRUN] sgdisk --zap-all $dev"
  else
    wipefs -a "$dev" 2>/dev/null || warn "wipefs reported non-zero for $dev"
    if command -v sgdisk &>/dev/null; then
      sgdisk --zap-all "$dev" 2>/dev/null || warn "sgdisk --zap-all failed"
    fi
    ok "wipefs/sgdisk executed on $dev"
  fi

  # attempt blkdiscard if available (fast) - do not fail if unsupported
  if command -v blkdiscard &>/dev/null; then
    if [ "$DRYRUN" -eq 1 ]; then
      log "[DRYRUN] blkdiscard $dev"
    else
      run_cmd "blkdiscard \"$dev\" || true"
      ok "blkdiscard attempted (if supported)"
    fi
  fi

  # residual dd head/tail (10MB)
  if command -v blockdev &>/dev/null; then
    sectors=$(blockdev --getsz "$dev" 2>/dev/null || echo 0)
    if [ "$sectors" -gt 20480 ]; then
      total_mb=$(( sectors / 2048 ))
      if [ "$DRYRUN" -eq 1 ]; then
        log "[DRYRUN] dd zero head/tail 10MB on $dev"
      else
        log "Zeroing 10MB head & tail on $dev"
        dd if=/dev/zero of="$dev" bs=1M count=10 conv=fsync status=none || warn "dd head failed"
        dd if=/dev/zero of="$dev" bs=1M count=10 seek=$(( total_mb - 10 )) conv=fsync status=none || warn "dd tail failed"
        ok "Head/tail zero completed (best-effort)"
      fi
    fi
  fi

  # aggressive reload
  reload_disk_strong "$dev"

  # final check
  sleep 1
  parts=$(lsblk -n -o NAME,TYPE "$dev" | awk '$2=="part"{print $1}' || true)
  pvleft=$(command -v pvs &>/dev/null && pvs --noheadings -o pv_name 2>/dev/null | grep -F "$(basename "$dev")" || true)
  if [[ -n "$parts" || -n "$pvleft" ]]; then
    warn "After cleanup, $dev still shows:"
    [ -n "$parts" ] && echo "  - partitions: $parts"
    [ -n "$pvleft" ] && echo "  - LVM PV: $pvleft"
    echo ""
    echo "Possible reasons:"
    echo "- A process/service still holds the device (use lsof to find it)."
    echo "- Multipath/device-mapper maps still exist; consider stopping multipathd and removing maps."
    echo "- Ceph may re-create OSD mappings; ensure cluster is stopped for this disk."
    echo "- As last resort: reboot to flush kernel."
  else
    ok "$dev appears clean (no partitions or PVs detected)."
  fi

  log "Finished $dev"
}

# ----------------------- MAIN FLOW -----------------------
check_tools
install_tools

resolve_targets

log "Final target list:"
for t in "${TARGETS[@]}"; do log " - $t"; done

if [ "$MODE" = "manual" ] && [ "$YES_ALL" -eq 0 ]; then
  if [ "$TIMEOUT" -gt 0 ]; then
    read -t "$TIMEOUT" -rp "Proceed processing ${#TARGETS[@]} disk(s)? (y/N): " proceed || proceed="n"
  else
    read -rp "Proceed processing ${#TARGETS[@]} disk(s)? (y/N): " proceed
  fi
  if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
    log "User cancelled. Exiting."
    exit 0
  fi
fi

for dev in "${TARGETS[@]}"; do
  process_disk "$dev"
done

ok "All requested targets processed. Run 'lsblk' to verify."
exit 0
