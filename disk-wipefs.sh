#!/usr/bin/env bash
# disk-wipefs v6.3
# Aggressive disk metadata cleaner (implements #disk_wipefs_checklist)
# Author: ChatGPT & TrungLun0112
# Repo: https://github.com/TrungLun0112/disk-wipefs
#
# WARNING: destructive. This script will attempt to remove ALL metadata on target disks.
# Always test with --dry-run first. Default skips /dev/sda unless --force specified.

set -euo pipefail
IFS=$'\n\t'

VERSION="v6.3"

# ----------------- Defaults / Globals -----------------
DRYRUN=0
MODE="manual"       # manual or auto
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

ESSENTIAL=(wipefs sgdisk partprobe blockdev lsblk dd)
RECOMMENDED=(mdadm lvm2 kpartx dmsetup multipath ceph-volume zpool blkdiscard udevadm)

# ----------------- Colors / logging -----------------
if [ "${NOCOLOR}" -eq 0 ]; then
  C_INFO="\033[1;34m"; C_OK="\033[1;32m"; C_WARN="\033[1;33m"; C_ERR="\033[1;31m"; C_RST="\033[0m"
else
  C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_RST=""
fi

_log() { [ "${QUIET}" -eq 0 ] && echo -e "$(date '+%F %T') ${C_INFO}[INFO]${C_RST} $*"; }
_ok() { [ "${QUIET}" -eq 0 ] && echo -e "$(date '+%F %T') ${C_OK}[OK]${C_RST} $*"; }
_warn() { [ "${QUIET}" -eq 0 ] && echo -e "$(date '+%F %T') ${C_WARN}[WARN]${C_RST} $*"; }
_err() { echo -e "$(date '+%F %T') ${C_ERR}[ERROR]${C_RST} $*" >&2; }

# Append to logfile if set
_logf() { _log "$*"; [ -n "${LOGFILE}" ] && echo "$(date '+%F %T') [INFO] $*" >> "${LOGFILE}"; }
_okf() { _ok "$*"; [ -n "${LOGFILE}" ] && echo "$(date '+%F %T') [OK] $*" >> "${LOGFILE}"; }
_warnf() { _warn "$*"; [ -n "${LOGFILE}" ] && echo "$(date '+%F %T') [WARN] $*" >> "${LOGFILE}"; }
_errf() { _err "$*"; [ -n "${LOGFILE}" ] && echo "$(date '+%F %T') [ERROR] $*" >> "${LOGFILE}"; }

# ----------------- Utilities -----------------
run_cmd() {
  # logs then runs command; respects DRYRUN
  if [ "${DRYRUN}" -eq 1 ]; then
    _logf "[DRYRUN] $*"
  else
    if [ "${VERBOSE}" -eq 1 ]; then _logf "RUN: $*"; fi
    eval "$@"
  fi
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    _errf "Please run as root (sudo)."
    exit 1
  fi
}

usage() {
  cat <<EOF
disk-wipefs $VERSION  - Aggressive disk metadata cleaner (LVM/mdadm/Ceph/ZFS/multipath)

Usage:
  sudo $0 [options] <targets...>

Targets:
  all                  - all detected disks (sd*, nvme*, vd*, mmcblk*). Default skips /dev/sda
  sdb nvme0n1          - explicit devices (omit /dev/ if you like)
  sd* nvme*            - shell-style patterns

Options:
  --auto               - automatic mode (no per-disk prompt)
  --manual             - manual mode (default)
  -y, --yes            - assume Yes to all prompts (implies --auto)
  --dry-run            - show actions only; no destructive commands executed
  --force              - allow wiping /dev/sda (dangerous)
  --exclude a,b        - comma-separated device names to exclude (e.g. sda,nvme0n1)
  --pattern p1,p2      - comma-separated shell patterns (e.g. sd*,nvme*)
  --no-install         - do not auto-install missing tools; fail if missing
  --include-dm         - include device-mapper (/dev/dm-*, /dev/mapper/*) as targets
  --log-file /path     - append logs to file
  --no-color           - disable colored output
  --quiet              - minimal output
  --timeout N          - prompt timeout seconds (0 = wait forever)
  -h|--help            - show this help

Examples:
  sudo $0 sdb
  sudo $0 all --auto
  sudo $0 sd* --dry-run
  sudo $0 nvme0n1 --yes --log-file /tmp/wipe.log
EOF
  exit 1
}

# ----------------- Parse args -----------------
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
_logf "disk-wipefs $VERSION starting"
_logf "Credits: ChatGPT & TrungLun0112 - https://github.com/TrungLun0112/disk-wipefs"

# detect OS
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  PRETTY="${PRETTY_NAME:-$OS_ID}"
  _logf "Detected OS: ${PRETTY}"
else
  OS_ID="unknown"
  _warnf "Cannot detect OS; continuing with conservative defaults"
fi

# ----------------- Tools check & optional install -----------------
MISSING=()
check_tools() {
  MISSING=()
  for t in "${ESSENTIAL[@]}"; do
    if ! command -v "$t" &>/dev/null; then
      MISSING+=("$t")
    fi
  done
  if [ ${#MISSING[@]} -gt 0 ]; then
    _warnf "Missing essential tools: ${MISSING[*]}"
    return 0
  fi
  _okf "All essential tools present"
  return 1
}

install_tools() {
  if [ ${#MISSING[@]} -eq 0 ]; then return; fi
  if [ "${NO_INSTALL}" -eq 1 ]; then
    _errf "Missing tools and --no-install set. Please install: ${MISSING[*]}"
    exit 1
  fi
  # Fix apt cdrom if needed
  if [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "debian" ]]; then
    if grep -Iq 'cdrom' /etc/apt/sources.list 2>/dev/null || ls /etc/apt/sources.list.d/* 2>/dev/null | xargs grep -Iq 'cdrom' 2>/dev/null; then
      _warnf "Found cdrom entries in apt sources; commenting them out to allow apt operations."
      sed -i.bak -E 's|(^deb .+cdrom)|#\1|' /etc/apt/sources.list 2>/dev/null || true
    fi
  fi

  _logf "Attempting to install missing tools: ${MISSING[*]} (best-effort)"
  case "${OS_ID}" in
    ubuntu|debian)
      run_cmd() { if [ "${DRYRUN}" -eq 1 ]; then _logf "[DRYRUN] $*"; else eval "$@"; fi; }
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
      _warnf "Auto-install not supported for OS=${OS_ID}. Please install: ${MISSING[*]}"
      exit 1
      ;;
  esac
  check_tools || _okf "Tools available now (or partially available)"
}

# ----------------- Resolve targets -----------------
resolve_targets() {
  local inputs=("${USER_INPUT[@]}")
  for p in "${PATTERN_LIST[@]:-}"; do inputs+=("$p"); done

  local cand=()
  if [ ${#inputs[@]} -eq 1 ] && [ "${inputs[0]}" == "all" ]; then
    mapfile -t devs < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
    cand=("${devs[@]}")
  else
    for tok in "${inputs[@]}"; do
      if [[ "$tok" == *"*"* ]]; then
        local regex="^${tok//\*/.*}$"
        mapfile -t matches < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print $1}' | grep -E "$regex" || true)
        for m in "${matches[@]}"; do cand+=("/dev/${m}"); done
      else
        if [[ "$tok" =~ ^/dev/ ]]; then cand+=("$tok"); else cand+=("/dev/$tok"); fi
      fi
    done
  fi

  declare -A seen
  TARGETS=()
  for d in "${cand[@]}"; do
    [ -z "$d" ] && continue
    base=$(basename "$d")
    skip=0
    for ex in "${EXCLUDE_LIST[@]:-}"; do
      if [[ "$ex" == "$base" || "$ex" == "$d" ]]; then skip=1; break; fi
    done
    [ $skip -eq 1 ] && { _logf "User exclude: skipping $d"; continue; }

    if [[ "$base" == "sda" && "${FORCE_SDA}" -eq 0 ]]; then
      _logf "Default skip /dev/sda (use --force to override)"; continue
    fi

    if [[ "$base" =~ ^sr ]] || [[ "$base" =~ ^loop ]] || [[ "$base" =~ ^ram ]]; then
      _logf "Skipping special device $d"; continue
    fi

    if { [[ "$base" =~ ^dm- ]] || [[ "$d" =~ /dev/mapper/ ]]; } && [ "${INCLUDE_DM}" -eq 0 ]; then
      _logf "Skipping device-mapper $d (use --include-dm to include)"; continue
    fi

    if ! lsblk -ndo TYPE "$d" 2>/dev/null | grep -q '^disk$'; then
      _warnf "Resolved $d is not present or not a disk; skipping"; continue
    fi

    if [[ -z "${seen[$d]:-}" ]]; then TARGETS+=("$d"); seen[$d]=1; fi
  done

  if [ ${#TARGETS[@]} -eq 0 ]; then
    _errf "No valid target disks found after resolution"
    exit 1
  fi
}

# ----------------- Low-level helpers -----------------
remove_dm_refs_for_base() {
  local base="$1"
  if ! command -v dmsetup &>/dev/null; then return; fi
  for dm in /sys/block/dm-*; do
    [ -e "$dm" ] || continue
    if ls "$dm/slaves" 2>/dev/null | grep -qx "$base"; then
      dmname=$(cat "$dm/dm/name" 2>/dev/null || true)
      if [ -n "$dmname" ]; then
        _warnf "Removing dm node /dev/mapper/$dmname (best-effort)"
        if [ "${DRYRUN}" -eq 1 ]; then _logf "[DRYRUN] dmsetup remove -f /dev/mapper/$dmname"; else dmsetup remove -f "/dev/mapper/$dmname" 2>/dev/null || true; fi
      fi
    fi
  done
  if [ "${DRYRUN}" -eq 1 ]; then _logf "[DRYRUN] dmsetup remove_all"; else dmsetup remove_all 2>/dev/null || true; fi
}

reload_disk_strong() {
  local dev="$1"
  local base
  base=$(basename "$dev")
  run_cmd() { if [ "${DRYRUN}" -eq 1 ]; then _logf "[DRYRUN] $*"; else eval "$@"; fi; }
  run_cmd "partprobe \"$dev\" || true"
  run_cmd "blockdev --rereadpt \"$dev\" || true"
  if command -v kpartx &>/dev/null; then run_cmd "kpartx -d \"$dev\" || true"; sleep 1; run_cmd "kpartx -a \"$dev\" || true"; fi
  if [ -w "/sys/block/$base/device/rescan" ]; then
    if [ "${DRYRUN}" -eq 1 ]; then _logf "[DRYRUN] echo 1 > /sys/block/$base/device/rescan"; else echo 1 > "/sys/block/$base/device/rescan" 2>/dev/null || true; fi
  fi
  for host in /sys/class/scsi_host/host*; do
    if [ -w "$host/scan" ]; then
      if [ "${DRYRUN}" -eq 1 ]; then _logf "[DRYRUN] printf ' - - -\\n' > $host/scan"; else printf " - - -\\n" > "$host/scan" 2>/dev/null || true; fi
    fi
  done
  if command -v multipath &>/dev/null; then run_cmd "multipath -r || true"; fi
  if command -v udevadm &>/dev/null; then run_cmd "udevadm settle --timeout=5 || true"; fi
}

# ----------------- LVM deep-clean -----------------
lvm_deep_clean_for_device() {
  local dev="$1"
  local base
  base=$(basename "$dev")
  if ! command -v pvs &>/dev/null; then
    _warnf "pvs not available; skipping LVM deep-clean"
    return
  fi
  mapfile -t pv_lines < <(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v b="$base" '$1 ~ b{print $1" "$2}' || true)
  if [ ${#pv_lines[@]} -eq 0 ]; then
    _logf "No LVM PVs referencing $dev"
    return
  fi
  for line in "${pv_lines[@]}"; do
    pv=$(echo "$line" | awk '{print $1}')
    vg=$(echo "$line" | awk '{print $2}')
    _logf "LVM: PV=$pv VG=$vg — deactivating & removing (best-effort)"
    if [ "${DRYRUN}" -eq 1 ]; then
      _logf "[DRYRUN] vgchange -an $vg; lvremove -ff -y (all); vgremove -ff -y $vg; pvremove -ff -y $pv"
    else
      vgchange -an "$vg" 2>/dev/null || true
      mapfile -t lvlist < <(lvs --noheadings -o lv_path "$vg" 2>/dev/null | awk '{print $1}' || true)
      for lv in "${lvlist[@]}"; do [ -n "$lv" ] && lvremove -ff -y "$lv" 2>/dev/null || true; done
      vgremove -ff -y "$vg" 2>/dev/null || true
      pvremove -ff -y "$pv" 2>/dev/null || true
      _okf "Removed VG $vg and PV $pv (best-effort)"
    fi
  done
}

# ----------------- Ceph & ZFS attempts (default ON) -----------------
ceph_zap_if_any() {
  local dev="$1"
  if command -v ceph-volume &>/dev/null; then
    if [ "${DRYRUN}" -eq 1 ]; then _logf "[DRYRUN] ceph-volume lvm zap --destroy $dev"; else ceph-volume lvm zap --destroy "$dev" 2>/dev/null || _warnf "ceph-volume zap failed/ignored"; fi
  else
    _warnf "ceph-volume not installed; skipping Ceph OSD zap"
  fi
}

zfs_labelclear_if_any() {
  local dev="$1"
  if command -v zpool &>/dev/null; then
    if [ "${DRYRUN}" -eq 1 ]; then _logf "[DRYRUN] zpool labelclear -f $dev"; else zpool labelclear -f "$dev" 2>/dev/null || _warnf "zpool labelclear failed/ignored"; fi
  else
    _warnf "zpool not installed; skipping ZFS labelclear"
  fi
}

# ----------------- Core per-disk process -----------------
process_disk() {
  local dev="$1"
  local base
  base=$(basename "$dev")
  _logf "=== Processing $dev ==="

  if ! lsblk -ndo TYPE "$dev" 2>/dev/null | grep -q '^disk$'; then
    _warnf "$dev not present or not a disk; skipping"; return
  fi

  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$dev" || true

  if [ "${MODE}" = "manual" ] && [ "${YES_ALL}" -eq 0 ]; then
    if [ "${TIMEOUT}" -gt 0 ]; then
      read -t "${TIMEOUT}" -rp "Wipe ${dev}? (y/N): " _ans || _ans="n"
    else
      read -rp "Wipe ${dev}? (y/N): " _ans
    fi
    if [[ ! "${_ans}" =~ ^[Yy]$ ]]; then _logf "User skipped ${dev}"; return; fi
  fi

  # Unmount partitions (lazy then force)
  mapfile -t parts < <(lsblk -ln -o NAME "$dev" | awk 'NR>1{print $1}' || true)
  for p in "${parts[@]:-}"; do
    pdev="/dev/${p}"
    if mount | grep -q "${pdev}"; then
      if [ "${DRYRUN}" -eq 1 ]; then _logf "[DRYRUN] umount -l ${pdev}"; else umount -l "${pdev}" 2>/dev/null || umount -f "${pdev}" 2>/dev/null || _warnf "Failed to unmount ${pdev}"; fi
      _logf "Unmount attempted: ${pdev}"
    fi
  done

  # swapoff if any
  mapfile -t swaps < <(lsblk -nr -o NAME,TYPE "$dev" | awk '$2=="swap"{print "/dev/"$1}' || true)
  for s in "${swaps[@]:-}"; do
    if [ "${DRYRUN}" -eq 1 ]; then _logf "[DRYRUN] swapoff ${s}"; else swapoff "${s}" 2>/dev/null || true; fi
    _logf "swapoff attempted: ${s}"
  done

  # LVM deep clean
  lvm_deep_clean_for_device "$dev"

  # remove dm refs
  remove_dm_refs_for_base "${base}"

  # Ceph & ZFS
  ceph_zap_if_any "$dev"
  zfs_labelclear_if_any "$dev"

  # mdadm zero superblock (device + partitions)
  if command -v mdadm &>/dev/null; then
    for t in "$dev" $(lsblk -ln -o NAME "$dev" | awk 'NR>1{print "/dev/"$1}' || true); do
      if [ "${DRYRUN}" -eq 1 ]; then _logf "[DRYRUN] mdadm --zero-superblock --force ${t}"; else mdadm --zero-superblock --force "${t}" 2>/dev/null || true; fi
    done
    _okf "mdadm superblocks zeroed (best-effort)"
  fi

  # wipefs + sgdisk
  if [ "${DRYRUN}" -eq 1 ]; then
    _logf "[DRYRUN] wipefs -a ${dev}"
    _logf "[DRYRUN] sgdisk --zap-all ${dev}"
  else
    wipefs -a "${dev}" 2>/dev/null || _warnf "wipefs returned non-zero for ${dev}"
    if command -v sgdisk &>/dev/null; then sgdisk --zap-all "${dev}" 2>/dev/null || _warnf "sgdisk --zap-all returned non-zero"; fi
    _okf "wipefs/sgdisk executed on ${dev}"
  fi

  # blkdiscard if available (fast)
  if command -v blkdiscard &>/dev/null; then
    if [ "${DRYRUN}" -eq 1 ]; then _logf "[DRYRUN] blkdiscard ${dev}"; else blkdiscard "${dev}" 2>/dev/null || _warnf "blkdiscard failed or not supported"; fi
  fi

  # dd head/tail 10MB
  if command -v blockdev &>/dev/null; then
    sectors=$(blockdev --getsz "${dev}" 2>/dev/null || echo 0)
    if [ "${sectors}" -gt 20480 ]; then
      total_mb=$(( sectors / 2048 ))
      if [ "${DRYRUN}" -eq 1 ]; then
        _logf "[DRYRUN] dd if=/dev/zero of=${dev} bs=1M count=10"
        _logf "[DRYRUN] dd if=/dev/zero of=${dev} bs=1M count=10 seek=$(( total_mb - 10 ))"
      else
        _logf "Zeroing 10MB head on ${dev}"
        dd if=/dev/zero of="${dev}" bs=1M count=10 conv=fsync status=none || _warnf "dd head failed"
        _logf "Zeroing 10MB tail on ${dev}"
        dd if=/dev/zero of="${dev}" bs=1M count=10 seek=$(( total_mb - 10 )) conv=fsync status=none || _warnf "dd tail failed"
        _okf "Head/tail zero completed on ${dev}"
      fi
    fi
  fi

  # aggressive reload
  reload_disk_strong "${dev}"

  # final check
  sleep 1
  parts_after=$(lsblk -n -o NAME,TYPE "${dev}" | awk '$2=="part"{print $1}' || true)
  pvleft=$(command -v pvs &>/dev/null && pvs --noheadings -o pv_name 2>/dev/null | grep -F "$(basename "${dev}")" || true)
  if [[ -n "${parts_after}" || -n "${pvleft}" ]]; then
    _warnf "After cleanup, ${dev} still shows:"
    [ -n "${parts_after}" ] && echo "  - partitions: ${parts_after}"
    [ -n "${pvleft}" ] && echo "  - LVM PV: ${pvleft}"
    echo ""
    echo "Possible causes and suggestions:"
    echo "- A process still holds the device (use: lsof /dev/NAME)."
    echo "- Multipath/device-mapper maps still active; stop multipathd and remove maps."
    echo "- Ceph may re-create OSD mappings; ensure cluster is stopped for this disk."
    echo "- Reboot as last resort."
  else
    _okf "${dev} appears clean (no partitions or PVs detected)."
  fi

  _logf "Finished processing ${dev}"
}

# ----------------- Main flow -----------------
check_tools
install_tools

resolve_targets

_logf "Final targets:"
for t in "${TARGETS[@]}"; do _logf " - ${t}"; done

if [ "${MODE}" = "manual" ] && [ "${YES_ALL}" -eq 0 ]; then
  if [ "${TIMEOUT}" -gt 0 ]; then
    read -t "${TIMEOUT}" -rp "Proceed processing ${#TARGETS[@]} disk(s)? (y/N): " proceed || proceed="n"
  else
    read -rp "Proceed processing ${#TARGETS[@]} disk(s)? (y/N): " proceed
  fi
  if [[ ! "${proceed}" =~ ^[Yy]$ ]]; then _logf "User cancelled."; exit 0; fi
fi

for dev in "${TARGETS[@]}"; do
  process_disk "${dev}"
done

_okf "All requested targets processed. Run 'lsblk' to verify."
exit 0
