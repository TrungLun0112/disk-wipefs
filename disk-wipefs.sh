#!/usr/bin/env bash
# disk-wipefs v6.5
# Aggressive disk metadata cleaner (implements #disk_wipefs_checklist)
# Authors: ChatGPT & TrungLun0112
# Repo: https://github.com/TrungLun0112/disk-wipefs
#
# WARNING: destructive. This will attempt to remove ANY metadata (LVM, mdadm, Ceph, ZFS,
# multipath, partition tables ...). Use --dry-run first and be careful with --all and --force.

set -euo pipefail
IFS=$'\n\t'

VERSION="v6.5"

# ------------------ Defaults ------------------
DRYRUN=0
MODE="manual"          # manual or auto
YES_ALL=0
FORCE_SDA=0
NO_INSTALL=0
INCLUDE_DM=0
QUIET=0
NOCOLOR=0
LOGFILE=""
TIMEOUT=0
EXCLUDE_LIST=()
PATTERN_LIST=()
USER_INPUT=()
TARGETS=()
OS_ID=""
VERBOSE=1

# Essential / recommended tools
ESSENTIAL=(wipefs sgdisk partprobe blockdev lsblk dd)
RECOMMENDED=(mdadm lvm2 kpartx dmsetup multipath ceph-volume zpool blkdiscard udevadm lsof)

# ------------------ Colors & logging ------------------
if [ "${NOCOLOR}" -eq 0 ]; then
  C_INFO="\033[1;34m"; C_OK="\033[1;32m"; C_WARN="\033[1;33m"; C_ERR="\033[1;31m"; C_RST="\033[0m"
else
  C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_RST=""
fi

_log()  { [ "${QUIET}" -eq 0 ] && echo -e "$(date '+%F %T') ${C_INFO}[INFO]${C_RST} $*"; [ -n "${LOGFILE}" ] && echo "$(date '+%F %T') [INFO] $*" >> "${LOGFILE}" 2>/dev/null || true; }
_ok()   { [ "${QUIET}" -eq 0 ] && echo -e "$(date '+%F %T') ${C_OK}[OK]${C_RST} $*";   [ -n "${LOGFILE}" ] && echo "$(date '+%F %T') [OK] $*" >> "${LOGFILE}" 2>/dev/null || true; }
_warn() { [ "${QUIET}" -eq 0 ] && echo -e "$(date '+%F %T') ${C_WARN}[WARN]${C_RST} $*"; [ -n "${LOGFILE}" ] && echo "$(date '+%F %T') [WARN] $*" >> "${LOGFILE}" 2>/dev/null || true; }
_err()  { echo -e "$(date '+%F %T') ${C_ERR}[ERROR]${C_RST} $*" >&2; [ -n "${LOGFILE}" ] && echo "$(date '+%F %T') [ERROR] $*" >> "${LOGFILE}" 2>/dev/null || true; }

# ------------------ Trap ------------------
trap ' _err "Interrupted by user"; exit 130 ' INT

# ------------------ Utilities ------------------
run_cmd() {
  if [ "${DRYRUN}" -eq 1 ]; then
    _log "[DRYRUN] $*"
  else
    if [ "${VERBOSE}" -eq 1 ]; then _log "RUN: $*"; fi
    eval "$@"
  fi
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    _err "This script must be run as root (sudo)."
    exit 1
  fi
}

usage() {
  cat <<EOF
disk-wipefs $VERSION - Aggressive disk metadata cleaner

USAGE:
  sudo $0 [options] <targets...>

Targets:
  all                 - all detected disks (sd*, nvme*, vd*, mmcblk*). Default skips /dev/sda
  sdb nvme0n1         - explicit devices (omit /dev/ if you like)
  sd* nvme*           - shell-style patterns

Options:
  --auto              - automatic mode (no per-disk prompt)
  --manual            - manual mode (default)
  -y, --yes           - assume Yes to all prompts (implies --auto)
  --dry-run           - show actions only; no destructive commands executed
  --force             - allow wiping /dev/sda (dangerous)
  --exclude a,b       - comma-separated devices to exclude (e.g. sda,nvme0n1)
  --pattern p1,p2     - comma-separated patterns (e.g. sd*,nvme*)
  --no-install        - do not auto-install missing tools; fail if missing
  --include-dm        - include device-mapper devices as targets
  --log-file /path    - append logs to file
  --no-color          - disable colored output
  --quiet             - minimal output
  --timeout N         - prompt timeout seconds (0 = wait)
  -h, --help          - show this help

Example:
  sudo $0 sdb --dry-run
  sudo $0 all --auto --exclude sda
EOF
  exit 1
}

# ------------------ Parse args ------------------
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

require_root
_log "disk-wipefs $VERSION starting"
_log "Credits: ChatGPT & TrungLun0112 - https://github.com/TrungLun0112/disk-wipefs"

# ------------------ Detect OS ------------------
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  PRETTY="${PRETTY_NAME:-$OS_ID}"
  _log "Detected OS: ${PRETTY}"
else
  OS_ID="unknown"
  _warn "Cannot detect OS reliably"
fi

# ------------------ Check & install tools ------------------
MISSING=()
check_tools() {
  MISSING=()
  for t in "${ESSENTIAL[@]}"; do
    if ! command -v "$t" &>/dev/null; then
      MISSING+=("$t")
    fi
  done
  if [ ${#MISSING[@]} -gt 0 ]; then
    _warn "Missing essential tools: ${MISSING[*]}"
    return 0
  fi
  _ok "All essential tools present"
  return 1
}

install_tools() {
  if [ ${#MISSING[@]} -eq 0 ]; then return; fi
  if [ "${NO_INSTALL}" -eq 1 ]; then
    _err "Missing tools: ${MISSING[*]} and --no-install set. Aborting."
    exit 1
  fi

  # fix apt cdrom entries if present
  if [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "debian" ]]; then
    if grep -Iq 'cdrom' /etc/apt/sources.list 2>/dev/null || ls /etc/apt/sources.list.d/* 2>/dev/null | xargs grep -Iq 'cdrom' 2>/dev/null; then
      _warn "Found cdrom entries in apt sources; commenting them out to allow apt operations."
      sed -i.bak -E 's|(^deb .+cdrom)|#\1|' /etc/apt/sources.list 2>/dev/null || true
    fi
  fi

  _log "Attempting to install missing tools (best-effort): ${MISSING[*]}"
  case "${OS_ID}" in
    ubuntu|debian)
      if [ "${DRYRUN}" -eq 1 ]; then
        _log "[DRYRUN] apt-get update -y"
        _log "[DRYRUN] DEBIAN_FRONTEND=noninteractive apt-get install -y gdisk kpartx lvm2 mdadm || true"
      else
        apt-get update -y || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y gdisk kpartx lvm2 mdadm || true
      fi
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
      _warn "Auto-install not supported for OS=${OS_ID}. Please install: ${MISSING[*]}"
      exit 1
      ;;
  esac

  check_tools || _ok "Tools available after install (or partially installed)"
}

# ------------------ Resolve targets ------------------
resolve_targets() {
  local inputs=("${USER_INPUT[@]}")
  for p in "${PATTERN_LIST[@]:-}"; do inputs+=("$p"); done

  local candidates=()
  if [ ${#inputs[@]} -eq 1 ] && [ "${inputs[0]}" == "all" ]; then
    mapfile -t devs < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
    candidates=("${devs[@]}")
  else
    for tok in "${inputs[@]}"; do
      if [[ "$tok" == *"*"* ]]; then
        local re="^${tok//\*/.*}$"
        mapfile -t matches < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print $1}' | grep -E "$re" || true)
        for m in "${matches[@]}"; do candidates+=("/dev/$m"); done
      else
        if [[ "$tok" =~ ^/dev/ ]]; then candidates+=("$tok"); else candidates+=("/dev/$tok"); fi
      fi
    done
  fi

  declare -A seen
  TARGETS=()
  for d in "${candidates[@]}"; do
    [ -z "$d" ] && continue
    base=$(basename "$d")
    skip=0
    for ex in "${EXCLUDE_LIST[@]:-}"; do
      if [[ "$ex" == "$base" || "$ex" == "$d" ]]; then skip=1; break; fi
    done
    [ $skip -eq 1 ] && { _log "User exclude: skipping $d"; continue; }

    # default skip sda
    if [[ "$base" == "sda" && "${FORCE_SDA}" -eq 0 ]]; then
      _log "Default skip /dev/sda (use --force to override)"
      continue
    fi

    # skip sr, loop, ram
    if [[ "$base" =~ ^sr ]] || [[ "$base" =~ ^loop ]] || [[ "$base" =~ ^ram ]]; then
      _log "Skipping special device: $d"
      continue
    fi

    # skip dm/mapper unless included
    if { [[ "$base" =~ ^dm- ]] || [[ "$d" =~ /dev/mapper/ ]]; } && [ "${INCLUDE_DM}" -eq 0 ]; then
      _log "Skipping device-mapper $d (use --include-dm to include)"
      continue
    fi

    # ensure disk
    if ! lsblk -ndo TYPE "$d" 2>/dev/null | grep -q '^disk$'; then
      _warn "Resolved $d is not present or not a disk; skipping"
      continue
    fi

    if [[ -z "${seen[$d]:-}" ]]; then TARGETS+=("$d"); seen[$d]=1; fi
  done

  if [ ${#TARGETS[@]} -eq 0 ]; then
    _err "No valid target disks found after resolution"
    exit 1
  fi
}

# ------------------ Helpers: device-mapper, reload, multipath ------------------
remove_dm_refs_for_base() {
  local base="$1"
  if ! command -v dmsetup &>/dev/null; then return; fi
  for dm in /sys/block/dm-*; do
    [ -e "$dm" ] || continue
    if ls "$dm/slaves" 2>/dev/null | grep -qx "$base"; then
      dmname=$(cat "$dm/dm/name" 2>/dev/null || true)
      if [ -n "$dmname" ]; then
        _warn "Removing dm node /dev/mapper/$dmname (best-effort)"
        if [ "${DRYRUN}" -eq 1 ]; then _log "[DRYRUN] dmsetup remove -f /dev/mapper/$dmname"; else dmsetup remove -f "/dev/mapper/$dmname" 2>/dev/null || true; fi
      fi
    fi
  done
  if [ "${DRYRUN}" -eq 1 ]; then _log "[DRYRUN] dmsetup remove_all"; else dmsetup remove_all 2>/dev/null || true; fi
}

reload_disk_strong() {
  local dev="$1"
  local base
  base=$(basename "$dev")
  run_cmd "partprobe \"$dev\" || true"
  run_cmd "blockdev --rereadpt \"$dev\" || true"
  if command -v kpartx &>/dev/null; then run_cmd "kpartx -d \"$dev\" || true"; sleep 1; run_cmd "kpartx -a \"$dev\" || true"; fi
  if [ -w "/sys/block/$base/device/rescan" ]; then
    if [ "${DRYRUN}" -eq 1 ]; then _log "[DRYRUN] echo 1 > /sys/block/$base/device/rescan"; else echo 1 > "/sys/block/$base/device/rescan" 2>/dev/null || true; fi
  fi
  for host in /sys/class/scsi_host/host*; do
    if [ -w "$host/scan" ]; then
      if [ "${DRYRUN}" -eq 1 ]; then _log "[DRYRUN] printf ' - - -\\n' > $host/scan"; else printf " - - -\\n" > "$host/scan" 2>/dev/null || true; fi
    fi
  done
  if command -v multipath &>/dev/null; then run_cmd "multipath -r || true"; fi
  if command -v udevadm &>/dev/null; then run_cmd "udevadm settle --timeout=5 || true"; fi
}

# ------------------ LVM deep cleaning ------------------
lvm_deep_clean_for_device() {
  local dev="$1"
  local base
  base=$(basename "$dev")
  if ! command -v pvs &>/dev/null; then
    _warn "pvs not available; skipping LVM deep-clean"
    return
  fi
  mapfile -t pv_lines < <(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v b="$base" '$1 ~ b{print $1" "$2}' || true)
  if [ ${#pv_lines[@]} -eq 0 ]; then
    _log "No LVM PVs referencing $dev"
    return
  fi
  for line in "${pv_lines[@]}"; do
    pv=$(echo "$line" | awk '{print $1}')
    vg=$(echo "$line" | awk '{print $2}')
    _log "LVM: PV=$pv VG=$vg — attempting deactivate & removal (best-effort)"
    if [ "${DRYRUN}" -eq 1 ]; then
      _log "[DRYRUN] vgchange -an $vg"
      _log "[DRYRUN] lvremove -ff -y (all LVs in $vg)"
      _log "[DRYRUN] vgremove -ff -y $vg"
      _log "[DRYRUN] pvremove -ff -y $pv"
    else
      vgchange -an "$vg" 2>/dev/null || true
      mapfile -t lvlist < <(lvs --noheadings -o lv_path "$vg" 2>/dev/null | awk '{print $1}' || true)
      for lv in "${lvlist[@]}"; do
        [ -n "$lv" ] && lvremove -ff -y "$lv" 2>/dev/null || true
      done
      vgremove -ff -y "$vg" 2>/dev/null || true
      pvremove -ff -y "$pv" 2>/dev/null || true
      _ok "Removed VG $vg and PV $pv (best-effort)"
    fi
  done
}

# ------------------ Ceph & ZFS attempts ------------------
ceph_zap_if_any() {
  local dev="$1"
  if command -v ceph-volume &>/dev/null; then
    if [ "${DRYRUN}" -eq 1 ]; then _log "[DRYRUN] ceph-volume lvm zap --destroy $dev"; else ceph-volume lvm zap --destroy "$dev" 2>/dev/null || _warn "ceph-volume zap failed/ignored"; fi
  else
    _warn "ceph-volume not installed; skipping Ceph zap"
  fi
}

zfs_labelclear_if_any() {
  local dev="$1"
  if command -v zpool &>/dev/null; then
    if [ "${DRYRUN}" -eq 1 ]; then _log "[DRYRUN] zpool labelclear -f $dev"; else zpool labelclear -f "$dev" 2>/dev/null || _warn "zpool labelclear failed/ignored"; fi
  else
    _warn "zpool not installed; skipping ZFS labelclear"
  fi
}

# ------------------ Per-disk processing ------------------
process_disk() {
  local dev="$1"
  local base
  base=$(basename "$dev")
  _log "=== Processing ${dev} ==="

  if ! lsblk -ndo TYPE "$dev" 2>/dev/null | grep -q '^disk$'; then
    _warn "${dev} not present or not a disk; skipping"
    return
  fi

  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$dev" || true

  if [ "${MODE}" = "manual" ] && [ "${YES_ALL}" -eq 0 ]; then
    if [ "${TIMEOUT}" -gt 0 ]; then
      read -t "${TIMEOUT}" -rp "Wipe ${dev}? (y/N): " _ans || _ans="n"
    else
      read -rp "Wipe ${dev}? (y/N): " _ans
    fi
    if [[ ! "${_ans}" =~ ^[Yy]$ ]]; then _log "User skipped ${dev}"; return; fi
  fi

  # 1) Unmount partitions (lazy then force)
  mapfile -t parts < <(lsblk -ln -o NAME "$dev" | awk 'NR>1{print $1}' || true)
  for p in "${parts[@]:-}"; do
    pdev="/dev/${p}"
    if mount | grep -q "${pdev}"; then
      if [ "${DRYRUN}" -eq 1 ]; then _log "[DRYRUN] umount -l ${pdev}"; else umount -l "${pdev}" 2>/dev/null || umount -f "${pdev}" 2>/dev/null || _warn "Failed to unmount ${pdev}"; fi
      _log "Unmount attempted: ${pdev}"
    fi
  done

  # 2) swapoff if partitions include swap
  mapfile -t swaps < <(lsblk -nr -o NAME,TYPE "$dev" | awk '$2=="swap"{print "/dev/"$1}' || true)
  for s in "${swaps[@]:-}"; do
    if [ "${DRYRUN}" -eq 1 ]; then _log "[DRYRUN] swapoff ${s}"; else swapoff "${s}" 2>/dev/null || true; fi
    _log "swapoff attempted: ${s}"
  done

  # 3) LVM deep-clean (best-effort)
  lvm_deep_clean_for_device "$dev"

  # 4) remove any device-mapper references
  remove_dm_refs_for_base "${base}"

  # 5) Ceph & ZFS attempts (best-effort)
  ceph_zap_if_any "$dev"
  zfs_labelclear_if_any "$dev"

  # 6) mdadm RAID superblock zero (device + partitions)
  if command -v mdadm &>/dev/null; then
    for t in "$dev" $(lsblk -ln -o NAME "$dev" | awk 'NR>1{print "/dev/"$1}' || true); do
      if [ "${DRYRUN}" -eq 1 ]; then _log "[DRYRUN] mdadm --zero-superblock --force ${t}"; else mdadm --zero-superblock --force "${t}" 2>/dev/null || true; fi
    done
    _ok "mdadm superblocks zeroed (best-effort)"
  fi

  # 7) wipefs + sgdisk
  if [ "${DRYRUN}" -eq 1 ]; then
    _log "[DRYRUN] wipefs -a ${dev}"
    _log "[DRYRUN] sgdisk --zap-all ${dev}"
  else
    wipefs -a "${dev}" 2>/dev/null || _warn "wipefs returned non-zero for ${dev}"
    if command -v sgdisk &>/dev/null; then sgdisk --zap-all "${dev}" 2>/dev/null || _warn "sgdisk --zap-all returned non-zero"; fi
    _ok "wipefs/sgdisk executed on ${dev}"
  fi

  # 8) blkdiscard (fast erase) if available
  if command -v blkdiscard &>/dev/null; then
    if [ "${DRYRUN}" -eq 1 ]; then _log "[DRYRUN] blkdiscard ${dev}"; else blkdiscard "${dev}" 2>/dev/null || _warn "blkdiscard failed or unsupported"; fi
  fi

  # 9) dd head/tail zero (10MB)
  if command -v blockdev &>/dev/null; then
    sectors=$(blockdev --getsz "${dev}" 2>/dev/null || echo 0)
    if [ "${sectors}" -gt 20480 ]; then
      total_mb=$(( sectors / 2048 ))
      if [ "${DRYRUN}" -eq 1 ]; then
        _log "[DRYRUN] dd if=/dev/zero of=${dev} bs=1M count=10"
        _log "[DRYRUN] dd if=/dev/zero of=${dev} bs=1M count=10 seek=$(( total_mb - 10 ))"
      else
        _log "Zeroing 10MB head on ${dev}"
        dd if=/dev/zero of="${dev}" bs=1M count=10 conv=fsync status=none || _warn "dd head failed"
        _log "Zeroing 10MB tail on ${dev}"
        dd if=/dev/zero of="${dev}" bs=1M count=10 seek=$(( total_mb - 10 )) conv=fsync status=none || _warn "dd tail failed"
        _ok "Head/tail zero completed on ${dev}"
      fi
    fi
  fi

  # 10) aggressive reload so kernel/udev sees changes
  reload_disk_strong "${dev}"

  # 11) final check & report
  sleep 1
  parts_after=$(lsblk -n -o NAME,TYPE "${dev}" | awk '$2=="part"{print $1}' || true)
  pvleft=$(command -v pvs &>/dev/null && pvs --noheadings -o pv_name 2>/dev/null | grep -F "$(basename "${dev}")" || true)
  if [[ -n "${parts_after}" || -n "${pvleft}" ]]; then
    _warn "After cleanup, ${dev} still shows:"
    [ -n "${parts_after}" ] && echo "  - partitions: ${parts_after}"
    [ -n "${pvleft}" ] && echo "  - LVM PV: ${pvleft}"
    echo ""
    echo "Possible causes & suggestions:"
    echo "- A process/service still holds the device (run: lsof /dev/<node>)"
    echo "- Multipath/device-mapper maps still active; stop multipathd and remove maps"
    echo "- Ceph may re-create OSD mappings; ensure cluster is stopped for this disk"
    echo "- Reboot as a last resort to clear kernel mappings"
  else
    _ok "${dev} appears clean (no partitions or PVs detected)"
  fi

  _log "Finished processing ${dev}"
}

# --------------- Main flow ---------------
check_tools
install_tools

resolve_targets

_log "Targets to process:"
for t in "${TARGETS[@]}"; do _log " - ${t}"; done

if [ "${MODE}" = "manual" ] && [ "${YES_ALL}" -eq 0 ]; then
  if [ "${TIMEOUT}" -gt 0 ]; then
    read -t "${TIMEOUT}" -rp "Proceed processing ${#TARGETS[@]} disk(s)? (y/N): " proceed || proceed="n"
  else
    read -rp "Proceed processing ${#TARGETS[@]} disk(s)? (y/N): " proceed
  fi
  if [[ ! "${proceed}" =~ ^[Yy]$ ]]; then _log "User cancelled."; exit 0; fi
fi

for dev in "${TARGETS[@]}"; do
  process_disk "${dev}"
done

_ok "All requested targets processed. Run 'lsblk' to verify."
exit 0
