#!/usr/bin/env bash
#
# disk-wipefs v2.4
# Author: ChatGPT & TrungLun0112
# Repo: https://github.com/TrungLun0112/disk-wipefs
#
# PURPOSE: Aggressive but careful disk metadata cleanup for Linux servers.
# - Detect OS; install missing tools only if needed (and if allowed)
# - Auto-unmount partitions (except when user declines)
# - Deep-clean LVM (lvremove/vgremove/pvremove), mdadm, Ceph OSD, ZFS labels
# - Residual zero (head/tail), sgdisk zap, wipefs -a
# - Aggressive reload: partprobe, blockdev, kpartx, udevadm, SCSI rescan, multipath refresh
# - Options: --auto / --manual, --dry-run, --force (allow sda), --exclude, --include-dm,
#            --zap-ceph, --zap-zfs, --no-install
#
# VERY DESTRUCTIVE — use with extreme care.
set -euo pipefail

# ---------------- Colors / logging ----------------
RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; BLUE="\033[1;34m"; NC="\033[0m"
log()    { echo -e "$(date '+%F %T') ${BLUE}[INFO]${NC} $*"; }
ok()     { echo -e "$(date '+%F %T') ${GREEN}[OK]${NC} $*"; }
warn()   { echo -e "$(date '+%F %T') ${YELLOW}[WARN]${NC} $*"; }
err()    { echo -e "$(date '+%F %T') ${RED}[ERROR]${NC} $*" >&2; }

trap 'echo -e "\n'"${RED}"'[ABORT] Script interrupted by user (Ctrl+C). Exiting.'"${NC}"'; exit 130' INT

# ---------------- Defaults / globals ----------------
MODE="ask"            # ask/manual or auto
DRYRUN=0
FORCE=0
NO_INSTALL=0
INCLUDE_DM=0
ZAP_CEPH=0
ZAP_ZFS=0
EXCLUDE=()
USER_INPUT=()
TARGETS=()
OS_ID=""
MISSING_TOOLS=()

# Essential tools we will check for (minimal)
ESSENTIAL=(wipefs sgdisk partprobe blockdev lsblk)

# Tools recommended for deeper cleanup
RECOMMENDED=(mdadm lvm pvremove vgremove lvremove pvs lvs vgchange kpartx dd udevadm multipath dmsetup ceph-volume zpool)

# ---------------- Helpers ----------------
usage() {
  cat <<EOF
disk-wipefs v2.4 - aggressive disk metadata cleaner

Usage:
  sudo ./disk-wipefs-v2.4.sh [options] <targets...>

Targets:
  all                      - all detected disks (sd*, nvme*, vd*, mmcblk*)
  sdb nvme0n1              - explicit devices (omit /dev/ if you like)
  sd* nvme*                - patterns supported

Options:
  --auto                   - run without prompting each disk
  --manual                 - prompt for each disk (default)
  --dry-run                - show actions without executing destructive commands
  --force                  - allow wiping /dev/sda (VERY DANGEROUS)
  --exclude NAME[,NAME...] - exclude device names (e.g. sda,nvme0n1)
  --include-dm             - include /dev/dm-* and /dev/mapper/* (dangerous)
  --zap-ceph               - attempt ceph-volume lvm zap --destroy when Ceph metadata detected
  --zap-zfs                - attempt zpool labelclear -f when ZFS label detected
  --no-install             - do NOT auto-install missing tools; fail if missing
  -h | --help              - show this help

Examples:
  sudo ./disk-wipefs-v2.4.sh all --exclude sda --auto
  sudo ./disk-wipefs-v2.4.sh sdb nvme0n1 --dry-run
EOF
  exit 1
}

# require root
if [[ $EUID -ne 0 ]]; then
  err "This script must be run as root."
  exit 1
fi

# ---------------- Parse CLI ----------------
while (( "$#" )); do
  case "$1" in
    --auto) MODE="auto"; shift ;;
    --manual) MODE="ask"; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --no-install) NO_INSTALL=1; shift ;;
    --include-dm) INCLUDE_DM=1; shift ;;
    --zap-ceph) ZAP_CEPH=1; shift ;;
    --zap-zfs) ZAP_ZFS=1; shift ;;
    --exclude) shift; IFS=',' read -r -a EXCLUDE <<< "$1"; shift ;;
    -h|--help) usage ;;
    *) USER_INPUT+=("$1"); shift ;;
  esac
done

if [ ${#USER_INPUT[@]} -eq 0 ]; then
  err "No targets specified."
  usage
fi

# ---------------- OS detection ----------------
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  log "Detected OS: ${PRETTY_NAME:-$OS_ID}"
else
  OS_ID="unknown"
  warn "Could not detect OS (no /etc/os-release)."
fi

# ---------------- Fix cdrom repo (Debian/Ubuntu) ----------------
fix_cdrom_repo_if_needed() {
  if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
    if grep -qE '(^deb .+cdrom|file:/cdrom)' /etc/apt/sources.list 2>/dev/null || grep -qE 'cdrom' /etc/apt/sources.list.d/* 2>/dev/null; then
      warn "Found cdrom entries in apt sources; commenting them out to allow apt operations."
      sed -i.bak -E 's|(^deb .+cdrom)|#\1|' /etc/apt/sources.list 2>/dev/null || true
      sed -i.bak -E 's|(^deb .+file:/cdrom)|#\1|' /etc/apt/sources.list 2>/dev/null || true
      ok "cdrom entries commented (backup: /etc/apt/sources.list.bak)."
    fi
  fi
}

# ---------------- Check missing tools ----------------
check_tools() {
  MISSING_TOOLS=()
  for t in "${ESSENTIAL[@]}"; do
    if ! command -v "$t" &>/dev/null; then
      MISSING_TOOLS+=("$t")
    fi
  done
  # note recommended are optional, but we warn if absent when needed later
  if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    warn "Missing essential tools: ${MISSING_TOOLS[*]}"
    return 0
  else
    ok "All essential tools present."
    return 1
  fi
}

# ---------------- Install missing tools if allowed ----------------
install_missing_tools() {
  if [ ${#MISSING_TOOLS[@]} -eq 0 ]; then return; fi
  if [ "$NO_INSTALL" -eq 1 ]; then
    err "Missing tools: ${MISSING_TOOLS[*]} and --no-install set. Please install them and re-run."
    exit 1
  fi
  fix_cdrom_repo_if_needed
  log "Attempting to install missing tools: ${MISSING_TOOLS[*]}"
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
      err "Unsupported OS for auto-install. Please install: ${MISSING_TOOLS[*]}"
      exit 1
      ;;
  esac

  # re-check
  check_tools || ok "Missing tools installed (or available now)."
}

# ---------------- Resolve user-specified targets -> TARGETS array ----------------
resolve_targets() {
  local inputs=("$@")
  local candidates=()
  if [[ "${inputs[0]}" == "all" ]]; then
    mapfile -t candidates < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
  else
    for tok in "${inputs[@]}"; do
      if [[ "$tok" == *"*"* ]]; then
        # pattern -> regex:
        local re="^${tok//\*/.*}$"
        mapfile -t matches < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print $1}' | grep -E "$re" || true)
        for m in "${matches[@]}"; do candidates+=("/dev/$m"); done
      else
        if [[ "$tok" =~ ^/dev/ ]]; then candidates+=("$tok"); else candidates+=("/dev/$tok"); fi
      fi
    done
  fi

  # apply excludes & default skips
  local filtered=()
  for d in "${candidates[@]}"; do
    [ -z "$d" ] && continue
    base=$(basename "$d")
    # skip user excludes
    skip=0
    for ex in "${EXCLUDE[@]}"; do
      if [[ "$ex" == "$base" || "$ex" == "$d" ]]; then skip=1; break; fi
    done
    [ $skip -eq 1 ] && { log "User exclude: $d"; continue; }

    # skip system disk sda (unless --force)
    if [[ "$base" == "sda" && "$FORCE" -ne 1 ]]; then log "Default skip /dev/sda (use --force to override)"; continue; fi

    # skip sr, loop, ram
    if [[ "$base" =~ ^sr ]] || [[ "$base" =~ ^loop ]] || [[ "$base" =~ ^ram ]]; then log "Skipping special device $d"; continue; fi

    # skip dm/mapper unless included
    if [[ "$base" =~ ^dm- || "$d" =~ /dev/mapper/ ]]; then
      if [ "$INCLUDE_DM" -eq 1 ]; then
        log "Including device-mapper $d (user requested --include-dm)"
      else
        log "Skipping device-mapper $d (use --include-dm to include)"
        continue
      fi
    fi

    # ensure device exists and is a disk
    if ! lsblk -ndo TYPE "$d" 2>/dev/null | grep -q "^disk$"; then
      warn "Resolved target $d is not present or not a disk; skipping"
      continue
    fi

    filtered+=("$d")
  done

  # dedupe
  declare -A seen
  TARGETS=()
  for x in "${filtered[@]}"; do
    if [[ -z "${seen[$x]:-}" ]]; then TARGETS+=("$x"); seen[$x]=1; fi
  done
  if [ ${#TARGETS[@]} -eq 0 ]; then err "No valid target disks"; exit 1; fi
}

# ---------------- Utilities: reload and dm/multipath helpers ----------------
reload_disk_strong() {
  local dev="$1"; local base=$(basename "$dev")
  log "Reload: partprobe $dev"
  partprobe "$dev" 2>/dev/null || true
  log "Reload: blockdev --rereadpt $dev"
  blockdev --rereadpt "$dev" 2>/dev/null || true
  if command -v kpartx &>/dev/null; then
    kpartx -d "$dev" 2>/dev/null || true
    sleep 1
    kpartx -a "$dev" 2>/dev/null || true
  fi
  if [ -w "/sys/block/$base/device/rescan" ]; then
    log "Triggering per-device rescan for $dev"
    echo 1 > "/sys/block/$base/device/rescan" 2>/dev/null || true
  fi
  for host in /sys/class/scsi_host/host*; do
    if [ -w "$host/scan" ]; then
      printf " - - -\n" > "$host/scan" 2>/dev/null || true
    fi
  done
  if command -v multipath &>/dev/null; then
    multipath -r 2>/dev/null || true
  fi
  if command -v udevadm &>/dev/null; then
    udevadm settle --timeout=5 2>/dev/null || true
  fi
}

# remove dm nodes referencing disk (best-effort)
remove_dm_refs() {
  local base="$1"
  if ! command -v dmsetup &>/dev/null; then return; fi
  for dm in /sys/block/dm-*; do
    [ -e "$dm" ] || continue
    # check slaves list for base
    if ls "$dm/slaves" 2>/dev/null | grep -qx "$base"; then
      dmname=$(cat "$dm/dm/name" 2>/dev/null || true)
      if [ -n "$dmname" ]; then
        warn "Removing dm node /dev/mapper/$dmname (best-effort)"
        dmsetup remove -f "/dev/mapper/$dmname" 2>/dev/null || true
      fi
    fi
  done
  dmsetup remove_all 2>/dev/null || true
}

# ---------------- LVM deep-clean for disk ----------------
lvm_deep_clean_for_device() {
  local dev="$1"
  local base=$(basename "$dev")
  if ! command -v pvs &>/dev/null; then
    warn "pvs not available; skipping LVM deep-clean"
    return
  fi

  # Find PV lines referencing this device (may be /dev/sdX or /dev/sdX1)
  mapfile -t pv_lines < <(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v b="$base" '$1 ~ b{print $1" "$2}' || true)
  if [ ${#pv_lines[@]} -eq 0 ]; then
    log "No LVM PVs detected referencing $dev"
    return
  fi

  for line in "${pv_lines[@]}"; do
    pv=$(echo "$line" | awk '{print $1}')
    vg=$(echo "$line" | awk '{print $2}')
    log "LVM found: PV=$pv VG=$vg — attempting deactivate & remove"
    if [ "$DRYRUN" -eq 1 ]; then
      log "[DRYRUN] vgchange -an $vg"
      log "[DRYRUN] lvremove -ff -y (all LVs in $vg)"
      log "[DRYRUN] vgremove -ff -y $vg"
      log "[DRYRUN] pvremove -ff -y $pv"
    else
      # deactivate VG
      vgchange -an "$vg" 2>/dev/null || true
      # remove LVs
      mapfile -t lvs_in_vg < <(lvs --noheadings -o lv_path "$vg" 2>/dev/null | awk '{print $1}' || true)
      for lv in "${lvs_in_vg[@]}"; do
        [ -n "$lv" ] && lvremove -ff -y "$lv" 2>/dev/null || true
      done
      vgremove -ff -y "$vg" 2>/dev/null || true
      pvremove -ff -y "$pv" 2>/dev/null || true
      ok "Removed VG $vg and PV $pv (best-effort)"
    fi
  done
}

# ---------------- Ceph / ZFS helpers ----------------
ceph_zap_if_needed() {
  local dev="$1"
  if [ "$ZAP_CEPH" -ne 1 ]; then return; fi
  if ! command -v ceph-volume &>/dev/null; then
    warn "ceph-volume not found; cannot zap Ceph OSD metadata automatically."
    return
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    log "[DRYRUN] ceph-volume lvm zap --destroy $dev"
  else
    log "Running: ceph-volume lvm zap --destroy $dev (may take a while)"
    ceph-volume lvm zap --destroy "$dev" 2>/dev/null || warn "ceph-volume zap failed (best-effort)"
  fi
}

zfs_labelclear_if_needed() {
  local dev="$1"
  if [ "$ZAP_ZFS" -ne 1 ]; then return; fi
  if ! command -v zpool &>/dev/null; then
    warn "zpool not present; cannot labelclear ZFS metadata."
    return
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    log "[DRYRUN] zpool labelclear -f $dev"
  else
    log "Running: zpool labelclear -f $dev"
    zpool labelclear -f "$dev" 2>/dev/null || warn "zpool labelclear failed (best-effort)"
  fi
}

# ---------------- Process single disk ----------------
process_disk() {
  local dev="$1"
  local base=$(basename "$dev")
  log "=== Processing $dev ==="

  # sanity
  if ! lsblk -ndo TYPE "$dev" 2>/dev/null | grep -q "^disk$"; then
    warn "$dev is not present or not a disk. Skipping."
    return
  fi

  # check mounts
  local mounted
  mounted=$(lsblk -nr -o NAME,MOUNTPOINT "$dev" | awk '$2!=""{print "/dev/"$1 ":" $2}' || true)
  if [ -n "$mounted" ]; then
    warn "Mounted partitions detected on $dev:"
    echo "$mounted"
    if [ "$MODE" == "ask" ]; then
      read -rp "Auto-unmount all partitions of $dev now? (y/N): " yn
      [[ "$yn" != "y" ]] && { warn "Skipping $dev (user declined unmount)"; return; }
    else
      log "Auto-unmounting (mode=auto)"
    fi
    # unmount partitions (try lazy, then force)
    for p in $(lsblk -ln -o NAME "$dev" | grep -v "^$base$"); do
      if mount | grep -q "/dev/$p"; then
        if [ "$DRYRUN" -eq 1 ]; then
          log "[DRYRUN] umount -l /dev/$p"
        else
          umount -l "/dev/$p" 2>/dev/null || umount -f "/dev/$p" 2>/dev/null || warn "Could not unmount /dev/$p"
          ok "Unmounted /dev/$p"
        fi
      fi
    done
  fi

  # swapoff if any swap on disk
  if lsblk -nr -o NAME,TYPE "$dev" | awk '$2=="swap"{print $1}' | grep -q .; then
    mapfile -t swap_parts < <(lsblk -nr -o NAME,TYPE "$dev" | awk '$2=="swap"{print "/dev/"$1}')
    for s in "${swap_parts[@]}"; do
      if [ "$DRYRUN" -eq 1 ]; then
        log "[DRYRUN] swapoff $s"
      else
        swapoff "$s" 2>/dev/null || warn "swapoff failed for $s"
        ok "swapoff $s"
      fi
    done
  fi

  # LVM deep-clean
  lvm_deep_clean_for_device "$dev"

  # remove device-mapper references (best-effort)
  remove_dm_refs "$base"

  # Ceph / ZFS
  ceph_zap_if_needed "$dev"
  zfs_labelclear_if_needed "$dev"

  # mdadm zero superblock (device + partitions)
  if command -v mdadm &>/dev/null; then
    for t in "$dev" $(lsblk -ln -o NAME "$dev" | awk 'NR>1{print "/dev/"$1}' || true); do
      if [ "$DRYRUN" -eq 1 ]; then
        log "[DRYRUN] mdadm --zero-superblock --force $t"
      else
        mdadm --zero-superblock --force "$t" 2>/dev/null || true
      fi
    done
  fi

  # wipefs + sgdisk
  if [ "$DRYRUN" -eq 1 ]; then
    log "[DRYRUN] wipefs -a $dev"
    log "[DRYRUN] sgdisk --zap-all $dev"
  else
    wipefs -a "$dev" 2>/dev/null || warn "wipefs returned non-zero for $dev"
    if command -v sgdisk &>/dev/null; then
      sgdisk --zap-all "$dev" 2>/dev/null || warn "sgdisk --zap-all returned non-zero"
    fi
  fi

  # Residual wipe head/tail (fast)
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
      fi
    fi
  fi

  # aggressive reload
  reload_disk_strong "$dev"

  # final checks
  sleep 1
  parts=$(lsblk -n -o NAME,TYPE "$dev" | awk '$2=="part"{print $1}' || true)
  pvleft=$(command -v pvs &>/dev/null && pvs --noheadings -o pv_name 2>/dev/null | grep -F "$(basename "$dev")" || true)
  if [[ -n "$parts" || -n "$pvleft" ]]; then
    warn "After cleanup, $dev still shows:"
    [ -n "$parts" ] && echo "  - partitions: $parts"
    [ -n "$pvleft" ] && echo "  - LVM PV: $pvleft"
    echo
    echo -e "${YELLOW}Possible reasons:${NC}"
    echo "- A process/service still holds the device (use lsof/ss to find); stop it then retry."
    echo "- Multipath/device-mapper is still active; consider stopping multipathd and remove maps."
    echo "- Ceph may be re-creating OSD mappings; ensure cluster is stopped for this disk."
    echo "- As last resort: reboot to flush kernel mappings."
    echo
    echo -e "${BLUE}Suggestions:${NC}"
    echo "- Run: lsblk, lsof /dev/<node>, pvs, vgs, lvs, mdadm --examine"
    echo "- Use flags: --include-dm, --zap-ceph, --zap-zfs as appropriate and re-run."
  else
    ok "$dev appears clean (no partitions or PVs detected)."
  fi

  ok "Finished $dev"
}

# ---------------- Main execution ----------------
check_tools
if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
  install_missing_tools
fi

resolve_targets "${USER_INPUT[@]}"

log "Final targets:"
for t in "${TARGETS[@]}"; do echo "  - $t"; done

# choose mode if not explicit
if [[ "$MODE" != "auto" && "$MODE" != "ask" ]]; then
  read -rp "Choose mode: auto/manual (default manual): " mm
  [[ "$mm" == "auto" ]] && MODE="auto" || MODE="ask"
fi

for dev in "${TARGETS[@]}"; do
  if [ "$MODE" == "ask" ]; then
    read -rp "Process $dev ? (y/N): " a
    [[ "$a" != "y" ]] && { log "Skipping $dev"; continue; }
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    log "[DRYRUN] Would process $dev"
    continue
  fi
  process_disk "$dev"
done

ok "All done."
