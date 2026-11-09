#!/usr/bin/env bash
# WRN Legacy Maintenance 2.0.0-rc.6 - the ONE command a technician runs on a Hanwha Gen 1 WRN (Ubuntu 18.04).
# NOTICE: This is an independent field-support tool, developed through hands-on testing on Hanwha WRN
# recorders. It is NOT an official Hanwha product and is NOT supported by Hanwha. It is provided as-is,
# based on real-world field experience. Use it at your own discretion and judgment.
#
# TECHNICIANS TYPE NO OPTIONS. Run it with nothing after the name; it looks, explains, asks one yes/no, fixes, reports.
#   sudo bash wrn_legacy_maintenance.sh     (if you forget sudo it asks for your password and carries on)
# Engineering/support only (never shown to technicians):
#   --check   look and report only; changes nothing
#   --apply   apply without asking (the field-proven RC1 habit)
#
# This does ONLY what the field-proven WRN_Gen1_Journal_Snap_RC1 script does (carried over byte-for-byte below,
# verified against reference/WRN_Gen1_Journal_Snap_RC1.sh by tools/build.py --check):
#   1. limit the system log (500 MB max, keep 1 GB free), back up the previous setting, trim old log history;
#   2. remove Snap revisions that are marked disabled (each one re-checked just before it is removed).
# It NEVER stops or restarts WAVE, never touches recordings, archive drives, mounts, fstab or the network, and never
# reboots. The only service restarted is the system log service (journald), only to load the new limit.
# Gen 1 (Ubuntu 18.04) only. A Gen 2 recorder is refused (use wrn_maintenance.sh there).
set -u
export LC_ALL=C
umask 077
VERSION='2.0.0-rc.6'
WRN_SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"

usage() {
  printf 'WRN Legacy Maintenance %s\n' "$VERSION"
  printf 'Usage: sudo bash wrn_legacy_maintenance.sh [--check | --apply | --version | --help]\n'
  printf '  (no option)  Check the recorder, explain what it found, ask once, then fix and report.\n'
  printf '  --check      Look and report only. Changes nothing.\n'
  printf '  --apply      Apply the fixes without asking.\n'
  printf 'Uses only on an authorized Gen 1 WRN (Ubuntu 18.04). A STOP is a safeguard: save the output and escalate.\n'
}

GEN2_STOP='STOP: this is not an Ubuntu 18.04 (Gen 1) recorder. This tool is for Gen 1 recorders only; on a Gen 2 recorder use wrn_maintenance.sh.'
is_gen1() { [[ "$(. /etc/os-release 2>/dev/null; echo "${ID:-}:${VERSION_ID:-}")" == ubuntu:18.04 ]]; }

ORIG_ARGS=("$@")
case "${1:-}" in
  '') MODE=guided ;;
  --check) MODE=--check ;;
  --apply) MODE=--apply ;;
  --version) [[ $# -eq 1 ]] || exit 2; printf '%s\n' "$VERSION"; exit 0 ;;
  --help|-h) usage; exit 0 ;;
  *) if is_gen1; then usage >&2; else echo "$GEN2_STOP" >&2; fi; exit 2 ;;
esac
[[ $# -le 1 ]] || { if is_gen1; then usage >&2; else echo "$GEN2_STOP" >&2; fi; exit 2; }
[[ -r /etc/os-release ]] || { echo 'STOP: cannot read OS information' >&2; exit 2; }
# shellcheck disable=SC1091
. /etc/os-release
VERSION='2.0.0-rc.6'   # os-release also defines VERSION (the OS release text); keep this tool's own version
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 18.04 ]] || { echo "$GEN2_STOP" >&2; exit 2; }
if [[ $EUID -ne 0 ]]; then
  # A technician who forgot sudo should not have to retype anything.
  if command -v sudo >/dev/null 2>&1; then
    echo 'This needs administrator rights. Asking for your password...'
    exec sudo bash "$WRN_SELF" "${ORIG_ARGS[@]}"
  fi
  echo 'STOP: administrator rights are required and sudo is not available.' >&2; exit 2
fi

# ---- RC1 start-up, report file and diagnostics: carried over unchanged ----
# >>> ORIGINAL reference/WRN_Gen1_Journal_Snap_RC1.sh:24-26
for cmd in timeout df du journalctl findmnt systemctl awk date hostname lsblk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing $cmd" >&2; exit 2; }
done
# <<< ORIGINAL
# >>> ORIGINAL reference/WRN_Gen1_Journal_Snap_RC1.sh:27-37
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
# <<< ORIGINAL
# >>> ORIGINAL reference/WRN_Gen1_Journal_Snap_RC1.sh:38-45
section() { printf '\n===== %s =====\n' "$1" >> "$REPORT"; }
run() {
  local label="$1" seconds="$2"; shift 2
  section "$label"
  timeout -k 2s "${seconds}s" "$@" >> "$REPORT" 2>&1
  local rc=$?
  if (( rc != 0 )); then printf '[command exit status %d; incomplete or unavailable]\n' "$rc" >> "$REPORT"; fi
}
# <<< ORIGINAL
# >>> ORIGINAL reference/WRN_Gen1_Journal_Snap_RC1.sh:46-64
section 'REPORT INFORMATION'
printf 'WRN Legacy: %s\nMode: %s\nOS: %s\nUTC: %s\nHostname: %s\n' "$VERSION" "$MODE" "$PRETTY_NAME" "$(date -u -Is)" "$HOST" >> "$REPORT"
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
# <<< ORIGINAL
# NEW IN 2.0.0 (owner request, report only): journal folders of other machine ids
other_journals_section() { section 'JOURNAL FOLDERS OF OTHER MACHINE IDS (REPORT ONLY)'; other_journals_report >> "$REPORT"; }

# ---- The fixes: RC1's apply block, unchanged except ONE owner-approved line (see sed): the exact Snap message
# "error: no changes found" (a box with no Snap history) now means "no active transaction"; every other
# error still skips the Snap cleanup. Runs in a subshell so a STOP in it ends only the fixes. ----
apply_changes() (
# >>> ORIGINAL reference/WRN_Gen1_Journal_Snap_RC1.sh:67-147 sed:s/if (( changes_rc != 0 )); then/if (( changes_rc != 0 )) \&\& [[ "$changes" != 'error: no changes found' ]]; then/
  section 'GEN1 MAINTENANCE APPLY'
  echo '=== GEN 1 LOG AND SNAP MAINTENANCE ==='
  echo 'No WAVE stop, recording deletion, archive mount edits, or reboot.'
  df -h / | tee -a "$REPORT"
  # Bound the persistent journal first. Preserve any prior managed file.
  confdir=/etc/systemd/journald.conf.d
  conf="$confdir/90-wrn-legacy-limits.conf"
  mkdir -p "$confdir" || { echo 'STOP: cannot create journald directory'; exit 1; }
  if [[ -L "$conf" || ( -e "$conf" && ! -f "$conf" ) ]]; then
    echo 'STOP: managed journal configuration is not a regular file' | tee -a "$REPORT"; exit 1
  fi
  if [[ -f "$conf" ]]; then
    cp -a "$conf" "$conf.bak.$STAMP.$$" || { echo 'STOP: cannot back up journal settings'; exit 1; }
  fi
  tmp="$(mktemp "$confdir/.wrn-legacy.XXXXXXXX")" || exit 1
  cat > "$tmp" <<'CONF'
[Journal]
SystemMaxUse=500M
SystemKeepFree=1G
CONF
  chmod 644 "$tmp"
  chown root:root "$tmp"
  if [[ -f "$conf" ]] && cmp -s "$tmp" "$conf"; then
    rm -f "$tmp"
    echo 'Journal limits already configured.' | tee -a "$REPORT"
  else
    mv -f "$tmp" "$conf" || { echo 'STOP: cannot install journal limits'; exit 1; }
    echo "Installed journal limits: $conf" | tee -a "$REPORT"
    # Restart journald only to load config. Does not restart Hanwha/WAVE.
    if ! systemctl restart systemd-journald.service; then
      echo 'STOP: journald could not reload its limits; inspect service' | tee -a "$REPORT"
      exit 1
    fi
  fi
  echo 'Rotating system journals and retaining approximately 500 MB of archived history...' | tee -a "$REPORT"
  if ! journalctl --rotate >> "$REPORT" 2>&1; then
    echo 'STOP: journal rotation failed' | tee -a "$REPORT"; exit 1
  fi
  if ! journalctl --vacuum-size=500M >> "$REPORT" 2>&1; then
    echo 'STOP: journal vacuum failed' | tee -a "$REPORT"; exit 1
  fi
  journalctl --disk-usage | tee -a "$REPORT"

  echo '=== INACTIVE SNAP REVISION CLEANUP ===' | tee -a "$REPORT"
  if ! command -v snap >/dev/null 2>&1; then
    echo 'SKIP: Snap CLI absent' | tee -a "$REPORT"
  else
    # Skip safely on any failed/unavailable or active transaction inventory.
    changes="$(timeout 20 snap changes 2>&1)"
    changes_rc=$?
    if (( changes_rc != 0 )) && [[ "$changes" != 'error: no changes found' ]]; then
      echo 'SKIP: unable to verify Snap transaction state' | tee -a "$REPORT"
    elif printf '%s\n' "$changes" | awk 'NR>1 && ($2=="Doing" || $2=="Undoing" || $2=="Hold") {active=1} END{exit !active}'; then
      echo 'SKIP: Snap operation in progress' | tee -a "$REPORT"
    else
      listing="$(timeout 20 snap list --all 2>&1)"
      listing_rc=$?
      if (( listing_rc != 0 )); then
        echo 'SKIP: cannot list Snap revisions' | tee -a "$REPORT"
      else
        while read -r package revision; do
          [[ -n "$package" && "$revision" =~ ^[0-9]+$ ]] || continue
          # Confirm the specific revision remains disabled immediately prior to removal.
          current="$(timeout 20 snap list --all "$package" 2>/dev/null)" || {
            echo "SKIP: cannot verify $package revision $revision" | tee -a "$REPORT"; continue;
          }
          if ! printf '%s\n' "$current" | awk -v n="$package" -v r="$revision" 'NR>1 && $1==n && $3==r && $0 ~ /disabled/ {found=1} END{exit !found}'; then
            echo "SKIP: $package revision $revision no longer disabled" | tee -a "$REPORT"
            continue
          fi
          echo "Removing disabled Snap: $package revision $revision" | tee -a "$REPORT"
          if ! timeout 180 snap remove "$package" --revision="$revision" >> "$REPORT" 2>&1; then
            echo "WARNING: Snap removal failed for $package $revision; remaining revisions skipped" | tee -a "$REPORT"
            break
          fi
        done < <(printf '%s\n' "$listing" | awk 'NR>1 && /disabled/ {print $1,$3}')
      fi
    fi
  fi
  echo '=== GEN 1 MAINTENANCE COMPLETE ===' | tee -a "$REPORT"
  df -h / | tee -a "$REPORT"
# <<< ORIGINAL
)

# ---- RC1 closing notes in the report: carried over unchanged ----
write_notes() {
# >>> ORIGINAL reference/WRN_Gen1_Journal_Snap_RC1.sh:149-158
section 'SAFETY AND LIMITATIONS'
cat >> "$REPORT" <<'NOTES'
Diagnostic mode is read-only. Apply mode changes only journal limits, archives journal history,
and removes explicitly disabled Snap revisions. No WAVE restart, network service changes, mount actions, repairs, or reboot.
SMART health and filesystem checks are not performed by this legacy build.
An absent/healthy mount or active service does not prove WAVE is successfully recording.
Older journal entries may be missing due to prior cleanup. Verify recording in WAVE client.
Report can contain identifying system details; do not post publicly.
NOTES
if [[ "$OWNER" != root ]]; then chown "$OWNER" "$REPORT" 2>/dev/null || true; fi
# <<< ORIGINAL
}

# >>> ORIGINAL wrn_maintenance.sh:1092-1107
tech_prompt() {
  local question="$1" response
  if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    echo "STOP: interactive confirmation required: $question (no terminal available)" >&2
    return 2
  fi
  while true; do
    printf '\n%s [Y/N]: ' "$question" > /dev/tty
    IFS= read -r response < /dev/tty || { echo 'STOP: confirmation input unavailable'; return 2; }
    case "${response,,}" in
      y|yes) return 0 ;;
      n|no) echo 'DECLINED: no action taken for this choice.'; return 1 ;;
      *) printf 'Please enter Y or N.\n' > /dev/tty ;;
    esac
  done
}
# <<< ORIGINAL

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

# ======================= look (read-only) =======================
say() { printf '  [%-5s] %s\n' "$1" "$2"; }
JOURNAL_CONF=/etc/systemd/journald.conf.d/90-wrn-legacy-limits.conf
journal_token() { journalctl --disk-usage 2>/dev/null | sed -nE 's/.*take up ([0-9.]+[BKMGT]?) .*/\1/p' | head -1; }
token_bytes() { awk -v t="$1" 'BEGIN{ n=t+0; u=substr(t,length(t),1); m=(u=="K")?1024:(u=="M")?1048576:(u=="G")?1073741824:(u=="T")?1099511627776:1; printf "%d\n", n*m }'; }
NEED_JOURNAL=0; NEED_SNAP=0

assess() {
  local jtok jbytes disabled usage limit oj ojd ojb
  NEED_JOURNAL=0; NEED_SNAP=0
  printf '\n=== WHAT I FOUND (read-only) ===\n'
  printf 'Recorder: %s   OS drive: %s\n' "$(hostname -s)" "$(df -h / | awk 'NR==2{print $5 " used, " $4 " free"}')"
  jtok="$(journal_token)"; jbytes=0; [[ -n "$jtok" ]] && jbytes="$(token_bytes "$jtok")"
  if [[ -n "$jtok" ]]; then say NOTE "The system log is using $jtok."; else say NOTE "Could not read the size of the system log."; fi
  # Once the limit is set, journald keeps the log near 500 MB itself; a trim can leave it a little over (the
  # active file is not trimmed), so only a clear overshoot (500 MB + one 128 MB journal file) counts as "too big".
  limit=524288000
  if printf '[Journal]\nSystemMaxUse=500M\nSystemKeepFree=1G\n' | cmp -s - "$JOURNAL_CONF" 2>/dev/null; then
    say OK "The system log size limit is already set (500 MB, keeps 1 GB free)."
    limit=$((524288000 + 134217728))
  else
    say FIX "The system log has no size limit set by this tool. Will set it to 500 MB and keep 1 GB free (previous setting backed up)."
    NEED_JOURNAL=1
  fi
  if (( jbytes > limit )); then
    say FIX "The system log history is larger than 500 MB. Will trim it to about 500 MB."
    NEED_JOURNAL=1
  fi
  oj="$(other_journals_report | grep -E '^OTHER_MACHINE_ID_JOURNALS')"; ojd="${oj#*dirs=}"; ojd="${ojd%% *}"; ojb="${oj#*bytes=}"; ojb="${ojb%% *}"
  if [[ "$ojd" =~ ^[0-9]+$ && "$ojd" -gt 0 ]]; then
    say NOTE "Found $ojd old log folder(s) from other machine identities (likely the factory image), $(numfmt --to=iec --suffix=B "$ojb" 2>/dev/null || echo "$ojb bytes"), in /var/log/journal. The log limit does not cover them. Report only: nothing is deleted."
  fi
  if ! command -v snap >/dev/null 2>&1; then
    say NOTE "Snap is not installed; nothing to clean."
  elif ! disabled="$(timeout 20 snap list --all 2>/dev/null)"; then
    say NOTE "Could not read the Snap list; Snap clean-up will be skipped."
  else
    disabled="$(printf '%s\n' "$disabled" | awk 'NR>1 && /disabled/ {n++} END{print n+0}')"
    if (( disabled > 0 )); then
      say FIX "$disabled old (disabled) Snap revision(s) can be removed. Each is re-checked just before it is removed."
      NEED_SNAP=1
    else
      say OK "No old (disabled) Snap revisions to remove."
    fi
  fi
  if [[ "$(systemctl is-active hanwha-mediaserver.service 2>/dev/null)" == active ]]; then
    say OK "WAVE is running. This tool never stops or restarts it."
  else
    say NOTE "WAVE is not running. This tool does not start or stop it."
  fi
  usage="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
  if [[ "$usage" =~ ^[0-9]+$ ]] && (( usage >= 80 )); then say NOTE "OS drive is ${usage}% full."; fi
}

# ======================= main =======================
other_journals_section
printf '=== WRN LEGACY MAINTENANCE %s (Gen 1) ===\n' "$VERSION"
assess
printf '\nReport: %s\n' "$REPORT"
if [[ "$MODE" == --check ]]; then
  write_notes
  echo; echo 'Look only: nothing was changed.'; exit 0
fi
if [[ "$MODE" == guided ]]; then
  if (( ! NEED_JOURNAL && ! NEED_SNAP )); then
    write_notes
    echo; echo 'RESULT: nothing needs fixing. Nothing was changed.'; exit 0
  fi
  printf '\n=== PLANNED CHANGES ===\n'
  (( NEED_JOURNAL )) && echo '  - Set the system log limit and trim old log history (only the log service is restarted, briefly).'
  (( NEED_SNAP )) && echo '  - Remove old, disabled Snap revisions.'
  echo '  Nothing here stops WAVE, touches recordings or archive drives, or reboots the recorder.'
  tech_prompt 'Apply these changes now?' || { write_notes; echo 'RESULT: nothing was changed.'; exit 0; }
fi
BEFORE="$(df -h / | awk 'NR==2{print $5 " used, " $4 " free"}')"
APPLY_LOG="$(mktemp)"
apply_changes 2>&1 | tee "$APPLY_LOG"; RC=${PIPESTATUS[0]}
write_notes
AFTER="$(df -h / | awk 'NR==2{print $5 " used, " $4 " free"}')"
printf '\n=== RESULT ===\n'
if (( RC == 0 )); then
  if grep -qE '^(SKIP|WARNING)' "$APPLY_LOG"; then
    echo 'RESULT: maintenance finished. Some Snap clean-up was skipped (see the SKIP/WARNING lines above); nothing was harmed.'
  else
    echo 'RESULT: maintenance completed successfully.'
  fi
  echo "OS drive before: $BEFORE"; echo "OS drive after:  $AFTER"
  echo 'Please check in the WAVE client that live view and recording look normal. This tool cannot check that.'
  rm -f "$APPLY_LOG"; echo "Report: $REPORT"; exit 0
fi
echo 'RESULT: maintenance did NOT complete. Nothing further was changed. Save this output and contact support.'
rm -f "$APPLY_LOG"; echo "Report: $REPORT"; exit 1
