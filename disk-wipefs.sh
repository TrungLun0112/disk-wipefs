#!/usr/bin/env bash
#
# disk-wipefs v2.5
# Aggressive disk metadata cleaner (LVM / mdadm / Ceph / ZFS / multipath)
# Author: ChatGPT & TrungLun0112
# Repo: https://github.com/TrungLun0112/disk-wipefs
#
# WARNING: destructive. Use --dry-run to preview. Default skips /dev/sda.
#

set -o errexit
set -o nounset
set -o pipefail

# ---------------- Defaults / Globals ----------------
VERSION="v2.5"
DRYRUN=0
MODE="manual"        # manual or auto
FORCE_SDA=0
NO_INSTALL=0
INCLUDE_DM=0
LOGFILE=""           # empty => stdout only
VERBOSE=1
QUIET=0
NOCOLOR=0
YES_ALL=0
TIMEOUT=0            # seconds for prompt timeout (0 = no timeout)
EXCLUDE_LIST=()
PATTERN_LIST=()
USER_TARGETS=()

# Essential tools minimal
ESSENTIAL=(wipefs sgdisk partprobe blockdev lsblk)
# Recommended for deep-clean
RECOMMENDED=(mdadm lvm2 kpartx dmsetup multipath ceph-volume zpool)

# ---------------- Colors ----------------
if [ "$NOCOLOR" -eq 0 ]; then
  C_INFO="\033[1;34m"  # blue
  C_OK="\033[1;32m"    # green
  C_WARN="\033[1;33m"  # yellow
  C_ERR="\033[1;31m"   # red
  C_RST="\033[0m"
else
  C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_RST=""
fi

log_to() {
  local line="$*"
  if [ -n "$LOGFILE" ]; then
    echo -e "$line" >> "$LOGFILE"
  else
    echo -e "$line"
  fi
}
log_info(){ [ $QUIET -eq 0 ] && log_to "$(date '+%F %T') ${C_INFO}[INFO]${C_RST} $*"; }
log_ok(){ [ $QUIET -eq 0 ] && log_to "$(date '+%F %T') ${C_OK}[OK]${C_RST} $*"; }
log_warn(){ [ $QUIET -eq 0 ] && log_to "$(date '+%F %T') ${C_WARN}[WARN]${C_RST} $*"; }
log_err(){ log_to "$(date '+%F %T') ${C_ERR}[ERROR]${C_RST} $*" >&2; }

# ---------------- Usage ----------------
usage(){
  cat <<EOF
disk-wipefs $VERSION  - Aggressive disk wipe (LVM/mdadm/Ceph/ZFS/multipath)

Usage:
  sudo $0 [options] <targets...>

Targets:
  all                  - all detected disks (sd*, nvme*, vd*, mmcblk*) except sda by default
  sdb nvme0n1          - explicit devices (omit /dev/ if you like)
  sd* nvme*            - shell-style patterns (supports *)

Options:
  --auto               - automatic mode (no per-disk prompt)
  --manual             - manual mode (default)
  --yes, -y            - assume Yes to all prompts (implies --auto)
  --dry-run            - show actions only; do not execute destructive commands
  --force-sda          - allow wiping /dev/sda (dangerous)
  --exclude a,b,c      - comma-separated list of device names to exclude (e.g. sda,nvme0n1)
  --pattern pat1,pat2  - comma-separated patterns (e.g. sd*,nvme*)
  --no-install         - do not auto-install missing tools; fail if missing
  --include-dm         - include device-mapper (/dev/dm-*, /dev/mapper/*) as targets
  --log-file /path     - write verbose log to file
  --no-color           - disable colored output
  --quiet              - minimal output
  --verbose            - extra verbose output
  --timeout N          - prompt timeout seconds (0 = no timeout)

Examples:
  sudo $0 sdb
  sudo $0 all --exclude sda --auto
  sudo $0 sd* --dry-run
  sudo $0 nvme0n1 --yes --log-file /tmp/wipe.log

EOF
  exit 1
}

# ---------------- Parse args ----------------
if [ $# -eq 0 ]; then usage; fi

while (( "$#" )); do
  case "$1" in
    --auto) MODE="auto"; shift ;;
    --manual) MODE="manual"; shift ;;
    -y|--yes) YES_ALL=1; MODE="auto"; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    --force-sda) FORCE_SDA=1; shift ;;
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
    *) USER_TARGETS+=("$1"); shift ;;
  esac
done

# ---------------- root check ----------------
if [ "$EUID" -ne 0 ]; then
  log_err "This script must be run as root (sudo)."
  exit 1
fi

log_info "disk-wipefs $VERSION starting. Repo: https://github.com/TrungLun0112/disk-wipefs"
log_info "Author credit: ChatGPT & TrungLun0112"

# ---------------- OS detect ----------------
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  log_info "Detected OS: ${PRETTY_NAME:-$OS_ID}"
else
  OS_ID="unknown"
  log_warn "Cannot detect OS; continuing with conservative defaults."
fi

# ---------------- helper: run or simulate ----------------
run_cmd() {
  if [ $DRYRUN -eq 1 ]; then
    log_info "[DRYRUN] $*"
  else
    if [ $VERBOSE -eq 1 ]; then
      log_info "RUN: $*"
    fi
    eval "$@"
  fi
}

# ---------------- check & install minimal tools if needed ----------------
MISSING=()
check_tools(){
  MISSING=()
  for t in "${ESSENTIAL[@]}"; do
    if ! command -v "$t" &>/dev/null; then
      MISSING+=("$t")
    fi
  done
  if [ ${#MISSING[@]} -gt 0 ]; then
    log_warn "Missing essential tools: ${MISSING[*]}"
    return 0
  else
    log_info "All essential tools present."
    return 1
  fi
}

install_tools_if_needed(){
  if check_tools; then
    if [ $NO_INSTALL -eq 1 ]; then
      log_err "Missing tools and --no-install set. Install: ${MISSING[*]} and re-run."
      exit 1
    fi
    log_info "Attempting to auto-install missing tools: ${MISSING[*]}"
    # fix cdrom entries only when installing on Debian/Ubuntu
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
      if grep -qE '(^deb .+cdrom|file:/cdrom)' /etc/apt/sources.list 2>/dev/null || ls /etc/apt/sources.list.d/* 2>/dev/null | xargs grep -Iq 'cdrom' 2>/dev/null; then
        log_warn "Found cdrom in apt sources; commenting out to allow apt operations."
        sed -i.bak -E 's|(^deb .+cdrom)|#\1|' /etc/apt/sources.list 2>/dev/null || true
        sed -i.bak -E 's|(^deb .+file:/cdrom)|#\1|' /etc/apt/sources.list 2>/dev/null || true
        log_info "cdrom entries commented (backup: /etc/apt/sources.list.bak)"
      fi
    fi

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
        log_warn "Unknown OS for auto-install. Please install manually: ${MISSING[*]}"
        exit 1
        ;;
    esac

    check_tools || log_info "Tools available after install (or partially installed)."
  fi
}

# ---------------- resolve targets ----------------
resolve_targets(){
  local inputs=("${USER_TARGETS[@]}")
  # merge pattern_list into inputs
  if [ ${#PATTERN_LIST[@]} -gt 0 ]; then
    for p in "${PATTERN_LIST[@]}"; do inputs+=("$p";); done
  fi

  local candidates=()
  if [ "${#inputs[@]}" -eq 1 ] && [ "${inputs[0]}" == "all" ]; then
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

  # filter by excludes, default skips
  declare -A seen
  TARGETS=()
  for d in "${candidates[@]}"; do
    [ -z "$d" ] && continue
    base=$(basename "$d")
    skip=0
    for ex in "${EXCLUDE_LIST[@]}"; do
      if [[ "$ex" == "$base" || "$ex" == "$d" ]]; then skip=1; break; fi
    done
    [ $skip -eq 1 ] && { log_info "User exclude: skipping $d"; continue; }

    # default skip sda
    if [[ "$base" == "sda" && "$FORCE_SDA" -eq 0 ]]; then
      log_info "Default skip: /dev/sda (use --force-sda to override)"
      continue
    fi
    # skip sr, loop, ram
    if [[ "$base" =~ ^sr ]] || [[ "$base" =~ ^loop ]] || [[ "$base" =~ ^ram ]]; then
      log_info "Skipping special device: $d"; continue
    fi
    # skip device-mapper unless included
    if [[ "$base" =~ ^dm- || "$d" =~ /dev/mapper/ ]]; then
      if [ "$INCLUDE_DM" -eq 1 ]; then
        log_info "Including device-mapper: $d"
      else
        log_info "Skipping device-mapper $d (use --include-dm to include)"; continue
      fi
    fi
    # ensure it's disk
    if ! lsblk -ndo TYPE "$d" 2>/dev/null | grep -q "^disk$"; then
      log_warn "Resolved $d is not present or not a disk; skipping"
      continue
    fi
    # de-dup
    if [[ -z "${seen[$d]:-}" ]]; then TARGETS+=("$d"); seen[$d]=1; fi
  done

  if [ ${#TARGETS[@]} -eq 0 ]; then
    err "No valid target disks found."
    exit 1
  fi
}

# ---------------- helpers: remove dm refs, reload, multipath ----------------
remove_dm_refs_for_base(){
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
  run_cmd "dmsetup remove_all" || true
}

reload_disk_strong(){
  local dev="$1"; local base=$(basename "$dev")
  run_cmd "partprobe \"$dev\" || true"
  run_cmd "blockdev --rereadpt \"$dev\" || true"
  if command -v kpartx &>/dev/null; then
    run_cmd "kpartx -d \"$dev\" || true"
    sleep 1
    run_cmd "kpartx -a \"$dev\" || true"
  fi
  if [ -w "/sys/block/$base/device/rescan" ]; then
    log_info "Per-device SCSI rescan for $dev"
    if [ $DRYRUN -eq 1 ]; then log_info "[DRYRUN] echo 1 > /sys/block/$base/device/rescan"; else echo 1 > "/sys/block/$base/device/rescan" 2>/dev/null || true; fi
  fi
  for host in /sys/class/scsi_host/host*; do
    if [ -w "$host/scan" ]; then
      if [ $DRYRUN -eq 1 ]; then log_info "[DRYRUN] printf ' - - -\\n' > $host/scan"; else printf " - - -\n" > "$host/scan" 2>/dev/null || true; fi
    fi
  done
  if command -v multipath &>/dev/null; then run_cmd "multipath -r || true"; fi
  if command -v udevadm &>/dev/null; then run_cmd "udevadm settle --timeout=5 || true"; fi
}

# ---------------- LVM deep-clean for device ----------------
lvm_deep_clean_for_device(){
  local dev="$1"; local base=$(basename "$dev")
  if ! command -v pvs &>/dev/null; then
    log_warn "pvs not found; skipping LVM deep-clean"
    return
  fi

  mapfile -t lines < <(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v b="$base" '$1 ~ b{print $1" "$2}' || true)
  if [ ${#lines[@]} -eq 0 ]; then
    log_info "No LVM PVs referencing $dev"
    return
  fi

  for line in "${lines[@]}"; do
    pv=$(echo "$line" | awk '{print $1}')
    vg=$(echo "$line" | awk '{print $2}')
    log_info "LVM detected: PV=$pv VG=$vg -> attempting lv/vg/pv removal"
    if [ $DRYRUN -eq 1 ]; then
      log_info "[DRYRUN] vgchange -an $vg; lvremove -ff -y (all LVs); vgremove -ff -y $vg; pvremove -ff -y $pv"
    else
      vgchange -an "$vg" 2>/dev/null || true
      mapfile -t lvs_arr < <(lvs --noheadings -o lv_path "$vg" 2>/dev/null | awk '{print $1}' || true)
      for lv in "${lvs_arr[@]}"; do
        [ -n "$lv" ] && run_cmd "lvremove -ff -y \"$lv\" || true"
      done
      run_cmd "vgremove -ff -y \"$vg\" || true"
      run_cmd "pvremove -ff -y \"$pv\" || true"
      ok "Removed VG $vg and PV $pv (best-effort)"
    fi
  done
}

# ---------------- Ceph / ZFS attempts (default ON) ----------------
ceph_zap_if_any(){
  local dev="$1"
  if command -v ceph-volume &>/dev/null; then
    if [ $DRYRUN -eq 1 ]; then
      log_info "[DRYRUN] ceph-volume lvm zap --destroy $dev"
    else
      log_info "Attempting ceph-volume lvm zap --destroy $dev (if Ceph metadata present)"
      ceph-volume lvm zap --destroy "$dev" 2>/dev/null || warn "ceph-volume zap failed or not required"
    fi
  else
    log_warn "ceph-volume not present; skipping Ceph zap (if needed, install ceph-volume)"
  fi
}

zfs_labelclear_if_any(){
  local dev="$1"
  if command -v zpool &>/dev/null; then
    if [ $DRYRUN -eq 1 ]; then
      log_info "[DRYRUN] zpool labelclear -f $dev"
    else
      log_info "Attempting zpool labelclear -f $dev (if ZFS label present)"
      zpool labelclear -f "$dev" 2>/dev/null || warn "zpool labelclear failed or not required"
    fi
  else
    log_warn "zpool not present; skipping ZFS labelclear"
  fi
}

# ---------------- Process single disk ----------------
process_disk(){
  local dev="$1"; local base=$(basename "$dev")
  log_info "=== Processing $dev ==="

  # sanity
  if ! lsblk -ndo TYPE "$dev" 2>/dev/null | grep -q '^disk$'; then
    log_warn "$dev not present or not a disk; skipping"
    return
  fi

  # show lsblk
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$dev" || true

  # confirm if manual
  if [ "$MODE" == "manual" ] && [ $YES_ALL -eq 0 ]; then
    if [ $TIMEOUT -gt 0 ]; then
      read -t "$TIMEOUT" -rp "Wipe $dev ? (y/N): " ans || ans="n"
    else
      read -rp "Wipe $dev ? (y/N): " ans
    fi
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then log_info "Skipping $dev (user choice)"; return; fi
  fi

  # unmount partitions (lazy then force)
  for p in $(lsblk -ln -o NAME "$dev" | awk 'NR>1{print $1}' || true); do
    part="/dev/$p"
    if mount | grep -q "$part"; then
      if [ $DRYRUN -eq 1 ]; then log_info "[DRYRUN] umount -l $part"; else umount -l "$part" 2>/dev/null || umount -f "$part" 2>/dev/null || warn "Failed to unmount $part"; fi
      log_info "Unmounted $part (or attempted)"
    fi
  done

  # swapoff on disk
  mapfile -t swaps < <(lsblk -nr -o NAME,TYPE "$dev" | awk '$2=="swap"{print "/dev/"$1}' || true)
  for s in "${swaps[@]}"; do
    if [ $DRYRUN -eq 1 ]; then log_info "[DRYRUN] swapoff $s"; else swapoff "$s" 2>/dev/null || true; fi
  done

  # LVM deep-clean
  lvm_deep_clean_for_device "$dev"

  # remove dm refs best-effort
  remove_dm_refs_for_base "$(basename "$dev")"

  # Ceph / ZFS cleanup attempts (default)
  ceph_zap_if_any "$dev"
  zfs_labelclear_if_any "$dev"

  # mdadm zero superblocks (device + partitions)
  if command -v mdadm &>/dev/null; then
    for t in "$dev" $(lsblk -ln -o NAME "$dev" | awk 'NR>1{print "/dev/"$1}' || true); do
      if [ $DRYRUN -eq 1 ]; then log_info "[DRYRUN] mdadm --zero-superblock --force $t"; else mdadm --zero-superblock --force "$t" 2>/dev/null || true; fi
    done
  fi

  # wipefs + sgdisk
  if [ $DRYRUN -eq 1 ]; then
    log_info "[DRYRUN] wipefs -a $dev"
    log_info "[DRYRUN] sgdisk --zap-all $dev"
  else
    wipefs -a "$dev" 2>/dev/null || warn "wipefs returned non-zero for $dev"
    if command -v sgdisk &>/dev/null; then sgdisk --zap-all "$dev" 2>/dev/null || warn "sgdisk failed on $dev"; fi
    log_info "wipefs/sgdisk executed on $dev"
  fi

  # residual dd head/tail
  if command -v blockdev &>/dev/null; then
    sectors=$(blockdev --getsz "$dev" 2>/dev/null || echo 0)
    if [ "$sectors" -gt 20480 ]; then
      total_mb=$(( sectors / 2048 ))
      if [ $DRYRUN -eq 1 ]; then
        log_info "[DRYRUN] dd zero head/tail 10MB on $dev"
      else
        log_info "Zeroing 10MB head & tail on $dev"
        dd if=/dev/zero of="$dev" bs=1M count=10 conv=fsync status=none || warn "dd head failed"
        dd if=/dev/zero of="$dev" bs=1M count=10 seek=$(( total_mb - 10 )) conv=fsync status=none || warn "dd tail failed"
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
    log_warn "After cleanup, $dev still shows:"
    [ -n "$parts" ] && echo "  - partitions: $parts"
    [ -n "$pvleft" ] && echo "  - LVM PV: $pvleft"
    echo
    echo "Possible reasons:"
    echo "- A process/service still holds the device (use lsof to find it)."
    echo "- Multipath/device-mapper maps still exist; consider stopping multipathd and removing maps."
    echo "- Ceph may re-create OSD mappings; ensure cluster is stopped for this disk."
    echo "- As last resort: reboot to flush kernel."
  else
    log_ok "$dev appears clean."
  fi

  log_info "Finished processing $dev"
}

# ---------------- main flow ----------------
check_tools
install_tools_if_needed
resolve_targets

log_info "Targets to process:"
for t in "${TARGETS[@]}"; do log_info " - $t"; done

if [ "$MODE" == "manual" ] && [ $YES_ALL -eq 0 ]; then
  read -rp "Proceed with processing ${#TARGETS[@]} disk(s)? (y/N): " proceed
  if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
    log_info "User cancelled."
    exit 0
  fi
fi

for dev in "${TARGETS[@]}"; do
  process_disk "$dev"
done

log_ok "All requested targets processed."

