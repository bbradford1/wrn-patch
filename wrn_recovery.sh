#!/usr/bin/env bash
# WRN Recovery 2.0.0-rc.7 - EXCEPTION TOOLS for Hanwha Gen 2 WRNs (Ubuntu 22.04).
# NOTICE: This is an independent field-support tool, developed through hands-on testing on Hanwha WRN
# recorders. It is NOT an official Hanwha product and is NOT supported by Hanwha. It is provided as-is,
# based on real-world field experience. Use it at your own discretion and judgment.
# Not part of routine maintenance. wrn_maintenance.sh never runs anything here except --inspect.
#
#   sudo bash wrn_recovery.sh --inspect          read-only look at EVERY archive drive (default)
#   sudo bash wrn_recovery.sh --recover          re-mount every offline archive drive (type RECOVER)
#   sudo bash wrn_recovery.sh --recover --only sdb   limit --recover to one drive
#   sudo bash wrn_recovery.sh --os-video-scan    list WAVE video that landed on the OS drive (read-only)
#   sudo bash wrn_recovery.sh --os-video-delete  delete that video (type DELETE OS VIDEO)
#
# --recover and --os-video-delete change the recorder. They never restart WAVE, never reboot,
# never format, and never delete anything from an archive drive.
WRN_SCRIPT_VERSION='2.0.0-rc.7'
SLOTS=(sda sdb sdc sdd)
# Archive size sanity range (bytes). Lab recorders with smaller disks can override from the
# command line:  sudo WRN_MIN_ARCHIVE_BYTES=100000000 bash wrn_recovery.sh --recover
MIN_ARCHIVE_BYTES="${WRN_MIN_ARCHIVE_BYTES:-3000000000000}"
MAX_ARCHIVE_BYTES="${WRN_MAX_ARCHIVE_BYTES:-24000000000000}"

usage() {
  printf 'WRN Recovery %s\n' "$WRN_SCRIPT_VERSION"
  printf 'Usage: sudo bash wrn_recovery.sh [--inspect | --recover [--only sdX] | --os-video-scan | --os-video-delete [--low-only|--high-only] | --version | --help]\n'
  printf '  --inspect          Read-only report on every archive drive (default). Changes nothing.\n'
  printf '  --recover          Replay the ext4 journal and re-mount each OFFLINE archive drive. Asks you to type RECOVER.\n'
  printf '  --os-video-scan    Read-only: list WAVE video recorded onto the OS drive.\n'
  printf '  --os-video-delete  Delete that OS-drive video (irreversible). Asks you to type DELETE OS VIDEO.\n'
  printf 'Archive drives normally keep ~30 GB free (WAVE reserve); that is not a fault.\n'
}

# ======================= OS-drive video scan / delete =======================
# Carried over from wrn_os_archive_cleanup.sh. The 120-minute "recent recordings" block was removed on
# purpose; the remaining guards (all present archives mounted, rw ext4, typed confirmation) are unchanged.
os_video() (
# >>> ORIGINAL wrn_os_archive_cleanup.sh:39-68
set -euo pipefail
# Keep all terminal diagnostics with the other WRN reports; no WAVE data is modified by logging.
REPORT_DIR=/home/wave/Downloads/maintenance
if [[ "${EUID:-$(id -u)}" -eq 0 && -d "$REPORT_DIR" && ! -L "$REPORT_DIR" ]]; then
    REPORT="$REPORT_DIR/WRN-OS-Archive-Cleanup_$(date -u +%Y%m%dT%H%M%SZ)_$$.txt"
    touch "$REPORT"
    chmod 644 "$REPORT"
    exec > >(tee -a "$REPORT") 2>&1
    echo "WRN OS archive cleanup transcript: $REPORT"
fi


# ============================================================
# Configuration
# ============================================================

DATA_ROOT="/opt/hanwha/mediaserver/var/data"

# OS usage threshold used for informational warning
OS_WARNING_PERCENT=80

DO_DELETE=false
DO_LOW=true
DO_HIGH=true


# ============================================================
# Helper Functions
# ============================================================

# <<< ORIGINAL
usage() {
    cat <<'EOT'
WAVE OS Archive Cleanup (wrn_recovery.sh --os-video-scan / --os-video-delete)

  --os-video-scan                 List dated WAVE recording directories on the OS drive. Deletes nothing.
  --os-video-delete               Delete them after you type DELETE OS VIDEO.
    --low-only / --high-only      Limit to low_quality or hi_quality recordings.
EOT
}
# >>> ORIGINAL wrn_os_archive_cleanup.sh:114-262


get_os_usage() {
    df --output=pcent / | tail -1 | tr -dc '0-9'
}


show_os_status() {

    local usage
    usage="$(get_os_usage)"

    echo
    echo "OS disk usage status:"
    echo

    df -h /

    echo

    if (( usage >= OS_WARNING_PERCENT )); then
        echo "WARNING: OS drive usage is ${usage}%."
        echo "         Recommended target is below ${OS_WARNING_PERCENT}%."
    else
        echo "PASS: OS drive usage is ${usage}%."
        echo "      Usage is below the ${OS_WARNING_PERCENT}% warning threshold."
    fi

    echo
}


# ============================================================
# Parse Command-Line Arguments
# ============================================================

while [[ $# -gt 0 ]]; do

    case "$1" in

        --delete)
            DO_DELETE=true
            ;;

        --low-only)
            DO_LOW=true
            DO_HIGH=false
            ;;

        --high-only)
            DO_LOW=false
            DO_HIGH=true
            ;;

        --help|-h)
            usage
            exit 0
            ;;

        *)
            echo
            echo "ERROR: Unknown option: $1"
            echo
            usage
            exit 1
            ;;

    esac

    shift
done


# ============================================================
# Root Check
# ============================================================

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then

    echo
    echo "ERROR: This script must be run with sudo."
    echo
    echo "Example:"
    echo
    echo "  sudo bash $0"
    echo

    exit 1
fi


# ============================================================
# Validate WAVE Data Directory
# ============================================================

if [[ ! -d "$DATA_ROOT" ]]; then

    echo
    echo "ERROR: WAVE data directory was not found:"
    echo
    echo "  $DATA_ROOT"
    echo
    echo "No changes were made."
    echo

    exit 1
fi


# OS-drive only: reject mounted/non-OS WAVE data roots.
OS_DEVICE_ID="$(stat -c %d /)"
[[ ! -L "$DATA_ROOT" && "$(stat -c %d "$DATA_ROOT")" == "$OS_DEVICE_ID" ]] || {
    echo 'STOP: WAVE root is not an ordinary OS-filesystem directory.' >&2; exit 1;
}

if $DO_DELETE; then
    # Standalone deletion remains an exceptional, technician-supervised action.
    # The automatic dev.19 guided workflow never invokes --delete.
    [[ -r /dev/tty && -w /dev/tty ]] || {
        echo 'STOP: deletion requires an interactive terminal.' >&2; exit 1;
    }
    archive_found=false
    for mp in /mnt/sda /mnt/sdb /mnt/sdc /mnt/sdd; do
        if findmnt -rn -M "$mp" >/dev/null 2>&1 && \
           [[ "$(findmnt -rn -M "$mp" -o FSTYPE)" == ext4 ]] && \
           [[ ",$(findmnt -rn -M "$mp" -o OPTIONS)," == *,rw,* ]] && \
           [[ "$(stat -c %d "$mp")" != "$OS_DEVICE_ID" ]]; then
            archive_found=true
        elif findmnt -rn -M "$mp" >/dev/null 2>&1; then
            echo "STOP: unexpected mounted archive $mp; inspect first" >&2; exit 1
        fi
    done
    $archive_found || { echo 'STOP: no healthy, mounted archive; OS video cannot be removed.' >&2; exit 1; }
    # A configured, present, but unmounted archive means recording fallback may still be active.
    for mp in /mnt/sda /mnt/sdb /mnt/sdc /mnt/sdd; do
        if awk -v mp="$mp" '$1 !~ /^#/ && $2==mp {found=1} END{exit !found}' /etc/fstab && \
           ! findmnt -rn -M "$mp" >/dev/null 2>&1; then
            spec="$(awk -v mp="$mp" '$1 !~ /^#/ && $2==mp {print $1; exit}' /etc/fstab)"
            present=''
            case "$spec" in
              UUID=*) present="$(blkid -U "${spec#UUID=}" 2>/dev/null || true)" ;;
              /dev/*) [[ -b "$spec" ]] && present="$spec" ;;
            esac
            if [[ -n "$present" ]]; then
                echo "STOP: configured archive $mp is present but not mounted; no deletion." >&2
                exit 1
            fi
        fi
    done
# <<< ORIGINAL
# >>> ORIGINAL wrn_os_archive_cleanup.sh:275-598 sed:s/\$0 --delete/$0 --os-video-delete/g
    printf '%s\n' 'CAUTION: Deleting OS recording data is irreversible.' \
      'Verify WAVE is now recording to an archive drive, playback works, and customer approves footage loss.' > /dev/tty
    printf 'Type DELETE OS VIDEO to proceed: ' > /dev/tty
    IFS= read -r confirmation < /dev/tty || exit 1
    [[ "$confirmation" == 'DELETE OS VIDEO' ]] || { echo 'DECLINED: nothing deleted'; exit 1; }
fi

# ============================================================
# Start
# ============================================================

echo
echo "============================================================"
echo " WAVE OS Archive Cleanup"
echo "============================================================"
echo

echo "Script mode:"

if $DO_DELETE; then
    echo "  DELETE MODE"
else
    echo "  DRY RUN"
    echo "  Nothing will be deleted."
fi

echo

if $DO_LOW && $DO_HIGH; then
    echo "Archive types:"
    echo "  low_quality"
    echo "  hi_quality"
elif $DO_LOW; then
    echo "Archive type:"
    echo "  low_quality only"
elif $DO_HIGH; then
    echo "Archive type:"
    echo "  hi_quality only"
fi

echo


# ============================================================
# Initial Disk Usage
# ============================================================

show_os_status

echo "Current WAVE data usage:"
echo

du -sh "$DATA_ROOT" 2>/dev/null || true

echo
echo "Scanning WAVE server data..."
echo


# ============================================================
# Counters
# ============================================================

TOTAL_FOUND=0
TOTAL_REMOVED=0
SERVER_COUNT=0


# ============================================================
# Archive Processing Function
# ============================================================

clean_quality() {

    local uuid_dir="$1"
    local quality="$2"
    local qdir="$uuid_dir/$quality"

    [[ -d "$qdir" ]] || return

    echo "------------------------------------------------------------"
    echo "Checking:"
    echo
    echo "  $qdir"
    echo

    local before
    before="$(du -sh "$qdir" 2>/dev/null | awk '{print $1}')"

    echo "Current size: ${before:-unknown}"
    echo

    #
    # Expected structure:
    #
    # hi_quality/<camera>/2026
    #
    # or:
    #
    # low_quality/<camera>/2026
    #
    # The year directory is exactly two levels below
    # hi_quality or low_quality.
    #

    mapfile -d '' year_dirs < <(
        find "$qdir" -xdev \
            -mindepth 2 \
            -maxdepth 2 \
            -type d \
            -name '20[0-9][0-9]' \
            -print0 2>/dev/null
    )

    if [[ ${#year_dirs[@]} -eq 0 ]]; then

        echo "No dated recording directories found."
        echo

        return
    fi


    echo "Dated recording directories found: ${#year_dirs[@]}"
    echo


    for dir in "${year_dirs[@]}"; do

        # Never act on a symlink or another mounted filesystem, even in preview.
        [[ ! -L "$dir" && "$(stat -c %d "$dir")" == "$OS_DEVICE_ID" ]] || {
            echo "SKIP: not a plain directory on OS filesystem: $dir"; continue;
        }
        local size
        size="$(du -sh "$dir" 2>/dev/null | awk '{print $1}')"

        echo "  ${size:-?}  $dir"

        TOTAL_FOUND=$((TOTAL_FOUND + 1))

    done

    echo


    # --------------------------------------------------------
    # Delete Mode
    # --------------------------------------------------------

    if $DO_DELETE; then

        echo "Removing dated $quality recording directories..."
        echo

        for dir in "${year_dirs[@]}"; do
            [[ ! -L "$dir" && "$(stat -c %d "$dir")" == "$OS_DEVICE_ID" ]] || {
                echo "STOP: path changed or crosses filesystem: $dir"; exit 1;
            }
            echo "  Removing:"
            echo "    $dir"

            rm -rf -- "$dir"

            TOTAL_REMOVED=$((TOTAL_REMOVED + 1))

        done

        echo
        echo "Cleanup complete for $quality."

        local after
        after="$(du -sh "$qdir" 2>/dev/null | awk '{print $1}')"

        echo
        echo "Before: $before"
        echo "After:  $after"

    else

        echo "DRY RUN:"
        echo "No files were deleted."

    fi

    echo
}


# ============================================================
# Scan Each WAVE Server UUID Directory
# ============================================================

for uuid_dir in "$DATA_ROOT"/*; do

    [[ -d "$uuid_dir" ]] || continue

    #
    # Ignore directories that don't contain WAVE quality folders.
    #

    if [[ ! -d "$uuid_dir/hi_quality" && ! -d "$uuid_dir/low_quality" ]]; then
        continue
    fi

    SERVER_COUNT=$((SERVER_COUNT + 1))

    echo
    echo "============================================================"
    echo "WAVE Server Data Directory"
    echo "============================================================"
    echo
    echo "$uuid_dir"
    echo

    if $DO_LOW; then
        clean_quality "$uuid_dir" "low_quality"
    fi

    if $DO_HIGH; then
        clean_quality "$uuid_dir" "hi_quality"
    fi

done


# ============================================================
# Final Summary
# ============================================================

echo
echo "============================================================"
echo " CLEANUP SUMMARY"
echo "============================================================"
echo

echo "WAVE archive data directories detected: $SERVER_COUNT"
echo


# ------------------------------------------------------------
# Nothing Found
# ------------------------------------------------------------

if [[ $TOTAL_FOUND -eq 0 ]]; then

    echo "No dated WAVE recording directories were found."
    echo
    echo "No cleanup is required."
    echo
    echo "Nothing was deleted."

    echo
    echo "Current WAVE data usage:"
    echo

    du -sh "$DATA_ROOT" 2>/dev/null || true

    show_os_status

    echo "============================================================"
    echo

    exit 0
fi


# ------------------------------------------------------------
# Dry Run Summary
# ------------------------------------------------------------

if ! $DO_DELETE; then

    echo "Dated recording directories found: $TOTAL_FOUND"
    echo
    echo "DRY RUN ONLY."
    echo
    echo "Nothing was deleted."

    echo
    echo "If the directories listed above are safe to remove,"
    echo "run:"
    echo
    echo "  sudo bash $0 --os-video-delete"

    echo
    echo "Or selectively:"
    echo
    echo "  sudo bash $0 --os-video-delete --low-only"
    echo
    echo "  sudo bash $0 --os-video-delete --high-only"

    echo
    echo "Current WAVE data usage:"
    echo

    du -sh "$DATA_ROOT" 2>/dev/null || true

    show_os_status

    echo "============================================================"
    echo

    exit 0
fi


# ------------------------------------------------------------
# Delete Summary
# ------------------------------------------------------------

echo "Dated recording directories found:   $TOTAL_FOUND"
echo "Dated recording directories removed: $TOTAL_REMOVED"

echo
echo "Current WAVE data usage:"
echo

du -sh "$DATA_ROOT" 2>/dev/null || true

show_os_status

echo "Cleanup finished successfully."
echo
echo "============================================================"
# <<< ORIGINAL
)

# ======================= Archive drive discovery (all four slots) =======================
declare -A S_COUNT S_SPEC S_MOUNTED S_DEV S_REASON
resolve_spec() {
  local spec="$1" d='' kids=()
  case "$spec" in
    UUID=*)  d="$(blkid -U "${spec#UUID=}" 2>/dev/null || true)" ;;
    LABEL=*) d="$(blkid -L "${spec#LABEL=}" 2>/dev/null || true)" ;;
    /dev/*)  [[ -b "$spec" ]] && d="$(readlink -f "$spec")" ;;
  esac
  [[ -n "$d" && -b "$d" ]] || return 1
  # A factory fstab line may name the whole disk (/dev/sdb) while ext4 lives on /dev/sdb1.
  if [[ -z "$(blkid -s TYPE -o value "$d" 2>/dev/null || true)" ]]; then
    mapfile -t kids < <(lsblk -lnpo NAME,TYPE,FSTYPE "$d" 2>/dev/null | awk '$2=="part" && $3=="ext4" {print $1}')
    (( ${#kids[@]} == 1 )) || return 1
    d="${kids[0]}"
  fi
  printf '%s\n' "$d"
}

discover_slots() {
  local slot mp
  for slot in "${SLOTS[@]}"; do
    mp="/mnt/$slot"
    S_COUNT[$slot]="$(awk -v mp="$mp" '$1 !~ /^#/ && $2==mp {n++} END{print n+0}' /etc/fstab)"
    S_SPEC[$slot]="$(awk -v mp="$mp" '$1 !~ /^#/ && $2==mp {print $1; exit}' /etc/fstab)"
    S_MOUNTED[$slot]=no
    findmnt -rn -M "$mp" >/dev/null 2>&1 && S_MOUNTED[$slot]=yes
    S_DEV[$slot]=''
    if [[ -n "${S_SPEC[$slot]}" ]]; then S_DEV[$slot]="$(resolve_spec "${S_SPEC[$slot]}" || true)"; fi
  done
}

slot_state() {  # one-line English state for a slot
  local slot="$1"
  if [[ "${S_MOUNTED[$slot]}" == yes ]]; then echo "MOUNTED"
  elif (( ${S_COUNT[$slot]} == 0 )); then echo "not configured"
  elif [[ -z "${S_DEV[$slot]}" ]]; then echo "configured, drive NOT FOUND (empty bay or hardware problem)"
  else echo "OFFLINE - drive present but not mounted"
  fi
}

print_slot_table() {
  local slot
  printf '%-6s %-9s %-34s %-18s %s\n' SLOT FSTAB 'FSTAB SOURCE' DEVICE STATE
  for slot in "${SLOTS[@]}"; do
    printf '%-6s %-9s %-34s %-18s %s\n' "$slot" "${S_COUNT[$slot]} entr$([[ ${S_COUNT[$slot]} == 1 ]] && echo y || echo ies)" "${S_SPEC[$slot]:--}" "${S_DEV[$slot]:--}" "$(slot_state "$slot")"
  done
}

# ======================= Common setup for --inspect / --recover =======================
recovery_setup() {  # $1 = mode name used in the report file name
  [[ $EUID -eq 0 ]] || { echo 'Run using sudo.' >&2; exit 1; }
  local cmd
  for cmd in lsblk blkid findmnt systemctl tune2fs smartctl awk; do command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd" >&2; exit 1; }; done
  # Reports go in the maintenance folder with every other report, so the end-of-visit cleanup removes them too.
  # (v1.0.0 wrote them straight into ~/Downloads, where nothing ever cleaned them up.)
  local rdir=/home/wave/Downloads/maintenance
  [[ ! -L "$rdir" ]] || { echo "STOP: $rdir is a symlink; refusing to write reports there." >&2; exit 1; }
  if [[ ! -d "$rdir" ]]; then mkdir -p "$rdir" && chown wave:wave "$rdir" 2>/dev/null || true; fi
  STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  REPORT="$rdir/WRN-Archive-Recovery_${STAMP}_$1.txt"
  touch "$REPORT"; chmod 644 "$REPORT"
  exec > >(tee -a "$REPORT") 2>&1
  trap 'rc=$?; if ((rc)); then echo "Recovery utility exited with status $rc. See $REPORT"; fi' EXIT
}
log(){ printf '\n=== %s ===\n' "$*"; }
stop(){ echo "STOP: $*"; echo "Report: $REPORT"; exit 1; }

# ======================= --inspect (read-only) =======================
do_inspect() {
  local slot dev mp unit offline=0 notfound=0
  recovery_setup inspect
  log "WRN ARCHIVE RECOVERY $WRN_SCRIPT_VERSION - INSPECT"
  echo "Mode: inspect | $(date -Is) | host $(hostname) | Report: $REPORT"
  echo 'Read-only. No mount, repair, WAVE restart or reboot is performed.'
  discover_slots
  log 'ALL ARCHIVE SLOTS'
  print_slot_table
  log 'BLOCK DEVICES'
  lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,UUID,MOUNTPOINTS || true
  log 'FSTAB / GENERATED MOUNT SETTINGS'
  grep -vE '^[[:space:]]*(#|$)' /etc/fstab || true
  log 'SYSTEMD GLOBAL TIMEOUTS'
  systemctl show -p DefaultTimeoutStartUSec -p DefaultTimeoutStopUSec || true
  for slot in "${SLOTS[@]}"; do
    mp="/mnt/$slot"; unit="mnt-$slot.mount"; dev="${S_DEV[$slot]}"
    if [[ "${S_MOUNTED[$slot]}" == yes ]]; then
      log "$mp - MOUNTED"; findmnt -M "$mp" || true; df -hT "$mp" || true
      continue
    fi
    (( ${S_COUNT[$slot]} )) || continue
    if [[ -z "$dev" ]]; then
      notfound=$((notfound+1))
      log "$mp - DRIVE NOT FOUND"
      echo "fstab names ${S_SPEC[$slot]} but no matching drive is present. Check the bay / cabling / drive. Recovery cannot help."
      systemctl show "$unit" -p ActiveState -p Result -p TimeoutUSec -p What -p Where || true
      continue
    fi
    offline=$((offline+1))
    log "$mp - OFFLINE ($dev)"
    lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,UUID,MOUNTPOINTS "$dev" || true
    printf 'Device=%s UUID=%s Type=%s bytes=%s\n' "$dev" "$(blkid -s UUID -o value "$dev" 2>/dev/null || true)" "$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)" "$(lsblk -dnbo SIZE "$dev" | tr -d ' ')"
    systemctl show "$unit" -p ActiveState -p Result -p TimeoutUSec -p What -p Where || true
    echo '--- ext4 superblock (read only) ---'
    tune2fs -l "$dev" 2>&1 | grep -Ei 'Filesystem state:|Filesystem features:|Error count:|Last mount time:|Last write time:|Last checked:' || true
    echo '--- SMART (read only) ---'
    smartctl -H -A "$dev" 2>&1 | grep -Ei 'overall-health|SMART Health Status|Reallocated_Sector|Current_Pending|Offline_Uncorrect|UDMA_CRC|Command_Timeout|Power_Off_Retract|Temperature_Celsius|Error:' || true
    echo '--- this boot: kernel / mount-unit signals ---'
    journalctl -b -k --no-pager 2>/dev/null | grep -Ei "(EXT4-fs.*${dev##*/}|JBD2|ata[0-9].*(reset|error|failed)|I/O error.*${dev##*/}|Buffer I/O error)" | tail -60 || true
    journalctl -b -u "$unit" --no-pager -o short-iso 2>/dev/null | tail -60 || true
  done
  log 'ROOT STORAGE AND WAVE SERVICE'
  df -h /; systemctl is-active hanwha-mediaserver || true
  if [[ -z "${WRN_FROM_MAINTENANCE:-}" ]]; then
  log 'WHAT TO DO NEXT'
    if (( offline )); then
      echo "$offline archive drive(s) are present but OFFLINE. To journal-replay and re-mount them:"
      echo '  sudo bash wrn_recovery.sh --recover        (you will be asked to type RECOVER)'
      echo 'Get customer approval first: journal replay writes to the drive.'
    fi
    if (( notfound )); then echo "$notfound configured archive drive(s) were not found at all: hardware/cabling check, not a software recovery."; fi
    if (( !offline && !notfound )); then echo 'No offline archive drives found. Nothing to recover.'; fi
  fi
  echo "INSPECT COMPLETE. No repair or mount attempted. Report: $REPORT"
}

# ======================= --recover (changes the recorder) =======================
# Per-slot preflight. Prints the reason and returns 1 when a slot is not eligible.
declare -A DEV_CLAIM
# >>> FSTAB-VERIFY (identical copy in wrn_maintenance.sh.in and wrn_recovery.sh.in; test FV7 asserts they match)
# `findmnt --verify` exits non-zero on ANY [E] in the file, including ones that were already there and have nothing to do
# with the archives (e.g. an old `auto` removable-media line whose device is gone). So compare against the file as it was
# before the change and fail only on a problem the change itself would add.
fstab_verify_errors() {  # <fstab-file>: "E<TAB>mountpoint<TAB>message" per [E] and "P<TAB>n" parse errors; rc 1 = could not verify
  local out
  out="$(findmnt --verify --tab-file "$1" 2>&1)" || true
  grep -Eq '^(Success, no errors|[0-9]+ parse error)' <<< "$out" || return 1
  awk '
    /^[0-9]+ parse error/ { p = $1 }
    /^[^[:space:]]/ && !/^[0-9]+ parse error/ && !/^Success/ { t = $0 }
    /^[[:space:]]+\[E\]/ { m = $0; sub(/^[[:space:]]+\[E\][[:space:]]*/, "", m); print "E\t" t "\t" m }
    END { print "P\t" p + 0 }
  ' <<< "$out"
}
fstab_no_new_errors() {  # <candidate-fstab> <original-fstab> [quiet]: 0 = the candidate adds no [E] and no parse error
  local cand orig new t cp op
  cand="$(fstab_verify_errors "$1")" || { echo "STOP: could not run the fstab check on $1"; return 1; }
  orig="$(fstab_verify_errors "$2")" || orig=''
  new="$(comm -13 <(grep '^E' <<< "$orig" | sort -u) <(grep '^E' <<< "$cand" | sort -u))"
  cp="$(awk -F'\t' '$1=="P"{print $2}' <<< "$cand")"; op="$(awk -F'\t' '$1=="P"{print $2}' <<< "$orig")"
  if [[ -n "$new" ]]; then
    echo 'The fstab check found a problem this change would add:'
    awk -F'\t' '{print "  " $2 ": " $3}' <<< "$new"
    return 1
  fi
  if (( ${cp:-0} > ${op:-0} )); then echo 'The fstab check found a new parse error that this change would add.'; return 1; fi
  [[ "${3:-}" == quiet ]] && return 0
  # problems that were already there are tolerated and never touched; say so once per entry
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    if [[ "$t" =~ ^/mnt/sd[a-d]$ ]]; then echo "NOTE: fstab entry $t was already flagged by findmnt before this change; it was not made worse."
    else echo "NOTE: fstab has an unrelated entry ($t) that was not touched."; fi
  done < <(awk -F'\t' '$1=="E"{print $2}' <<< "$cand" | sort -u)
  return 0
}
# <<< FSTAB-VERIFY

fstab_slot_check() {  # read-only: exactly one eligible fstab line for this slot, drive not referenced elsewhere
  local mp="$1" u="$2" dev="$3" slot="$4" ents other src fs
  mapfile -t ents < <(awk -v mp="$mp" '$1 !~ /^#/ && NF>=4 && $2==mp {print}' /etc/fstab)
  (( ${#ents[@]} == 1 )) || { echo "fstab has ${#ents[@]} $mp entries; need exactly one (run wrn_maintenance.sh first to clean up duplicates)"; return 1; }
  read -r src _ fs _ <<< "${ents[0]}"
  case "$src" in "/dev/$slot"|"$dev"|"UUID=$u"|"/dev/disk/by-uuid/$u") ;; *) echo "unexpected existing $mp source $src"; return 1 ;; esac
  [[ "$fs" == ext4 || "$fs" == auto ]] || { echo "unexpected filesystem type $fs"; return 1; }
  other="$(awk -v mp="$mp" -v a="UUID=$u" -v b="/dev/disk/by-uuid/$u" -v c="$dev" '$1 !~ /^#/ && NF>=2 && $2!=mp && ($1==a || $1==b || $1==c) {print; exit}' /etc/fstab)"
  [[ -z "$other" ]] || { echo "drive is also referenced by another fstab line: $other"; return 1; }
}
# Rewrites the ONE fstab line of a slot to UUID + ext4 with at least 60s device / 120s mount timeouts, never
# shortening a longer existing timeout. (Pure Bash/awk port of the python in wrn_archive_recovery.sh 1.1.)
fstab_update_slot() {  # fstab_update_slot <mountpoint> <uuid> <device> <slot>
  local mp="$1" u="$2" dev="$3" slot="$4" lineno src tgt fs opts dump pass extra o key v secs best newopts tmp
  local -a keep=() toks=()
  fstab_slot_check "$mp" "$u" "$dev" "$slot" >/dev/null || { fstab_slot_check "$mp" "$u" "$dev" "$slot"; return 1; }
  lineno="$(awk -v mp="$mp" '$1 !~ /^#/ && NF>=4 && $2==mp {print NR; exit}' /etc/fstab)"
  read -r src tgt fs opts dump pass extra <<< "$(sed -n "${lineno}p" /etc/fstab)"
  IFS=, read -r -a toks <<< "$opts"
  for o in "${toks[@]}"; do
    [[ -n "$o" ]] || continue
    case "$o" in x-systemd.device-timeout=*|x-systemd.mount-timeout=*) ;; *) keep+=("$o") ;; esac
  done
  newopts="$(IFS=,; echo "${keep[*]}")"
  for key in x-systemd.device-timeout x-systemd.mount-timeout; do
    [[ $key == x-systemd.device-timeout ]] && best=60 || best=120
    for o in "${toks[@]}"; do
      [[ "$o" == "$key="* ]] || continue
      v="${o#*=}"
      secs="$(awk -v v="$v" 'BEGIN{ if (v ~ /^[0-9.]+min$/) {sub(/min$/,"",v); print v*60} else if (v ~ /^[0-9.]+ms$/) {sub(/ms$/,"",v); print v/1000} else if (v ~ /^[0-9.]+s$/) {sub(/s$/,"",v); print v+0} else if (v ~ /^[0-9.]+$/) print v+0; else print "BAD" }')"
      [[ "$secs" != BAD ]] || { echo "Unrecognized timeout; refuse to overwrite"; return 1; }
      best="$(awk -v a="$best" -v b="$secs" 'BEGIN{print (b>a)?b:a}')"
    done
    newopts+="${newopts:+,}${key}=$(awk -v x="$best" 'BEGIN{printf "%d", x}')s"
  done
  tmp="$(mktemp /etc/.fstab.wrn-XXXXXXXX)" || return 1
  if ! awk -v n="$lineno" -v l="UUID=$u $tgt ext4 $newopts ${dump:-0} ${pass:-0}" 'NR==n {print l; next} {print}' /etc/fstab > "$tmp" \
     || ! chmod 644 "$tmp" || ! mv -f -- "$tmp" /etc/fstab; then rm -f "$tmp"; return 1; fi
  echo "Updated $mp: $(sed -n "${lineno}p" /etc/fstab)"
}
slot_preflight() {
  local slot="$1" dev="${S_DEV[$1]}" mp="/mnt/$1" type uuid size os_dev where msg
  type="$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)"
  uuid="$(blkid -s UUID -o value "$dev" 2>/dev/null || true)"
  size="$(lsblk -dnbo SIZE "$dev" 2>/dev/null | tr -d ' ')"
  [[ "$type" == ext4 ]] || { S_REASON[$slot]="$dev is not ext4 (found '${type:-none}'); no repair supported"; return 1; }
  [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || { S_REASON[$slot]='cannot verify the drive UUID'; return 1; }
  [[ "$size" =~ ^[0-9]+$ ]] && (( size >= MIN_ARCHIVE_BYTES && size <= MAX_ARCHIVE_BYTES )) || { S_REASON[$slot]="size ${size:-?} bytes is outside the expected archive range; no automatic selection"; return 1; }
  os_dev="$(findmnt -no SOURCE / | sed 's/\[.*//')"
  [[ "$(readlink -f "$os_dev")" != "$dev" ]] || { S_REASON[$slot]='drive is the OS root'; return 1; }
  where="$(findmnt -n -S "$dev" -o TARGET 2>/dev/null || true)"
  [[ -z "$where" ]] || { S_REASON[$slot]="drive is already mounted at $where"; return 1; }
  [[ -z "$(findmnt -n -M "$mp" -o SOURCE 2>/dev/null || true)" ]] || { S_REASON[$slot]="$mp is occupied by a different source"; return 1; }
  [[ -d "$mp" ]] || { S_REASON[$slot]="$mp directory is missing"; return 1; }
  if [[ -n "${DEV_CLAIM[$dev]:-}" ]]; then S_REASON[$slot]="same drive $dev is also claimed by ${DEV_CLAIM[$dev]}; ambiguous - names may have shifted"; return 1; fi
  DEV_CLAIM[$dev]="$slot"
  msg="$(fstab_slot_check "$mp" "$uuid" "$dev" "$slot" 2>&1)" || { S_REASON[$slot]="${msg##*$'\n'}"; return 1; }
  return 0
}

# Recover ONE drive. Runs in a subshell so one drive's failure cannot abort the others.
recover_slot() (
  set -Eeuo pipefail
  slot="$1"; dev="${S_DEV[$slot]}"; mp="/mnt/$slot"; unit="mnt-$slot.mount"
  uuid="$(blkid -s UUID -o value "$dev")"
  fail(){ echo "FAIL $slot: $*"; exit 1; }
  log "JOURNAL RECOVERY (MUTATING $dev)"
  command -v e2fsck >/dev/null || fail 'e2fsck missing'
  [[ -z "$(findmnt -n -S "$dev" -o TARGET 2>/dev/null || true)" ]] || fail 'device mounted during preflight; abort'
  # NEW IN 2.0.0 - deterministic and never interactive (v1.0.0 ran e2fsck in a pseudo-terminal and relied on a person
  # answering its questions; a stray Enter after "n" silently answered "Fix<y>? yes", e2fsck reset the corrupt journal,
  # exited 1 and the drive was mounted anyway). Now:
  #  1) read-only pre-check: e2fsck -n answers "no" to every question itself and writes nothing. A damaged journal
  #     returns 12 here and the drive FAILS before anything is written.
  #  2) journal replay in preen mode (no questions, no terminal needed).
  #  3) if e2fsck's output shows it cleared/recreated the journal, or its status is anything but 0/1, the drive FAILS.
  set +e
  PRE="$(e2fsck -n -E journal_only "$dev" < /dev/null 2>&1)"; PRC=$?
  set -e
  if (( PRC != 0 )); then
    printf '%s\n' "$PRE"
    fail "the journal on $dev is damaged (read-only check returned status $PRC). Nothing was changed. A full file-system check by engineering/support is needed. Do not mount."
  fi
  set +e
  OUT="$(e2fsck -p -E journal_only "$dev" < /dev/null 2>&1)"; RC=$?
  set -e
  printf '%s\n' "$OUT"
  # e2fsck exit bits: 1 corrected, 2 reboot needed; all others treated as failure.
  (( (RC & ~1) == 0 )) || fail "journal recovery returned status $RC; manual intervention required. Do not mount."
  if grep -qiE 'invalid journal|journal has been (deleted|regenerated)|superblock is corrupt|recreate journal|CLEARED' <<<"$OUT"; then
    fail 'e2fsck had to discard the journal instead of replaying it. A full file-system check by engineering/support is needed. Do not mount.'
  fi
  FEATURES="$(tune2fs -l "$dev" | sed -n 's/^Filesystem features:[[:space:]]*//p')"
  STATE="$(tune2fs -l "$dev" | sed -n 's/^Filesystem state:[[:space:]]*//p')"
  echo "Filesystem state: $STATE; features: $FEATURES"
  [[ "$STATE" == clean && " $FEATURES " != *' needs_recovery '* ]] || fail 'journal recovery state uncertain; do not mount or edit fstab'
  log "FSTAB BACKUP AND SAFE UPDATE ($mp)"
  BACKUP="/etc/fstab.wrn-archive-recovery-${STAMP}-${slot}.bak"
  cp -a /etc/fstab "$BACKUP"
  echo "Backup: $BACKUP"
  fstab_update_slot "$mp" "$uuid" "$dev" "$slot" || { cp -a "$BACKUP" /etc/fstab; fail 'fstab update failed; backup restored'; }
  # Whole-file `findmnt --verify` also trips on old, unrelated fstab lines, so compare with the pre-edit copy: only a
  # problem this edit would ADD blocks (see fstab_no_new_errors). An unrelated pre-existing error is noted and left alone.
  if ! fstab_no_new_errors /etc/fstab "$BACKUP"; then
    cp -a "$BACKUP" /etc/fstab
    fail 'fstab validation found a new problem; backup restored, no mount attempted'
  fi
  log "RELOAD MOUNT UNIT AND MOUNT ONLY $mp"
  systemctl daemon-reload
  systemctl reset-failed "$unit" || true
  systemctl start "$unit" || fail 'mount attempt failed; inspect journal. Do not reboot'
  SRC="$(findmnt -n -M "$mp" -o SOURCE || true)"
  MOUNT_UUID="$(findmnt -n -M "$mp" -o UUID || true)"
  [[ -n "$SRC" && "$MOUNT_UUID" == "$uuid" ]] || fail "mounted source/UUID check failed (source=$SRC UUID=$MOUNT_UUID)"
  findmnt -M "$mp"
  df -hT "$mp"
  systemctl show "$unit" -p ActiveState -p Result -p TimeoutUSec
  echo "PASS $slot: $mp mounted with expected UUID $uuid"
)

do_recover() {
  local slot only="${1:-}" targets=() blocked=() absent=() ok=() bad=() answer
  recovery_setup recover
  log "WRN ARCHIVE RECOVERY $WRN_SCRIPT_VERSION - RECOVER"
  echo "Mode: recover | $(date -Is) | host $(hostname) | Report: $REPORT"
  echo 'No WAVE restarts, reboots, or recording removal.'
  if [[ "$MIN_ARCHIVE_BYTES" != 3000000000000 || "$MAX_ARCHIVE_BYTES" != 24000000000000 ]]; then
    echo "NOTE: archive size range overridden: $MIN_ARCHIVE_BYTES - $MAX_ARCHIVE_BYTES bytes"
  fi
  discover_slots
  log 'ALL ARCHIVE SLOTS'
  print_slot_table
  for slot in "${SLOTS[@]}"; do
    [[ -z "$only" || "$only" == "$slot" ]] || continue
    [[ "${S_MOUNTED[$slot]}" == no ]] || continue
    (( ${S_COUNT[$slot]} )) || continue
    if [[ -z "${S_DEV[$slot]}" ]]; then
      # An empty optional bay is normal (the factory fstab lists all four). A missing PRIMARY drive is not.
      if [[ $slot == sda ]]; then blocked+=("sda: primary archive drive not found; hardware/cabling check, not a software recovery")
      else absent+=("$slot"); fi
      continue
    fi
    if slot_preflight "$slot"; then targets+=("$slot"); else blocked+=("$slot: ${S_REASON[$slot]}"); fi
  done
  if (( ${#blocked[@]} )); then
    log 'NOT ELIGIBLE FOR AUTOMATIC RECOVERY'
    printf '  %s\n' "${blocked[@]}"
  fi
  if (( ${#absent[@]} )); then
    echo "NOTE: configured but no drive found in: ${absent[*]} (empty optional bay, or a hardware/cabling fault - nothing to recover in software)"
  fi
  if (( ${#targets[@]} == 0 )); then
    if (( ${#blocked[@]} )); then stop 'no drive can be safely recovered by this tool; see the reasons above. No changes made.'; fi
    echo 'Every configured archive drive is already mounted. Nothing to recover.'
    echo "Report: $REPORT"; exit 0
  fi
  log 'HUMAN AUTHORIZATION REQUIRED'
  echo "These archive drives are UNMOUNTED and will be recovered, one at a time:"
  for slot in "${targets[@]}"; do echo "  /mnt/$slot  ${S_DEV[$slot]}  UUID $(blkid -s UUID -o value "${S_DEV[$slot]}")"; done
  echo 'Journal-only e2fsck will WRITE filesystem metadata on each drive.'
  echo 'It can change incomplete recording transactions. This is NOT a backup, and not a full fsck repair.'
  echo 'Proceed only after customer approval and if loss of unrecovered footage is acceptable.'
  [[ -t 0 ]] || stop 'Interactive terminal required. Not running filesystem repair unattended.'
  read -r -p 'Type RECOVER to authorize ext4 journal replay and archive mounts: ' answer
  if [[ "$answer" != RECOVER ]]; then
    # Asked once more, in plain words: a technician used to yes/no questions may press Enter out of habit.
    echo
    echo 'Nothing has been changed yet.'
    echo 'To go ahead, type the word RECOVER (all capital letters) and press Enter.'
    echo 'Pressing Enter alone, or typing anything else, will stop here and leave the recorder as it is.'
    read -r -p 'Type RECOVER to authorize, or anything else to stop: ' answer
  fi
  [[ "$answer" == RECOVER ]] || stop 'User did not authorize recovery. Nothing was changed.'
  for slot in "${targets[@]}"; do
    log "RECOVERING /mnt/$slot"
    if recover_slot "$slot"; then ok+=("$slot"); else bad+=("$slot"); fi
  done
  log 'POST-RECOVERY SUMMARY'
  discover_slots
  print_slot_table
  df -h /; systemctl is-active hanwha-mediaserver || true
  (( ${#ok[@]} )) && echo "RECOVERED: ${ok[*]}"
  (( ${#bad[@]} )) && echo "FAILED:    ${bad[*]}  (see messages above; do not reboot)"
  (( ${#blocked[@]} )) && echo "NOT ELIGIBLE: ${#blocked[@]} drive(s) listed above need manual review"
  echo 'Check live WAVE recording and playback in the client. No WAVE restart, reboot, OS fallback cleanup, or full fsck was performed.'
  echo "Report: $REPORT"
  (( ${#bad[@]} == 0 && ${#blocked[@]} == 0 )) || exit 1
  echo 'SUCCESS: every archive drive is mounted.'
  (( ${#ok[@]} )) && echo "IMPORTANT: WAVE may not start using the re-mounted drive(s) (${ok[*]}) until WAVE is restarted. In WAVE's Drive view, check that each one shows as in use; if not, restart the recorder."
  [[ -n "${WRN_FROM_MAINTENANCE:-}" ]] || echo 'Next: run sudo bash wrn_maintenance.sh'
}

# ======================= dispatch =======================
MODE="${1:---inspect}"
# Gen 1 (Ubuntu 18.04) recorders are never recovered by this tool, whatever the option (--version/--help excepted).
if [[ "$MODE" != --version && "$MODE" != --help && "$MODE" != -h ]] \
   && [[ "$(. /etc/os-release 2>/dev/null; echo "${ID:-}:${VERSION_ID:-}")" == ubuntu:18.04 ]]; then
  echo 'STOP: this is an Ubuntu 18.04 (Gen 1) recorder. Recovery is not allowed here; on this Gen 1 recorder run wrn_legacy_maintenance.sh (or wrn_diagnose.sh to only check it).' >&2; exit 2
fi
case "$MODE" in
  --version) echo "$WRN_SCRIPT_VERSION"; exit 0 ;;
  --help|-h) usage; exit 0 ;;
  --inspect) [[ $# -le 1 ]] || { usage >&2; exit 2; }; do_inspect ;;
  --recover)
    ONLY=''
    if [[ $# -eq 3 && "${2:-}" == --only ]]; then
      [[ "$3" =~ ^sd[a-d]$ ]] || { echo 'ERROR: --only takes sda, sdb, sdc or sdd' >&2; exit 2; }
      ONLY="$3"
    elif [[ $# -ne 1 ]]; then usage >&2; exit 2; fi
    do_recover "$ONLY" ;;
  --os-video-scan)
    [[ $# -le 2 ]] || { usage >&2; exit 2; }
    [[ "${2:-}" =~ ^(|--low-only|--high-only)$ ]] || { usage >&2; exit 2; }
    [[ $EUID -eq 0 ]] || { echo 'Run using sudo.' >&2; exit 1; }
    os_video ${2:+"$2"}; exit $? ;;
  --os-video-delete)
    [[ $# -le 2 ]] || { usage >&2; exit 2; }
    [[ "${2:-}" =~ ^(|--low-only|--high-only)$ ]] || { usage >&2; exit 2; }
    [[ $EUID -eq 0 ]] || { echo 'Run using sudo.' >&2; exit 1; }
    os_video --delete ${2:+"$2"}; exit $? ;;
  *) usage >&2; exit 2 ;;
esac
