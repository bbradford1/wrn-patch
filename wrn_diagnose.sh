#!/usr/bin/env bash
# WRN Diagnose 2.0.0-rc.3 - READ-ONLY diagnostics for Hanwha WRN recorders.
# NOTICE: This is an independent field-support tool, developed through hands-on testing on Hanwha WRN
# recorders. It is NOT an official Hanwha product and is NOT supported by Hanwha. It is provided as-is,
# based on real-world field experience. Use it at your own discretion and judgment.
# Makes no changes: no repairs, mounts, service restarts, package or fstab edits.
# Safe on every recorder. This is the ONLY file an Ubuntu 18.04 (Gen 1) recorder receives.
#
#   sudo bash wrn_diagnose.sh            full report (default)
#   sudo bash wrn_diagnose.sh --full     full report (18.04 and 22.04)
#        bash wrn_diagnose.sh --quick    quick look, no root needed (18.04 and 22.04)
#   sudo bash wrn_diagnose.sh --space    where is the OS drive space going (22.04)
#   sudo bash wrn_diagnose.sh --spillover  video written to the OS drive (22.04)
#   sudo bash wrn_diagnose.sh --metadata   WAVE analytics data stored on the OS drive? (22.04; also run by wrn_maintenance.sh)
#
# NOTE ON ARCHIVE FREE SPACE: WAVE deliberately keeps about 30 GB free on every archive
# drive. Low free space on an archive drive is NORMAL and is never reported as a problem.
WRN_SCRIPT_VERSION='2.0.0-rc.3'

usage() {
  printf 'WRN Diagnose %s (read-only)\n' "$WRN_SCRIPT_VERSION"
  printf 'Usage: sudo bash wrn_diagnose.sh [--full|--quick|--space|--spillover|--metadata|--version|--help]\n'
  printf '  --full       Full diagnostic report (default). Ubuntu 18.04 or 22.04.\n'
  printf '  --quick      Quick look; no root needed. Ubuntu 18.04 or 22.04.\n'
  printf '  --space      OS-drive space breakdown. Ubuntu 22.04.\n'
  printf '  --spillover  Video that WAVE wrote to the OS drive. Ubuntu 22.04.\n'
  printf '  --metadata   Is WAVE storing analytics data on the OS drive? Ubuntu 22.04.\n'
  printf 'Archive drives normally keep ~30 GB free (WAVE reserve); that is not a fault.\n'
}

# ---- NEW IN 2.0.0: WAVE analytics (metadata) storage location, report-only ----
# WAVE has a Drive-view setting for where analytics/motion metadata is stored. If it is left on the OS
# drive, metadata files keep growing under /opt/hanwha/mediaserver/var/data/<serverGuid>/ . After the
# setting is switched to an archive drive WAVE itself deletes those OS-drive files (verified on the lab
# recorder), so any recently written file there means the setting is still on the OS drive.
# This only LOOKS; it never changes WAVE settings.
# PROVISIONAL: 48 hours is a first guess, to be tuned with real field data (different camera counts/activity).
WRN_METADATA_ACTIVE_HOURS=48
metadata_location_check() {
  local base=/opt/hanwha/mediaserver/var/data mp any_archive=NO d g n=0 bytes=0 b
  [[ -d $base ]] || { echo 'STATUS: SKIPPED - WAVE data folder not found.'; return 0; }
  for mp in /mnt/sda /mnt/sdb /mnt/sdc /mnt/sdd; do
    findmnt -rn -M "$mp" >/dev/null 2>&1 && any_archive=YES
  done
  if [[ $any_archive == NO ]]; then
    echo 'STATUS: SKIPPED - no archive drive is mounted, so this cannot be judged (fix the archive first).'
    return 0
  fi
  if [[ "$(findmnt -rn -T "$base" -o TARGET 2>/dev/null)" != / ]]; then
    echo 'STATUS: SKIPPED - WAVE data folder is not on the OS drive.'
    return 0
  fi
  for d in "$base"/*/; do
    [[ -d $d ]] || continue
    g=$(find "$d" -type f \( -path '*/archive/metadata/*' -o -path '*/motion_data/metadata/*' -o -name 'object_detection.sqlite*' \) \
         -mmin "-$(( WRN_METADATA_ACTIVE_HOURS * 60 ))" -printf '%s\n' 2>/dev/null) || true
    [[ -n $g ]] || continue
    n=$(( n + $(printf '%s\n' "$g" | wc -l) ))
    for b in $g; do bytes=$(( bytes + b )); done
  done
  if (( n == 0 )); then
    echo "OK: no WAVE analytics data has been written to the OS drive in the last ${WRN_METADATA_ACTIVE_HOURS} hours."
  else
    echo "FINDING: ${n} WAVE analytics file(s) (about $(( bytes / 1024 )) KB) were written to the OS drive in the last ${WRN_METADATA_ACTIVE_HOURS} hours."
    echo "WAVE's analytics data is being stored on the OS drive instead of the archive drive - this slowly fills the OS drive over time."
    echo "Switch this in WAVE's Drive settings to point to the archive drive. (This script does not change any WAVE setting.)"
  fi
}

# ---- Full diagnostics, Ubuntu 22.04 (collector carried over from wrn_maintenance.sh 1.0.0) ----
# >>> ORIGINAL wrn_maintenance.sh:22-105
collect_diagnostics() (
set -u
export LC_ALL=C
umask 077

if (( EUID != 0 )); then echo 'ERROR: run with sudo for complete system logs and SMART data.' >&2; exit 1; fi
OPERATOR="${SUDO_USER:-root}"
OP_HOME="$(getent passwd "$OPERATOR" | cut -d: -f6)"
[[ -n "$OP_HOME" ]] || OP_HOME=/root
OUTDIR="${WRN_REPORT_DIR:-$OP_HOME/Downloads}"
if [[ ! -d "$OUTDIR" ]]; then echo "ERROR: report directory not found: $OUTDIR" >&2; exit 1; fi
HOST="$(hostname -s 2>/dev/null | tr -cd '[:alnum:]_.-' | cut -c1-48)"
HOST="${HOST:-unknown}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$OUTDIR/WRN-Diagnostics_${HOST}_${STAMP}_$$.txt"
: > "$REPORT" || exit 1
chmod 644 "$REPORT"
chown wave:wave "$REPORT" 2>/dev/null || true

section() { printf '\n===== %s =====\n' "$1" >> "$REPORT"; }
run() {
  local label="$1" duration="$2"; shift 2
  section "$label"
  timeout -k 2s "${duration}s" "$@" >> "$REPORT" 2>&1
  local result=$?
  if (( result != 0 )); then printf '[command exit status: %d; output may be incomplete]\n' "$result" >> "$REPORT"; fi
}

# Resolve the archive by mounted source, fstab UUID, or by a single detected large ext4 disk.
# Do not assume that /dev/sda is the correct disk on every WRN.
ARCHIVE_MOUNT=/mnt/sda
ARCHIVE_DEV=''
ARCHIVE_MATCH=''
mounted_source="$(findmnt -rn -M "$ARCHIVE_MOUNT" -o SOURCE 2>/dev/null || true)"
if [[ -n "$mounted_source" && -b "$mounted_source" ]]; then
  ARCHIVE_DEV="$(readlink -f "$mounted_source")"; ARCHIVE_MATCH='mounted source'
else
  fstab_spec="$(awk '$1 !~ /^#/ && $2=="/mnt/sda" {print $1; exit}' /etc/fstab 2>/dev/null)"
  if [[ -n "$fstab_spec" ]]; then
    case "$fstab_spec" in
      UUID=*) ARCHIVE_DEV="$(blkid -U "${fstab_spec#UUID=}" 2>/dev/null || true)" ;;
      LABEL=*) ARCHIVE_DEV="$(blkid -L "${fstab_spec#LABEL=}" 2>/dev/null || true)" ;;
      /dev/*) [[ -b "$fstab_spec" ]] && ARCHIVE_DEV="$(readlink -f "$fstab_spec")" ;;
    esac
    if [[ -n "$ARCHIVE_DEV" ]]; then ARCHIVE_MATCH='fstab resolution'; fi
  fi
fi
if [[ -z "$ARCHIVE_DEV" ]]; then
  mapfile -t candidates < <(lsblk -bpnro NAME,SIZE,FSTYPE,TYPE 2>/dev/null | awk '$3=="ext4" && $2>=1000000000000 && ($4=="disk" || $4=="part") {print $1}')
  if (( ${#candidates[@]} == 1 )); then ARCHIVE_DEV="${candidates[0]}"; ARCHIVE_MATCH='unique large ext4 device'; fi
fi
if [[ -n "$ARCHIVE_DEV" && ! -b "$ARCHIVE_DEV" ]]; then ARCHIVE_DEV=''; ARCHIVE_MATCH=''; fi
ARCHIVE_FS=''
[[ -n "$ARCHIVE_DEV" ]] && ARCHIVE_FS="$(lsblk -dnro FSTYPE "$ARCHIVE_DEV" 2>/dev/null | head -1)"
ARCHIVE_MOUNTED='NO'
if findmnt -rn -M "$ARCHIVE_MOUNT" >/dev/null 2>&1; then ARCHIVE_MOUNTED='YES'; fi

# Information-only status; do not infer recording health from mount presence.
# Exact mount matching avoids treating an ordinary OS directory as an archive.
archive_status_summary() {
  local mp src fs opts size count=0
  for mp in /mnt/sda /mnt/sdb /mnt/sdc /mnt/sdd; do
    if ! findmnt -rn -M "$mp" >/dev/null 2>&1; then
      continue
    fi
    count=$((count + 1))
  done
  printf 'Archives mounted: %d\n' "$count"
  for mp in /mnt/sda /mnt/sdb /mnt/sdc /mnt/sdd; do
    if ! findmnt -rn -M "$mp" >/dev/null 2>&1; then
      continue
    fi
    src="$(findmnt -rn -M "$mp" -o SOURCE 2>/dev/null || true)"
    fs="$(findmnt -rn -M "$mp" -o FSTYPE 2>/dev/null || true)"
    opts="$(findmnt -rn -M "$mp" -o OPTIONS 2>/dev/null || true)"
    size="$(df -h --output=size "$mp" 2>/dev/null | awk 'NR==2 {print $1}')"
    [[ -n "$size" ]] || size='unknown'
    case ",$opts," in
      *,rw,*) printf '%s  %s  %s  RW  %s\n' "$mp" "${src:-unknown}" "${fs:-unknown}" "$size" ;;
      *,ro,*) printf '%s  %s  %s  RO  %s\n' "$mp" "${src:-unknown}" "${fs:-unknown}" "$size" ;;
      *) printf '%s  %s  %s  UNKNOWN-MODE  %s\n' "$mp" "${src:-unknown}" "${fs:-unknown}" "$size" ;;
    esac
  done
  printf 'Note: mounted status does not establish WAVE recording or playback health.\n'
# <<< ORIGINAL
  printf 'Note: WAVE keeps ~30 GB free on each archive drive by design; low free space there is normal, not a fault.\n'
# >>> ORIGINAL wrn_maintenance.sh:106-246 sed:s/WRN Maintenance 1\.0\.0/WRN Diagnose @VERSION@/;s/WRN MAINTENANCE 1\.0\.0/WRN DIAGNOSE @VERSION@/
}

section 'REPORT INFORMATION'
printf 'UTC: %s\nHostname: %s\nCollector: WRN Diagnose 2.0.0-rc.3\nOperator: %s\nMode: READ-ONLY\nArchive selected: %s\nSelection method: %s\nArchive mounted at /mnt/sda: %s\n' "$(date -u -Is)" "$HOST" "$OPERATOR" "${ARCHIVE_DEV:-UNRESOLVED}" "${ARCHIVE_MATCH:-not determined}" "$ARCHIVE_MOUNTED" >> "$REPORT"
run 'OS, KERNEL, TIME, UPTIME' 5 bash -c 'grep -E "^(PRETTY_NAME|VERSION_ID)=" /etc/os-release; printf "Kernel: "; uname -r; printf "Local time: "; date -Is; printf "Boot: "; uptime -s; uptime -p'
run 'OS DISK CAPACITY' 5 df -hT /
run 'OS JOURNAL UTILIZATION (READ-ONLY)' 8 bash -c 'journalctl --disk-usage 2>&1; for p in /var/log/journal /run/log/journal; do if [[ -d "$p" ]]; then du -sh "$p" 2>&1; else echo "$p: not present"; fi; done'
run 'KB LOGGING CONFIGURATION (READ-ONLY)' 12 bash -c 'echo "-- rsyslog syntax --"; rsyslogd -N1 2>&1; echo "-- rsyslog state --"; systemctl is-active rsyslog || true; echo "-- logrotate dry run --"; logrotate -d /etc/logrotate.conf 2>&1 | grep -Ei "warning:|error:|reading config file rsyslog|considering log /var/log/(syslog|kern.log)" | tail -30; echo "-- logrotate timer --"; systemctl list-timers --all --no-pager logrotate.timer 2>&1'
run 'LOG AND WAVE DIRECTORY CAPACITY (READ-ONLY)' 12 bash -c 'for p in /var/log /opt/hanwha/mediaserver/var/log /opt/hanwha/mediaserver/var/data; do if [[ -d "$p" ]]; then du -shx "$p" 2>&1; fi; done; find /var/log -xdev -type f -size +100M -printf "%s bytes %p\n" 2>/dev/null | sort -rn | head -15'
run 'WAVE STORAGE PATH AND THRESHOLD CONTEXT' 8 bash -c 'df -hT / /opt/hanwha/mediaserver/var/data 2>&1; findmnt -T /opt/hanwha/mediaserver/var/data -o TARGET,SOURCE,FSTYPE,OPTIONS 2>&1'
run 'BLOCK DEVICES / MODEL / UUID / MOUNTS' 6 lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,FSTYPE,UUID,MOUNTPOINTS,RO
run 'ARCHIVE MOUNT AND SPACE' 5 bash -c 'if findmnt -rn -M /mnt/sda; then df -hT /mnt/sda; else echo "NOT MOUNTED at /mnt/sda (archive df skipped; /mnt/sda may reside on OS filesystem)"; fi'
section 'ALL ARCHIVES SUMMARY (READ-ONLY)'
archive_status_summary >> "$REPORT"
run 'ARCHIVE FSTAB ENTRY' 5 awk '$2=="/mnt/sda" && $1 !~ /^#/ {print}' /etc/fstab
run 'FSTAB DUPLICATE AND TIMEOUT AUDIT (READ-ONLY)' 5 awk '
  $1 !~ /^#/ && NF>=4 {
    mounts[$2]++; devices[$1]++;
    if ($2 ~ /^\/mnt\/sd[a-z]$/) {
      printf "ARCHIVE_ENTRY line=%d device=%s mount=%s options=%s\n", NR,$1,$2,$4;
      if ($1 ~ /^\/dev\/sd[a-z]$/) print "WARNING: volatile /dev/sdX naming";
      if ($4 ~ /x-systemd.device-timeout=5([,s]|$)/) print "WARNING: 5-second device timeout";
    }
  }
  END {
    for (m in mounts) if (mounts[m]>1) printf "WARNING: duplicate mountpoint %s count=%d\n",m,mounts[m];
    for (d in devices) if (d ~ /^(UUID=|LABEL=|\/dev\/)/ && devices[d]>1) printf "REVIEW: repeated source %s count=%d\n",d,devices[d];
  }
' /etc/fstab
run 'EXPECTED ARCHIVE DEVICE PRESENCE (READ-ONLY)' 5 bash -c 'for d in /dev/sda /dev/sdb /dev/sdc /dev/sdd; do if [[ -b "$d" ]]; then echo "PRESENT: $d"; else echo "ABSENT: $d"; fi; done'
run 'SYSTEMD ARCHIVE MOUNT STATE' 5 systemctl show mnt-sda.mount -p LoadState -p ActiveState -p Result -p What -p Where -p TimeoutUSec -p ActiveEnterTimestamp
run 'ARCHIVE FAILURE AND JOURNAL FLAGS (READ-ONLY)' 8 bash -c '
  systemctl show mnt-sda.mount -p ActiveState -p Result -p TimeoutUSec
  journalctl -u mnt-sda.mount -n 35 --no-pager -o short-iso 2>&1 | grep -Ei "timed out|failed|mounting|mounted|timeout" || true
  journalctl -k -n 2500 --no-pager 2>&1 | grep -Ei "JBD2: recovery failed|EXT4-fs \(sda\): error loading journal|recovering journal" | tail -20 || true
  if ! findmnt -rn -M /mnt/sda >/dev/null 2>&1; then
    echo "WARNING: Archive unmounted; no fsck, journal replay, or mounting attempted. Collect forensics before repair."
  fi
' 
run 'FSTAB DEVICE MATCH AND PERSISTENCE' 5 bash -c 'grep -E "^[^#].*[[:space:]]/mnt/sda[[:space:]]" /etc/fstab; if grep -Eq "^UUID=[^[:space:]]+[[:space:]]+/mnt/sda[[:space:]]+ext4[[:space:]]" /etc/fstab; then echo "PASS: archive fstab uses UUID"; else echo "WARNING: archive fstab not confirmed UUID ext4"; fi'
if [[ -n "$ARCHIVE_DEV" ]]; then
  run 'ARCHIVE IDENTITY AND FILESYSTEM SIGNATURE' 7 bash -c 'lsblk -dn -o NAME,SIZE,FSTYPE,UUID,MODEL,SERIAL "$1"; blkid "$1"' _ "$ARCHIVE_DEV"
  if [[ "$ARCHIVE_MOUNTED" == NO && "$ARCHIVE_FS" == ext4 ]] && ! findmnt -rn -S "$ARCHIVE_DEV" >/dev/null 2>&1; then
    run 'EXT4 SUPERBLOCK METADATA (UNMOUNTED ONLY; NO REPAIR)' 9 bash -c 'tune2fs -l "$1" | grep -Ei "Filesystem (state|features)|Journal inode|Last (mount|write) time|Last checked|Mount count|error|Lifetime writes"' _ "$ARCHIVE_DEV"
  else
    section 'EXT4 SUPERBLOCK METADATA'
    printf 'Skipped: mounted=%s, detected filesystem=%s. Avoiding ambiguous live recovery-flag interpretation.\n' "$ARCHIVE_MOUNTED" "${ARCHIVE_FS:-unknown}" >> "$REPORT"
  fi
else
  section 'ARCHIVE IDENTITY'; echo 'Unable to identify archive confidently. NO DEVICE-SPECIFIC CHECKS performed.' >> "$REPORT"
fi
run 'BOOT RECORDS (AVAILABLE JOURNAL)' 6 bash -c 'journalctl --list-boots --no-pager | tail -12; echo "--- last reboot/shutdown events ---"; last -x -n 12 2>&1'
run 'ARCHIVE MOUNT UNIT JOURNAL (AVAILABLE)' 8 journalctl -u mnt-sda.mount --no-pager -n 100 -o short-iso
# Limit journal reading before filtering: avoid traversing months of unrelated system logs.
run 'KERNEL: EXT4 / JBD2 / SATA / I-O / eMMC (LAST 4000 KERNEL LINES)' 12 bash -c 'journalctl -k -n 4000 --no-pager -o short-iso | grep -Ei "EXT4-fs|JBD2|I/O error|Buffer I/O|ata[0-9]|SATA|resetting link|blk_update_request|device timeout|task blocked|sda|mmcblk" | tail -110 || true'
run 'SYSTEM: MOUNT FAILURES / JOURNAL REPLAY / SHUTDOWNS (RECENT 4000)' 12 bash -c 'journalctl -n 4000 --no-pager -o short-iso | grep -Ei "mnt-sda.mount|Failed to mount /mnt/sda|error loading journal|recovering journal|EXT4-fs.*error|systemd-shutdown|Reached target Shutdown|Starting Reboot|Starting Power-Off" | tail -100 || true'
if [[ -n "$ARCHIVE_DEV" ]]; then
  run 'SMART IDENTITY, HEALTH AND KEY ATTRIBUTES (NO SELF-TEST)' 15 bash -c 'if command -v smartctl >/dev/null; then smartctl -i -H -A "$1" 2>&1 | grep -Ei "Device Model|Serial Number|Firmware Version|User Capacity|SATA Version|overall-health|SMART Health Status|Reallocated_Sector|Current_Pending|Offline_Uncorrectable|UDMA_CRC|Power_Cycle|Power_On_Hours|Power-Off_Retract|Command_Timeout|Reported_Uncorrect|Temperature"; else echo "smartctl not installed"; fi' _ "$ARCHIVE_DEV"
  run 'SMART ERROR LOG SUMMARY (NO SELF-TEST)' 12 bash -c 'if command -v smartctl >/dev/null; then smartctl -l error "$1" 2>&1 | tail -35; else echo "smartctl not installed"; fi' _ "$ARCHIVE_DEV"
fi
# WAVE Media Server history: inspect bounded rotated logs, preserving filename and timestamp.
# Never search recording archives or write inside the mediaserver tree.
collect_wave_logs() {
  section 'WAVE MEDIA SERVER STORAGE EVENTS (CLASSIFIED, BOUNDED)'
  local logdir=/opt/hanwha/mediaserver/var/log
  if [[ ! -d "$logdir" ]]; then
    echo 'STATUS: LOG DIRECTORY MISSING' >> "$REPORT"; return
  fi
  local tmpdir sourcef size rc selected=0 skipped=0 warnings=0
  local -a list=()
  tmpdir="$(mktemp -d "$OUTDIR/.wrn-wave-XXXXXX")" || {
    echo 'STATUS: TEMP FILE CREATION FAILED' >> "$REPORT"; return;
  }
  chmod 700 "$tmpdir"
  : > "$tmpdir/high"
  : > "$tmpdir/context"
  # Recent log rotations only; do not search recordings, ZIPs, or update logs.
  mapfile -t list < <(find "$logdir" -maxdepth 1 -type f \
    \( -name 'main.log' -o -name 'main.log.[0-9]*' -o -name 'system.log' -o -name 'system.log.[0-9]*' \) \
    ! -name '*.zip' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -24 | cut -d' ' -f2-)
  if (( ${#list[@]} == 0 )); then
    echo 'STATUS: NO MATCHING LOG FILES' >> "$REPORT"
    rm -rf -- "$tmpdir"; return
  fi
  for sourcef in "${list[@]}"; do
    size="$(stat -c %s -- "$sourcef" 2>/dev/null || echo 0)"
    if (( size > 100000000 )); then ((skipped+=1)); continue; fi
    ((selected+=1))
    # Each log is processed as a stream; only up to 120 lines per category
    # per file are staged. Output lines limited to 450 characters.
    # No WAVE application state is changed.
    case "$sourcef" in
      *.gz) timeout -k 2s 12s gzip -cd -- "$sourcef" 2> "$tmpdir/err" ;;
      *) timeout -k 2s 12s cat -- "$sourcef" 2> "$tmpdir/err" ;;
    esac | LC_ALL=C awk -v source="$(basename "$sourcef")" '
      {
        x=tolower($0)
        # Ignore known lab noise, routine housekeeping, metadata reads,
        # WAVE updater download messages and cloud integration.
        if (x ~ /\/boot\/efi\/wisenet wave media|\/sys\/fs\/fuse\/connections\/wisenet wave media|filealreadydownloaded|wave-server_update|removeemptydirs: finished|loading chunks from db|specific_features.txt|skip missing resource|resourcemonitor\(|catalog rebuild operation is canceled|cloud_integration/) next
        if (x ~ /\/(mnt\/sda|opt\/hanwha\/mediaserver\/var\/data)/) path=1; else path=0
        # High confidence: actual recording/archive path with failure,
        # or severe disk / filesystem / write error.
        severe=(x ~ /i\/o error|input\/output error|no space left on device|read-only file system|error loading journal|journal abort|failed to write|write failed|disk disconnected|archive.*inaccessible|storage.*inaccessible|storage.*unavailable|storage.*disconnected|failed to mount/)
        if ((path && x ~ /fail|error|inaccess|unavail|disconnect|read.only|timeout|no space/) || severe) kind="HIGH"
        else if (x ~ /(warning|error|fatal)/ && x ~ /(createstorage|qnfilestorageresource|storagedb|storage directory|storage|archive|filesystem|disk|mount|recording|write)/) kind="CONTEXT"
        else next
        if (length($0)>450) $0=substr($0,1,450) "...[truncated]"
        printf "%s %s : %s\n", kind, source, $0
      }
    ' | tail -n 240 > "$tmpdir/selected"
    grep '^HIGH ' "$tmpdir/selected" | cut -c6- | tail -n 120 >> "$tmpdir/high"
    grep '^CONTEXT ' "$tmpdir/selected" | cut -c9- | tail -n 120 >> "$tmpdir/context"
    # File reading status is checked separately below.
    if [[ -s "$tmpdir/err" ]]; then
      ((warnings+=1))
      printf 'READ WARNING: %s: ' "$(basename "$sourcef")" >> "$REPORT"
      head -c 120 "$tmpdir/err" >> "$REPORT"
      printf '\n' >> "$REPORT"
    fi
    : > "$tmpdir/err"
  done
  # AWK error output is also collected in high, so select only tagged dated events.
  local high_count context_count
  high_count="$(grep -Ec '^[^ ]+ : [0-9]{4}-[0-9]{2}-[0-9]{2} ' "$tmpdir/high" || true)"
  context_count="$(wc -l < "$tmpdir/context")"
  printf 'STATUS: SEARCHED; files=%d; skipped=%d; read_warnings=%d\n' "$selected" "$skipped" "$warnings" >> "$REPORT"
  printf 'CATEGORIES: HIGH=%s CONTEXT=%s (before final output limit)\n' "$high_count" "$context_count" >> "$REPORT"
  echo 'HIGH means matching severe storage/write errors; verify exact affected path before concluding archive failure.' >> "$REPORT"
  echo 'Known non-archive initialization noise and updater download warnings excluded.' >> "$REPORT"
  echo '--- HIGH PRIORITY (last 80, timestamp order) ---' >> "$REPORT"
  if (( high_count )); then
    grep -E '^[^ ]+ : [0-9]{4}-[0-9]{2}-[0-9]{2} ' "$tmpdir/high" | LC_ALL=C sort -s -k3,3 -k4,4 | tail -80 >> "$REPORT"
  else echo 'No high-priority matching events in searched logs.' >> "$REPORT"; fi
  echo '--- CONTEXT ONLY (last 30, timestamp order) ---' >> "$REPORT"
  if (( context_count )); then
    LC_ALL=C sort -s -k3,3 -k4,4 "$tmpdir/context" | tail -30 >> "$REPORT"
  else echo 'No contextual matching events in searched logs.' >> "$REPORT"; fi
  rm -rf -- "$tmpdir"
}
collect_wave_logs
# <<< ORIGINAL
# WAVE Event Log: 1.0.0 read mserver.sqlite with python3. Pure-Bash version: uses the sqlite3 command-line tool
# ONLY if it is already installed; otherwise the section says so. Counts are approximate (keyword based).
section 'WAVE EVENT LOG (SQLITE, READ-ONLY; BOUNDED; APPROXIMATE)'
if command -v sqlite3 >/dev/null 2>&1 && [[ -r /opt/hanwha/mediaserver/var/mserver.sqlite ]]; then
  {
    echo 'SOURCE: /opt/hanwha/mediaserver/var/mserver.sqlite  (opened read-only; last 30 days, newest 20000 rows; keyword classification)'
    timeout -k 2s 9s sqlite3 -readonly -batch -separator ': ' /opt/hanwha/mediaserver/var/mserver.sqlite "
      SELECT 'CLASS ' || cat, COUNT(*) FROM (
        SELECT CASE
          WHEN d LIKE '%/mnt/sda%' OR d LIKE '%archive%' OR d LIKE '%disconnected%' OR d LIKE '%inaccessible%' OR d LIKE '%mount fail%' OR d LIKE '%disk failure%' THEN 'ARCHIVE_OR_STORAGE'
          WHEN d LIKE '%systemstoragefull%' OR d LIKE '%system storage full%' OR d LIKE '%disk almost full%' OR d LIKE '%disk full%' OR d LIKE '%low disk space%' OR d LIKE '%/opt/hanwha/mediaserver/var/data%' THEN 'OS_DISK'
          WHEN d LIKE '%storage%' OR d LIKE '%disk%' OR d LIKE '%filesystem%' OR d LIKE '%recording%' THEN 'STORAGE_UNCLASSIFIED'
          ELSE 'OTHER' END AS cat
        FROM (SELECT lower(coalesce(event_data,'')) AS d FROM event_log
              WHERE timestamp >= (strftime('%s','now') - 2592000) * 1000000 ORDER BY timestamp DESC LIMIT 20000))
      GROUP BY cat;" 2>&1 || echo 'STATUS: UNAVAILABLE / INCOMPLETE (query error or timeout)'
    echo 'Interpretation: zero matched rows does not prove zero WAVE alerts; inspect the WAVE client event log if needed.'
  } >> "$REPORT"
else
  echo 'STATUS: SKIPPED - sqlite3 command-line tool not installed (or database unreadable). Check the WAVE client event log.' >> "$REPORT"
fi
section 'WAVE ANALYTICS (METADATA) STORAGE LOCATION (READ-ONLY)'
metadata_location_check >> "$REPORT" 2>&1
# >>> ORIGINAL wrn_maintenance.sh:344-376 sed:s/WRN Maintenance 1\.0\.0/WRN Diagnose @VERSION@/;s/WRN MAINTENANCE 1\.0\.0/WRN DIAGNOSE @VERSION@/
run 'WAVE SERVICE STATUS (NO RESTART)' 5 bash -c 'systemctl is-active hanwha-mediaserver.service; systemctl show hanwha-mediaserver.service -p MainPID -p NRestarts -p ActiveEnterTimestamp'
# OS fallback directory can contain recordings: measure only, never alter.
run 'WAVE OS FALLBACK DATA (DEPTH 2, NO DELETION)' 12 bash -c 'p=/opt/hanwha/mediaserver/var/data; if [[ -d "$p" ]]; then du -xhd2 "$p" 2>/dev/null | sort -h | tail -25; else echo "No fallback path"; fi'
run 'OS TOP DIRECTORIES >= 1 GiB' 18 bash -c 'du -xhd1 / 2>/dev/null | awk '\''{x=$1; if (x ~ /G$/ && x+0>=1 || x ~ /T$/) print}'\'' | sort -h'
run 'LARGE SUBDIRECTORIES (VAR, OPT, HOME; >= 1 GiB)' 22 bash -c 'for p in /var /opt /home; do du -xhd2 "$p" 2>/dev/null; done | awk '\''{x=$1; if (x ~ /G$/ && x+0>=1 || x ~ /T$/) print}'\'' | sort -h | tail -35'
run 'SNAP INSTALLED / DISABLED REVISIONS (INFORMATION ONLY)' 6 bash -c 'if command -v snap >/dev/null; then snap list --all 2>&1 | head -35; else echo "snap unavailable"; fi'
run 'SNAP REFRESH HOLD (READ-ONLY)' 7 bash -c 'if command -v snap >/dev/null; then snap refresh --time; else echo "SKIP: snap unavailable"; fi'
run 'FAILED SYSTEMD UNITS (READ-ONLY)' 7 systemctl --failed --no-pager
run 'COCKPIT PACKAGE VERSIONS / LOCAL WAVE CLIENT' 6 bash -c 'dpkg-query -W cockpit-bridge cockpit-system cockpit-ws cockpit-files 2>&1; ls -1 /home/wave/.local/share/Hanwha/client/hanwha/ 2>/dev/null || true'
section 'INTERPRETATION AND OPERATING LIMITS'
cat >> "$REPORT" <<'NOTES'
This is observation, not a filesystem integrity check. SMART PASSED does not rule out intermittent failures.
Absence of matches may mean logs were vacuumed, rotated, or not persisted.
Unexpected shutdown cannot be inferred from service-level "unclean termination" messages alone.
Archive recording and playback must be independently confirmed in WAVE, especially on active production recorders.
Diagnostic collection does not perform repairs, fsck, journal replay, mount/unmount, reboot, service restart, recording cleanup, or outbound upload.
Report includes sensitive device serials and identifiers; use only approved transfer paths.
A kernel-blocked I/O may not terminate promptly even with timeout.
NOTES
if [[ "$OPERATOR" != root ]]; then
  chown "$OPERATOR" "$REPORT" 2>/dev/null || echo "WARNING: report ownership could not be changed: $REPORT" >&2
fi
chmod 644 "$REPORT"
chown wave:wave "$REPORT" 2>/dev/null || true
printf '\n========== WRN DIAGNOSE 2.0.0-rc.3 | DIAGNOSTICS ========\n'
printf 'Host: %s\nReport: %s\n' "$HOST" "$REPORT"
printf 'OS: '; df -h / | awk 'NR==2 {print $5 " used; " $4 " free"}'
archive_status_summary
printf 'WAVE service: '; systemctl is-active hanwha-mediaserver.service 2>/dev/null || true
printf 'SMART: '; grep -m1 'SMART overall-health self-assessment test result:' "$REPORT" || echo 'See report'
printf 'Diagnostic report collected. This diagnostic operation did not modify services, mounts or recordings.\n==========================================\n'

)
# <<< ORIGINAL

diag_full_2204() {
  [[ $EUID -eq 0 ]] || { echo 'Run with sudo' >&2; return 2; }
  WRN_DIR=/home/wave/Downloads/maintenance
  [[ -d "$WRN_DIR" && ! -L "$WRN_DIR" ]] || { echo 'STOP: maintenance folder must exist and not be a symlink' >&2; return 2; }
  export WRN_REPORT_DIR="$WRN_DIR"
  collect_diagnostics || return $?
  echo
  echo 'WAVE ANALYTICS STORAGE CHECK:'
  metadata_location_check
}

# Report only - nothing is ever deleted here. journald manages only the journal folder of THIS machine-id; folders
# left by other machine-ids (e.g. the factory image) are never trimmed by the log limit or the vacuum.
other_journals_report() {
  local base=/var/log/journal cur d n=0 total=0 sz cnt newest oldest
  cur="$(cat /etc/machine-id 2>/dev/null || true)"
  if [[ ! -d "$base" ]]; then echo 'OTHER_MACHINE_ID_JOURNALS: dirs=0 bytes=0 (no persistent journal folder)'; return 0; fi
  sz="$(du -sB1 "$base/$cur" 2>/dev/null | awk '{print $1}')"
  echo "Current machine-id: ${cur:-unknown} (this folder is managed by journald: ${sz:-0} bytes)"
  for d in "$base"/*/; do
    d="${d%/}"
    [[ -d "$d" && "${d##*/}" != "$cur" ]] || continue
    sz="$(du -sB1 "$d" 2>/dev/null | awk '{print $1}')"
    cnt="$(find "$d" -type f 2>/dev/null | wc -l)"
    oldest="$(find "$d" -type f -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort | head -1)"
    newest="$(find "$d" -type f -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort | tail -1)"
    echo "  other machine-id ${d##*/}: bytes=${sz:-0} files=$cnt oldest=${oldest:--} newest=${newest:--}"
    n=$((n+1)); total=$((total+${sz:-0}))
  done
  echo "OTHER_MACHINE_ID_JOURNALS: dirs=$n bytes=$total"
  if [[ $n -gt 0 ]]; then echo 'These folders belong to other machine ids (for example the factory image). journald never trims them. Nothing was changed or deleted.'; fi
  return 0
}

# ---- Full diagnostics, Ubuntu 18.04 / Gen 1 (carried over from wrn_legacy.sh) ----
diag_legacy() (
  set -u
  export LC_ALL=C
  umask 077
  VERSION="$WRN_SCRIPT_VERSION"
# >>> ORIGINAL wrn_legacy.sh:16-75
(( EUID == 0 )) || { echo 'ERROR: run with sudo' >&2; exit 2; }
[[ -r /etc/os-release ]] || { echo 'ERROR: cannot detect OS' >&2; exit 2; }
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 18.04 ]] || {
  echo "STOP: Ubuntu 18.04 required (found ${PRETTY_NAME:-unknown}). No report written." >&2
  exit 2
}
for cmd in timeout df du journalctl findmnt systemctl awk date hostname lsblk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing $cmd" >&2; exit 2; }
done
OWNER="${SUDO_USER:-root}"
OWNER_HOME="$(getent passwd "$OWNER" | awk -F: 'NR==1 {print $6}')"
[[ -n "$OWNER_HOME" ]] || OWNER_HOME=/root
OUTDIR="${WRN_REPORT_DIR:-$OWNER_HOME/Downloads/maintenance}"
[[ -d "$OUTDIR" && ! -L "$OUTDIR" ]] || { echo "ERROR: report directory unavailable: $OUTDIR" >&2; exit 2; }
HOST="$(hostname -s | tr -cd '[:alnum:]_.-' | cut -c1-48)"
HOST="${HOST:-unknown}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$OUTDIR/WRN-Legacy-Diagnostics_${HOST}_${STAMP}_$$.txt"
( set -o noclobber; : > "$REPORT" ) || { echo 'ERROR: unable to create report' >&2; exit 1; }
chmod 600 "$REPORT"
section() { printf '\n===== %s =====\n' "$1" >> "$REPORT"; }
run() {
  local label="$1" seconds="$2"; shift 2
  section "$label"
  timeout -k 2s "${seconds}s" "$@" >> "$REPORT" 2>&1
  local rc=$?
  if (( rc != 0 )); then printf '[command exit status %d; incomplete or unavailable]\n' "$rc" >> "$REPORT"; fi
}
section 'REPORT INFORMATION'
printf 'WRN Legacy: %s\nMode: READ ONLY\nOS: %s\nUTC: %s\nHostname: %s\n' "$VERSION" "$PRETTY_NAME" "$(date -u -Is)" "$HOST" >> "$REPORT"
run 'OS STORAGE' 8 df -hT / /var/log
run 'JOURNAL UTILIZATION' 8 journalctl --disk-usage
run 'JOURNAL CONFIGURATION' 6 bash -c 'for f in /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf; do [[ -f "$f" ]] && { printf "%s\n" "--- $f ---"; grep -E "^[[:space:]]*(Storage|SystemMaxUse|SystemKeepFree|RuntimeMaxUse|MaxRetentionSec)=" "$f" || true; }; done; true'
run 'LARGE LOG FILES (>= 1 GiB)' 12 find /var/log -xdev -type f -size +1023M -printf '%s bytes %p\n'
run 'LOG FOLDER USAGE' 12 du -shx /var/log
run 'WAVE SERVICE STATE' 6 bash -c 'systemctl is-active hanwha-mediaserver.service; systemctl show hanwha-mediaserver.service -p MainPID -p ActiveEnterTimestamp -p NRestarts'
run 'BLOCK DEVICE AND MOUNT INVENTORY' 8 lsblk -o NAME,SIZE,MODEL,FSTYPE,UUID,MOUNTPOINT,RO
run 'ARCHIVE MOUNT STATUS' 6 bash -c 'if findmnt -rn -M /mnt/sda; then df -hT /mnt/sda; else echo "Archive not mounted at /mnt/sda; no mount attempted"; fi'
run 'FSTAB ENTRIES AND DUPLICATES' 6 awk '
  $1 !~ /^#/ && NF>=4 {
    if ($2 ~ /^\/mnt\/sd[a-z]$/) printf "Archive line %d: %s\n",NR,$0;
    mounts[$2]++;
  }
  END { for(m in mounts) if(mounts[m]>1) printf "WARNING: repeated mount point %s (%d entries)\n",m,mounts[m]; }
' /etc/fstab
run 'OS TOP DIRECTORIES (>= 1 GiB)' 18 bash -c 'du -xhd1 / 2>/dev/null | awk '\''$1 ~ /G$/ && $1+0>=1 || $1 ~ /T$/ { print }'\'' | sort -h'
run 'WAVE FALLBACK STORAGE SIZE (NO DELETION)' 15 bash -c 'p=/opt/hanwha/mediaserver/var/data; if [[ -d "$p" ]]; then du -shx "$p"; findmnt -T "$p" -o TARGET,SOURCE,FSTYPE; else echo "WAVE data directory missing"; fi'
section 'SAFETY AND LIMITATIONS'
cat >> "$REPORT" <<'NOTES'
Read-only diagnostic build. No journald stop/start, log vacuum, journal deletion, cron changes,
WAVE restart, network service changes, mount actions, repairs, or reboot.
SMART health and filesystem checks are not performed by this legacy build.
An absent/healthy mount or active service does not prove WAVE is successfully recording.
Older journal entries may be missing due to prior cleanup. Verify recording in WAVE client.
Report can contain identifying system details; do not post publicly.
NOTES
if [[ "$OWNER" != root ]]; then chown "$OWNER" "$REPORT" 2>/dev/null || true; fi
printf 'WRN Legacy %s: read-only diagnostic report created\n%s\nNo maintenance performed.\n' "$VERSION" "$REPORT"
# <<< ORIGINAL
  # NEW IN 2.0.0 (owner request, report only): journal folders of other machine ids
  { printf '\n===== JOURNAL FOLDERS OF OTHER MACHINE IDS (REPORT ONLY) =====\n'; other_journals_report; } >> "$REPORT"
  other_journals_report | grep -E '^OTHER_MACHINE_ID_JOURNALS'
)

# ---- Quick look (carried over from wrn_inspect.sh; works without root) ----
diag_quick() (
# >>> ORIGINAL wrn_inspect.sh:4-94 sed:s/v0\.1\.0/@VERSION@/g
set -u
export LC_ALL=C
umask 077

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
HOST=$(hostname -s 2>/dev/null || printf 'unknown')
HOST=${HOST//[^A-Za-z0-9_.-]/_}
BASE="${HOME:-/tmp}"
if [[ $(id -u) -eq 0 && -d /home/wave ]]; then BASE=/home/wave; fi
if [[ ! -d "$BASE" || ! -w "$BASE" ]]; then BASE=/tmp; fi
REPORT="$BASE/WRN-Inspection-${HOST}-${STAMP}.txt"
if ! ( : > "$REPORT" ) 2>/dev/null; then
  REPORT="/tmp/WRN-Inspection-${HOST}-${STAMP}.txt"
  : > "$REPORT" || { echo 'ERROR: Cannot save report'; exit 1; }
fi
chmod 644 "$REPORT" 2>/dev/null || true
# Keep the output visible while also saving it; never allow failures to stop later checks.
exec > >(tee -a "$REPORT") 2>&1

section() { printf '\n========== %s ==========\n' "$1"; }
run() {
  printf '\n$'; printf ' %q' "$@"; printf '\n'
  if command -v timeout >/dev/null 2>&1; then timeout 20 "$@" 2>&1 || printf '[NOTE] Command exited nonzero or timed out: %s\n' "$1"
  else "$@" 2>&1 || printf '[NOTE] Command exited nonzero: %s\n' "$1"; fi
}

section 'WRN READ-ONLY INSPECTION 2.0.0-rc.3'
printf 'UTC: %s\nHost: %s\nReport: %s\n' "$STAMP" "$HOST" "$REPORT"
printf 'No maintenance, package changes, mounting, service restarts, or reboot.\n'
section 'OPERATING SYSTEM'
if [[ -r /etc/os-release ]]; then grep -E '^(PRETTY_NAME|ID|VERSION_ID)=' /etc/os-release; fi
run uname -a
run uptime
section 'ROOT FILESYSTEM'
run df -hT /
run df -i /
section 'STORAGE BLOCK DEVICES'
if command -v lsblk >/dev/null 2>&1; then
  run lsblk -e 7 -o NAME,TYPE,SIZE,MODEL,FSTYPE,UUID,MOUNTPOINT
else echo 'NOT TESTED: lsblk unavailable'; fi
section 'ACTIVE MOUNTS'
if command -v findmnt >/dev/null 2>&1; then
  findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS | awk '$2=="/" || $2 ~ /^\/mnt\// || $2 ~ /^\/opt\/hanwha\//'
else echo 'NOT TESTED: findmnt unavailable'; fi
section 'ARCHIVE FSTAB ENTRIES (READ ONLY)'
if [[ -r /etc/fstab ]]; then
  awk 'BEGIN{print "SOURCE TARGET TYPE OPTIONS"} /^[[:space:]]*#/ || NF<4 {next} {if ($2 ~ /^\/mnt\// || tolower($2) ~ /hanwha|wave/ || $1 ~ /^UUID=/ || $1 ~ /^\/dev\/sd/) print $1,$2,$3,$4}' /etc/fstab
else echo 'NOT TESTED: Cannot read fstab'; fi
section 'WAVE SERVICE'
if command -v systemctl >/dev/null 2>&1; then
  run systemctl is-active hanwha-mediaserver.service
  run systemctl is-enabled hanwha-mediaserver.service
  run systemctl show hanwha-mediaserver.service -p ActiveState -p SubState -p UnitFileState -p ExecMainStartTimestamp
else echo 'NOT TESTED: systemctl unavailable'; fi
section 'WAVE DATA DIRECTORY (METADATA ONLY)'
for d in /opt/hanwha/mediaserver/var/data /mnt/sda /mnt/sda1 /mnt/sdb /mnt/sdb1 /mnt/sdc /mnt/sdc1 /mnt/sdd /mnt/sdd1; do
  if [[ -d "$d" ]]; then
    printf 'Directory: %s\n' "$d"
    if command -v findmnt >/dev/null 2>&1; then findmnt -T "$d" -n -o SOURCE,TARGET,FSTYPE 2>&1 || true; fi
  fi
done
section 'JOURNAL STORAGE'
if command -v journalctl >/dev/null 2>&1; then run journalctl --disk-usage; else echo 'NOT TESTED: journalctl unavailable'; fi
section 'JOURNAL CONFIGURATION'
if [[ -r /etc/systemd/journald.conf ]]; then
  grep -HnE '^[[:space:]]*(Storage|SystemMaxUse|SystemKeepFree|RuntimeMaxUse)=' /etc/systemd/journald.conf || true
fi
if [[ -d /etc/systemd/journald.conf.d ]]; then
  for f in /etc/systemd/journald.conf.d/*.conf; do
    [[ -f "$f" && -r "$f" ]] || continue
    grep -HnE '^[[:space:]]*(Storage|SystemMaxUse|SystemKeepFree|RuntimeMaxUse)=' "$f" || true
  done
fi
section 'SNAP INVENTORY'
if command -v snap >/dev/null 2>&1; then
  run snap list --all
  section 'SNAP TRANSACTIONS'
  run snap changes
else echo 'Snap not installed'; fi
section 'SYSTEMD GLOBAL TIMEOUT SETTINGS'
for f in /etc/systemd/system.conf /etc/systemd/system.conf.d/*.conf; do
  [[ -f "$f" && -r "$f" ]] || continue
  grep -HnE '^[[:space:]]*Default(TimeoutStartSec|TimeoutStopSec)=' "$f" || true
done
section 'DISK HEALTH TOOL AVAILABILITY'
if command -v smartctl >/dev/null 2>&1; then echo 'smartctl available (SMART probing intentionally omitted; may require device-specific selection)'; else echo 'smartctl not installed'; fi
section 'FINAL SUMMARY'
run df -hT /
if command -v systemctl >/dev/null 2>&1; then run systemctl is-active hanwha-mediaserver.service; fi
printf '\nINSPECTION COMPLETED. Report: %s\n' "$REPORT"
printf 'Review required: inspection does not prove cameras are recording or playback is working.\n'
# <<< ORIGINAL
)

# ---- OS-drive space breakdown (carried over from wrn_remaining_os_space.sh) ----
diag_space() (
# >>> ORIGINAL wrn_remaining_os_space.sh:4-6
set -u
export LC_ALL=C
umask 077
# <<< ORIGINAL
# >>> ORIGINAL wrn_remaining_os_space.sh:8-39
(( EUID == 0 )) || { echo 'Run with sudo' >&2; exit 2; }
[[ -r /etc/os-release ]] || exit 2
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 22.04 ]] || { echo 'Ubuntu 22.04 required' >&2; exit 2; }
OUTDIR=/home/wave/Downloads/maintenance
[[ -d "$OUTDIR" && ! -L "$OUTDIR" ]] || { echo "STOP: $OUTDIR unavailable" >&2; exit 2; }
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$OUTDIR/WRN-Remaining-OS-Space_${STAMP}_$$.txt"
( set -C; : > "$REPORT" ) || exit 2
chmod 600 "$REPORT"
section(){ printf '\n===== %s =====\n' "$1" >> "$REPORT"; }
run(){ local label="$1" seconds="$2"; shift 2; section "$label"; timeout -k 2s "${seconds}s" "$@" >> "$REPORT" 2>&1; local rc=$?; if ((rc)); then echo "[command status=$rc; information may be incomplete]" >> "$REPORT"; fi; }
section 'IDENTIFICATION AND LIMITS'
printf 'UTC: %s\nHostname: %s\nUbuntu: %s\nRead-only system inspection. No deletion, package commands, service operations or mount operations.\n' "$(date -u -Is)" "$(hostname -s)" "${PRETTY_NAME:-unknown}" >> "$REPORT"
run 'OS FILESYSTEM' 8 df -hT /
run 'FILESYSTEM AND MOUNT MAP' 10 lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,RO
run 'ARCHIVE MOUNT' 8 bash -c 'findmnt -M /mnt/sda || echo "NOT MOUNTED"; findmnt -T /opt/hanwha/mediaserver/var/data || true'
run 'WAVE SERVICE' 8 bash -c 'systemctl is-active hanwha-mediaserver.service; systemctl show hanwha-mediaserver.service -p ActiveEnterTimestamp -p NRestarts'
run 'ROOT DIRECTORIES >= 1GiB ACTUAL DISK BLOCKS' 45 bash -c 'du -x -B1 -d1 / 2>/dev/null | awk '\''$1>=1073741824 {printf "%.2f GiB %s\n",$1/1073741824,$2}'\'' | sort -nr'
run 'VAR OPT HOME SUBDIRECTORIES >= 1GiB' 60 bash -c 'for d in /var /opt /home; do du -x -B1 -d2 "$d" 2>/dev/null; done | awk '\''$1>=1073741824 {printf "%.2f GiB %s\n",$1/1073741824,$2}'\'' | sort -nr | head -80'
run 'LARGE OS-RESIDENT FILES >= 1GiB ALLOCATED (NO CONTENT READ)' 60 bash -c 'find /var /opt /home -xdev -type f -printf "%b %s %TY-%Tm-%Td %p\n" 2>/dev/null | awk '\''$1*512>=1073741824 {printf "%.2f GiB allocated / %.2f GiB apparent / %s %s\n",$1*512/1073741824,$2/1073741824,$3,$4}'\'' | sort -nr | head -80'
run 'CORE DUMPS (METADATA ONLY, INCLUDING SPARSE FILES)' 30 bash -c 'find /home/wave -maxdepth 2 -type f \( -name core -o -name "core.*" \) -print0 2>/dev/null | xargs -0 -r stat -c "path=%n owner=%U modified=%y apparent_bytes=%s allocated_blocks_512=%b inode=%i"'
run 'CORE FILE TYPES (NO FILE CONTENT DUMP)' 30 bash -c 'find /home/wave -maxdepth 1 -type f \( -name core -o -name "core.*" \) -print0 2>/dev/null | xargs -0 -r file --'
run 'SNAP STORAGE' 15 bash -c 'for p in /var/lib/snapd /var/lib/snapd/seed /var/lib/snapd/snaps /var/snap /home/wave/snap; do [[ ! -e "$p" ]] || du -shx "$p" 2>&1; done; if command -v snap >/dev/null; then timeout -k 2s 8s snap list --all || echo "SNAP INVENTORY UNAVAILABLE"; fi'
run 'PACKAGE STATE (NO CHANGES)' 12 bash -c 'dpkg-query -W snapd firefox google-chrome-stable gdm3 gnome-shell ubuntu-desktop 2>&1 || true; dpkg --audit'
run 'WAVE DATA AND DATABASE SIZE (NEVER DELETE)' 20 bash -c 'for p in /opt/hanwha/mediaserver/var/data /opt/hanwha/mediaserver/var; do [[ ! -d "$p" ]] || { du -shx "$p" 2>&1; findmnt -T "$p" -o TARGET,SOURCE,FSTYPE; }; done; find /opt/hanwha/mediaserver/var -xdev -type f \( -name "*.sqlite-wal" -o -name "*.sqlite" -o -name "*.nxdb" \) -size +1023M -printf "%s bytes %p\n" 2>/dev/null | head -40'
run 'LARGE LOGS AND JOURNAL' 16 bash -c 'journalctl --disk-usage; find /var/log -xdev -type f -size +1023M -printf "%s bytes %p\n" 2>/dev/null'
section 'SAFETY SUMMARY'
printf 'REPORT ONLY. Do not delete SQLite/WAL, WAVE recordings, indexes, or metadata.\nDo not remove Snap automatically. Archive and recording health must be verified in WAVE client.\n' >> "$REPORT"
chown wave:wave "$REPORT" 2>/dev/null || chmod 644 "$REPORT"
chmod 640 "$REPORT" 2>/dev/null || true
printf 'READ-ONLY WRN OS space report saved:\n%s\n' "$REPORT"
# <<< ORIGINAL
)

# ---- Video written to the OS drive, read-only (carried over from wrn_archive_spillover.sh) ----
diag_spillover() (
# >>> ORIGINAL wrn_archive_spillover.sh:4-5
set -Eeuo pipefail
export LC_ALL=C
# <<< ORIGINAL
  MODE=--audit
# >>> ORIGINAL wrn_archive_spillover.sh:8-44
[[ ${EUID:-$(id -u)} == 0 ]] || { echo 'STOP: sudo required' >&2; exit 2; }
DATA=/opt/hanwha/mediaserver/var/data
REPORT_DIR=/home/wave/Downloads/maintenance
[[ -d $REPORT_DIR && ! -L $REPORT_DIR ]] || { echo 'STOP: reports folder unavailable' >&2; exit 1; }
REPORT="$REPORT_DIR/WRN-Archive-Spillover_$(date -u +%Y%m%dT%H%M%SZ)_$$.txt"
: > "$REPORT" && chmod 644 "$REPORT"
exec > >(tee -a "$REPORT") 2>&1
printf '=== WAVE OS SPILLOVER AUDIT (READ-ONLY; %s) ===\n' "$MODE"
echo "Report: $REPORT"
[[ -d $DATA && ! -L $DATA ]] || { echo "NOTICE: WAVE data root not present as regular directory: $DATA"; exit 0; }
osdev=$(stat -c %d /)
datadev=$(stat -c %d "$DATA")
if [[ $datadev != "$osdev" ]]; then
  echo 'STOP: WAVE data root not on OS filesystem; do not assume spillover source'; exit 1
fi
shopt -s nullglob
found=0
bytes=0
for server in "$DATA"/*; do
  [[ -d $server && ! -L $server ]] || continue
  [[ $(stat -c %d "$server") == "$osdev" ]] || { echo "SKIP: not on OS filesystem $server"; continue; }
  for quality in hi_quality low_quality; do
    qpath="$server/$quality"
    [[ -d $qpath && ! -L $qpath ]] || continue
    [[ $(stat -c %d "$qpath") == "$osdev" ]] || continue
    while IFS= read -r -d '' year; do
      [[ -d $year && ! -L $year && $(stat -c %d "$year") == "$osdev" ]] || continue
      # Calculate allocated bytes using du -s -B1 confined to the source filesystem.
      size=$(du -sx -B1 "$year" 2>/dev/null | awk 'NR==1 {print $1}')
      [[ $size =~ ^[0-9]+$ ]] || { echo "WARNING: cannot size $year"; continue; }
      printf 'OS RECORDINGS: %12s bytes  %s\n' "$size" "$year"
      (( found+=1 )); bytes=$((bytes+size))
    done < <(find "$qpath" -xdev -mindepth 2 -maxdepth 2 -type d -name '20[0-9][0-9]' -print0 2>/dev/null)
  done
done
printf 'TOTAL: %s dated directories; %s allocated bytes on OS filesystem\n' "$found" "$bytes"
echo '=== POSSIBLE DESTINATIONS (INFORMATIONAL ONLY) ==='
# <<< ORIGINAL
  echo 'NOTE: WAVE keeps ~30 GB free on archive drives by design. The headroom figures below are only about'
  echo '      relocating OS-drive video; they are NOT a low-disk-space warning for the archive.'
# >>> ORIGINAL wrn_archive_spillover.sh:45-78
for mp in /mnt/sda /mnt/sdb /mnt/sdc /mnt/sdd; do
  if ! findmnt -rn -M "$mp" >/dev/null 2>&1; then echo "$mp: not mounted"; continue; fi
  fs=$(findmnt -rn -M "$mp" -o FSTYPE)
  mountopts=$(findmnt -rn -M "$mp" -o OPTIONS)
  [[ $fs == ext4 && ,$mountopts, == *,rw,* ]] || { echo "$mp: NOT ELIGIBLE (not rw ext4)"; continue; }
  # Insist destination really is a different mounted filesystem from /.
  [[ $(stat -c %d "$mp") != "$osdev" ]] || { echo "$mp: NOT ELIGIBLE (same OS filesystem)"; continue; }
  read -r total avail < <(df -B1 --output=size,avail "$mp" | awk 'NR==2 {print $1,$2}')
  [[ $total =~ ^[0-9]+$ && $avail =~ ^[0-9]+$ ]] || { echo "$mp: cannot determine free space"; continue; }
  # Conservative extra reserve; VMS can need considerably more and recycle constantly.
  reserve=$((50 * 1024 * 1024 * 1024))
  headroom=$(( avail > reserve ? avail - reserve : 0 ))
  printf '%s: free=%s bytes  conservative non-VMS headroom=%s bytes' "$mp" "$avail" "$headroom"
  if (( bytes > 0 && bytes <= headroom )); then echo '  CAPACITY MAY BE SUFFICIENT (NOT APPROVED FOR MOVE)';
  elif (( bytes > 0 )); then echo '  INSUFFICIENT HEADROOM';
  else echo '  no OS recording data identified'; fi
done
if (( found )); then
  cat <<'WARNING'
WARNING: Video chunks are indexed by WAVE to a physical storage path.
Moving or copying chunks can make timeline video unavailable until a supported
archive reindex is performed. A running WAVE server may recycle files during a
copy; full destination disks may recycle old footage to maintain recordings.
Do NOT move, delete, overwrite or reindex from this script. Coordinate with
Hanwha/WAVE support, preserve existing footage, confirm destination path format
and free-space headroom, arrange a maintenance window, and validate playback.
WARNING
else
  echo 'No standard dated hi_quality/low_quality OS video folders detected; other WAVE metadata and unrecognized archive layouts are not classified.'
fi
if [[ $MODE == --plan-move ]]; then
  echo 'PLAN ONLY: dev.19 intentionally does not implement migration or select a destination.'
fi
echo 'AUDIT COMPLETE: no media files modified.'
# <<< ORIGINAL
  echo; echo 'WAVE ANALYTICS STORAGE CHECK:'
  metadata_location_check
)

MODE=--full
if (( $# > 1 )); then usage >&2; exit 2; fi
[[ $# -eq 0 ]] || MODE="$1"
case "$MODE" in
  --version) echo "$WRN_SCRIPT_VERSION"; exit 0 ;;
  --help|-h) usage; exit 0 ;;
  --quick) diag_quick; exit $? ;;
  --full|--space|--spillover|--metadata) ;;
  *) usage >&2; exit 2 ;;
esac
[[ -r /etc/os-release ]] || { echo 'ERROR: cannot detect OS' >&2; exit 2; }
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || { echo "STOP: unsupported OS: ${PRETTY_NAME:-unknown}" >&2; exit 2; }
(( EUID == 0 )) || { echo 'Run with sudo (only --quick works without root)' >&2; exit 2; }
case "${VERSION_ID:-}:$MODE" in
  18.04:--full) diag_legacy ;;
  22.04:--full) diag_full_2204 ;;
  22.04:--space) diag_space ;;
  22.04:--spillover) diag_spillover ;;
  22.04:--metadata) metadata_location_check ;;
  18.04:*) echo "STOP: $MODE is for Ubuntu 22.04 recorders. On this Ubuntu 18.04 recorder use --full or --quick." >&2; exit 2 ;;
  *) echo "STOP: unsupported Ubuntu release: ${VERSION_ID:-unknown}" >&2; exit 2 ;;
esac
