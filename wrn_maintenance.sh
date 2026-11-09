#!/usr/bin/env bash
# WRN Maintenance 2.0.0-rc.4 - the ONE command a technician runs on a Hanwha Gen 2 WRN (Ubuntu 22.04).
# NOTICE: This is an independent field-support tool, developed through hands-on testing on Hanwha WRN
# recorders. It is NOT an official Hanwha product and is NOT supported by Hanwha. It is provided as-is,
# based on real-world field experience. Use it at your own discretion and judgment.
#
# TECHNICIANS TYPE NO OPTIONS. Run it with nothing after the name; it asks plain questions (yes/no, or 1/2).
#   sudo bash wrn_maintenance.sh            (if you forget sudo it asks for your password and carries on)
# Engineering/support only (never shown to technicians):
#   --check     look and report only; changes nothing
#   --finalize  tidy the maintenance folder after a verified visit
#   --fresh     skip the "continue / start over" questions and start a new visit
#
# Every fix runs as its own sub-process so one failing step is reported, never silent.
# No WAVE/network restart, remount, fsck, reboot, or video deletion happens here.
# (Archive re-mount lives in wrn_recovery.sh; OS-drive video deletion lives there too.)
WRN_SCRIPT_VERSION='2.0.0-rc.4'
WRN_SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
WRN_DIR=/home/wave/Downloads/maintenance
WRN_STATE="$WRN_DIR/.wrn-visit-state"
WRN_LOCK="$WRN_DIR/.wrn-visit.lock"
SLOTS=(sda sdb sdc sdd)

usage() {
  printf 'WRN Maintenance %s\n' "$WRN_SCRIPT_VERSION"
  printf 'Usage: sudo bash wrn_maintenance.sh [--check | --finalize | --fresh | --version | --help]\n'
  printf '  (no option)  Check the recorder, explain what it found, ask once, then fix and report.\n'
  printf '  --check      Look and report only. Changes nothing.\n'
  printf '  --finalize   After you verified desktop, live recording and playback: tidy the maintenance folder.\n'
  printf '  --fresh      Ignore an interrupted or unfinished earlier visit and start a new one.\n'
  printf 'Uses only on an authorized Gen 2 WRN. A STOP is a safeguard: save the output and escalate.\n'
}

is_gen1() { [[ "$(. /etc/os-release 2>/dev/null; echo "${ID:-}:${VERSION_ID:-}")" == ubuntu:18.04 ]]; }
GEN1_STOP='STOP: this is an Ubuntu 18.04 (Gen 1) recorder. Maintenance is not allowed here; on this Gen 1 recorder run wrn_legacy_maintenance.sh (or wrn_diagnose.sh to only check it).'

ORIG_ARGS=("$@")
MODE=guided; FRESH=0; STAGE_NAME=''
while (( $# )); do
  case "$1" in
    --apply) ;;                      # accepted for old habits: same as no option
    --check) MODE=check ;;
    --finalize) MODE=finalize ;;
    --fresh) FRESH=1 ;;
    --version) echo "$WRN_SCRIPT_VERSION"; exit 0 ;;
    --help|-h) usage; exit 0 ;;
    --stage)
      [[ "${WRN_STAGE_CHILD:-}" == 1 && -n "${2:-}" ]] || { echo 'Internal option; not for direct use.' >&2; exit 2; }
      MODE=stage; STAGE_NAME="$2"; shift ;;
    *) if is_gen1; then echo "$GEN1_STOP" >&2; else usage >&2; fi; exit 2 ;;
  esac
  shift
done
if [[ $EUID -ne 0 ]]; then
  # A technician who forgot sudo should not have to retype anything.
  if command -v sudo >/dev/null 2>&1; then
    echo 'This needs administrator rights. Asking for your password...'
    exec sudo bash "$WRN_SELF" "${ORIG_ARGS[@]}"
  fi
  echo 'STOP: administrator rights are required and sudo is not available.' >&2; exit 2
fi
[[ -r /etc/os-release ]] || { echo 'STOP: cannot read OS information' >&2; exit 2; }
. /etc/os-release
if [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 18.04 ]]; then echo "$GEN1_STOP" >&2; exit 2; fi
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == '22.04' ]] || { echo 'Only Ubuntu 22.04 is supported' >&2; exit 2; }
[[ -d "$WRN_DIR" && ! -L "$WRN_DIR" ]] || { echo 'STOP: maintenance folder must exist and not be a symlink' >&2; exit 2; }
export WRN_REPORT_DIR="$WRN_DIR"

# ==================================================================================================
# CARRIED OVER FROM wrn_maintenance.sh 1.0.0 (guards, KB fixes, finalization). Blocks between the
# ORIGINAL markers are byte-identical to the qualified v1.0.0 code unless a sed is shown.
# ==================================================================================================

# Write audit and maintenance transcript to the operator's Downloads folder.
# >>> ORIGINAL wrn_maintenance.sh:379-391 sed:s/_dev17\.txt/.txt/
maintenance_log_setup() {
  local who="${SUDO_USER:-wave}" home
  home="$(getent passwd "$who" | cut -d: -f6)"
  [[ -n "$home" && -d "$home/Downloads" ]] || { echo 'STOP: Downloads directory unavailable' >&2; return 1; }
  WRN_LOG="$WRN_DIR/WRN-Maintenance_$(hostname -s)_$(date -u +%Y%m%dT%H%M%SZ).txt"
  touch "$WRN_LOG" || return 1
  chmod 644 "$WRN_LOG" || return 1
  if [[ "$who" != root ]]; then
    chown "$who" "$WRN_LOG" || { echo "STOP: cannot grant report access to $who" >&2; return 1; }
  fi
  exec > >(tee -a "$WRN_LOG") 2>&1
  echo "Maintenance build=$WRN_SCRIPT_VERSION, log=$WRN_LOG"
}
# <<< ORIGINAL

# >>> ORIGINAL wrn_maintenance.sh:393-398
safe_state() {
  [[ "$(systemctl is-active hanwha-mediaserver.service 2>/dev/null)" == active ]] || { echo 'STOP: WAVE not active'; return 1; }
  [[ "$(systemctl is-active display-manager.service 2>/dev/null)" == active ]] || { echo 'STOP: desktop manager not active'; return 1; }
  [[ "$(findmnt -rn -M /mnt/sda -o OPTIONS 2>/dev/null)" =~ (^|,)rw(,|$) ]] || { echo 'STOP: archive /mnt/sda not mounted read-write'; return 1; }
  [[ "$(findmnt -rn -o SOURCE /)" == /dev/mmcblk* ]] || { echo 'STOP: unexpected OS drive layout'; return 1; }
}
# <<< ORIGINAL

# >>> ORIGINAL wrn_maintenance.sh:400-430
# Logrotate KB: validate existing logging first; never replace distro configurations.
logging_kb() {
  echo '=== KB LOGGING AUDIT ==='
  if ! rsyslogd -N1 2>&1; then
    echo 'STOP: rsyslog config is invalid; leave configuration untouched for manual diagnosis'
    return 1
  fi
  [[ "$(systemctl is-active rsyslog.service 2>/dev/null)" == active ]] || { echo 'STOP: rsyslog inactive'; return 1; }
  local out
  out="$(mktemp)" || return 1
  if ! logrotate -d /etc/logrotate.conf > "$out" 2>&1; then
    cat "$out"; rm -f "$out"
    echo 'STOP: logrotate config invalid; manual repair required'; return 1
  fi
  echo 'Logrotate config: valid; existing rotation configuration retained.'
  grep -Ei "warning:.*(size|daily|hourly)" "$out" || true
  rm -f "$out"
  # Unlike the original KB, do not recursively chown /etc or delete all large logs.
  # Only rotate approved system logs with their already validated rules.
  local f
  for f in /var/log/syslog /var/log/kern.log; do
    if [[ -f "$f" && $(stat -c %s "$f") -gt 104857600 ]]; then
      echo "Over 100 MiB: $f; requesting normal rotation using installed rules"
      logrotate /etc/logrotate.conf || { echo 'STOP: logrotate unsuccessful'; return 1; }
      break
    fi
  done
  journalctl --vacuum-size=1G || return 1
  journalctl --vacuum-time=7d || return 1
  echo 'KB logging: configuration valid; bounded rotation and journal cleanup completed.'
}
# <<< ORIGINAL

# >>> ORIGINAL wrn_maintenance.sh:531-639
# Snap refresh suspension is deliberately explicit: preventing an update is not the
# same as preventing a user or another process from manually reinstalling a snap.
# Snap refresh --hold=forever is supported on the target snapd; verify the resulting
# setting before deleting cached downloads or considering the Snap stage complete.
snap_refresh_hold() {
  echo '=== SNAP AUTOMATIC REFRESH HOLD ==='
  if ! command -v snap >/dev/null 2>&1; then
    echo 'SKIP: snap not installed'
    return 0
  fi
  echo 'Before (snap refresh --time):'
  snap refresh --time 2>&1 || echo 'WARNING: unable to read refresh schedule before hold'
  echo 'APPLY: request indefinite hold of all automatic Snap refreshes'
  if ! snap refresh --hold=forever; then
    echo 'STOP: failed to request indefinite Snap refresh hold'; return 1
  fi
  echo 'After (snap refresh --time):'
  local schedule
  schedule="$(snap refresh --time 2>&1)" || {
    echo "STOP: could not read Snap refresh schedule after applying hold: $schedule"; return 1;
  }
  echo "$schedule"
  # snap refresh --hold and system refresh.hold are different mechanisms.
  # Explicitly identify the indefinite hold if snapd displays it; otherwise
  # report command success without falsely claiming a parsed confirmation.
  if echo "$schedule" | grep -Eiq '(^|[[:space:]])hold:.*forever|(^|[[:space:]])held:.*forever'; then
    echo 'PASS: indefinite automatic-refresh hold visible in refresh schedule'
  else
    echo 'NOTICE: hold command succeeded, but indefinite hold not independently parsed from this snapd output'
  fi
  echo 'NOTE: holding auto-refresh does not prohibit manual upgrades or reinstallations'
}

snap_cleanup() {
  echo '=== SNAP CLEANUP / STATE AUDIT ==='
  command -v snap >/dev/null 2>&1 || { echo 'Snap not installed; skipping'; return 0; }
  local name rev
  while read -r name rev; do
    [[ -n "${name:-}" && "$rev" =~ ^[0-9]+$ ]] || continue
    case "$name" in
      core20|core22|core24|snapd|firefox|snap-store|snapd-desktop-integration|gnome-42-2204|gnome-46-2404|mesa-2404) ;;
      *) echo "SKIP unapproved disabled revision: $name $rev"; continue ;;
    esac
    if snap list --all "$name" | awk -v r="$rev" 'NR>1 && $3==r && /disabled/ {ok=1} END {exit !ok}'; then
      safe_state || return 1
      echo "Removing disabled Snap: $name revision $rev"
      snap remove "$name" --revision="$rev" --purge || return 1
    fi
  done < <(snap list --all | awk 'NR>1 && /disabled/ {print $1, $3}')
  for name in firefox snap-store snapd-desktop-integration; do
    if snap list "$name" >/dev/null 2>&1; then
      echo "REVIEW: active $name retained; no silent active application removal"
    fi
  done
  if [[ -d /var/lib/snapd/cache ]]; then
    echo "Snap download cache before: $(du -sh /var/lib/snapd/cache 2>/dev/null || true)"
    find /var/lib/snapd/cache -mindepth 1 -maxdepth 1 -type f -delete || return 1
    echo "Snap download cache after: $(du -sh /var/lib/snapd/cache 2>/dev/null || true)"
  fi
  echo 'Failed Snap mount units, if any:'
  systemctl list-units --all --type=mount --state=failed --no-pager | grep 'snap-' || true
  echo 'NOTE: failed Snap units are reported, not blindly reset or deleted.'
  echo 'IMPORTANT: a refresh hold does not prevent manual snap install, apt operations, or other installers.'
}

# ADDITIVE PILOT: remove only the approved Snap applications and their now-unused
# runtimes. Never uninstall snapd/apt packages, touch Snap seed files, or remove
# any unknown Snap. The normal maintenance safety checks remain in force.
snap_active_cleanup_pilot() {
  echo '=== APPROVED ACTIVE SNAP CLEANUP (GUARDED PILOT) ==='
  command -v snap >/dev/null 2>&1 || { echo 'SKIP: snap command unavailable'; return 0; }
  local pkg name remaining
  for pkg in gdm3 gnome-shell google-chrome-stable cockpit; do
    if [[ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)" != 'install ok installed' ]]; then
      echo "STOP SNAP STAGE: protected desktop package missing: $pkg"; return 1
    fi
  done
  safe_state || return 1
  # Any extra Snap application may consume one of the shared runtimes.
  # Skip this optional stage rather than risk removing its dependencies.
  remaining="$(timeout -k 2s 20s snap list 2>/dev/null | awk 'NR>1 {print $1}')" || {
    echo 'STOP SNAP STAGE: unable to enumerate installed Snaps'; return 1;
  }
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    case "$name" in
      firefox|snap-store|snapd-desktop-integration|gnome-3-38-2004|gnome-42-2204|gnome-46-2404|mesa-2404|gtk-common-themes|core20|core22|core24|bare|snapd) ;;
      *) echo "SKIP SNAP STAGE: unrecognized installed Snap $name; manual review required"; return 0 ;;
    esac
  done <<< "$remaining"
  for name in firefox snap-store snapd-desktop-integration \
              gnome-3-38-2004 gnome-42-2204 gnome-46-2404 \
              mesa-2404 gtk-common-themes core20 core22 core24 bare; do
    if snap list "$name" >/dev/null 2>&1; then
      safe_state || return 1
      echo "Removing approved Snap: $name"
      # External timeout protects remote technicians from indefinite Snap hangs.
      if ! timeout -k 10s 180s snap remove --purge "$name"; then
        echo "STOP SNAP STAGE: removal failed/timed out for $name; review logs; no forced deletion"; return 1
      fi
    else
      echo "Already absent: $name"
    fi
  done
  safe_state || return 1
  echo 'Remaining installed Snaps (snapd is deliberately preserved):'
  snap list --all 2>&1 || true
  echo 'ACTIVE SNAP CLEANUP COMPLETE; validate desktop and WAVE client before finalization.'
}
# <<< ORIGINAL

# >>> ORIGINAL wrn_maintenance.sh:642-722
# Automatic post-Snap-removal cleanup. No prompt: this is housekeeping for an
# already-approved maintenance run. Only remove FAILED, INACTIVE snap mount
# definitions that reference a missing image and an entirely uninstalled Snap.
# Never touch active mounts, registered Snap packages, snapd itself or user data.
# A read-only --snap-orphan-audit mode uses exactly the same eligibility rules.
snap_orphan_cleanup() {
  local mode="${1:-audit}" unit fragment what where snap_name revision
  local snap_output candidates=() skipped=0 found=0 original backup state path
  local safe_regex='^/snap/([a-z0-9][a-z0-9-]*)/([0-9]+)$'
  echo "=== SNAP ORPHAN UNIT CLEANUP ($mode) ==="
  command -v snap >/dev/null 2>&1 || { echo 'SKIP: snap CLI unavailable'; return 0; }
  command -v systemctl >/dev/null 2>&1 || { echo 'STOP: systemctl unavailable'; return 1; }
  # Do NOT interpret arbitrary CLI errors as an empty installed Snap registry.
  snap_output="$(timeout -k 2s 20s snap list --all 2>&1)" || {
    echo 'STOP: Snap registry unavailable; cannot safely identify orphans'; return 1;
  }
  if [[ $snap_output != Name\ * && $snap_output != *'No snaps are installed yet'* ]]; then
    echo 'STOP: unexpected snap list response; no orphan changes'; return 1
  fi
  while IFS= read -r unit; do
    [[ $unit == snap-*.mount ]] || continue
    ((found+=1))
    fragment="$(systemctl show "$unit" -p FragmentPath --value 2>/dev/null)" || return 1
    what="$(systemctl show "$unit" -p What --value 2>/dev/null)" || return 1
    where="$(systemctl show "$unit" -p Where --value 2>/dev/null)" || return 1
    if [[ $fragment != "/etc/systemd/system/$unit" || ! -f $fragment || -L $fragment || ! $where =~ $safe_regex ]]; then
      echo "REVIEW: $unit (unexpected unit definition/path)"; ((skipped+=1)); continue
    fi
    snap_name="${BASH_REMATCH[1]}"; revision="${BASH_REMATCH[2]}"
    if [[ $what != "/var/lib/snapd/snaps/${snap_name}_${revision}.snap" ]]; then
      echo "REVIEW: $unit (Snap image does not match mount location)"; ((skipped+=1)); continue
    fi
    if [[ -e $what || -L $what ]] || findmnt -rn -M "$where" >/dev/null 2>&1; then
      echo "PRESERVE: $unit (image exists or mount is active)"; ((skipped+=1)); continue
    fi
    # Preserve ANY revision if its snap name is still registered. This is stricter
    # than merely proving that one particular disabled revision is absent.
    if awk -v n="$snap_name" 'NR>1 && $1==n {exists=1} END {exit !exists}' <<< "$snap_output"; then
      echo "PRESERVE: $unit (Snap $snap_name is registered)"; ((skipped+=1)); continue
    fi
    if [[ $(systemctl show "$unit" -p ActiveState --value 2>/dev/null) != failed ]]; then
      echo "PRESERVE: $unit (not in failed state)"; ((skipped+=1)); continue
    fi
    echo "ORPHAN: $unit  missing-image=$what"
    candidates+=("$unit")
  done < <(systemctl list-units --type=mount --state=failed --plain --no-legend --no-pager 2>/dev/null | awk '$1 ~ /^snap-.*\.mount$/ {print $1}')
  echo "SNAP ORPHANS: ${#candidates[@]} eligible; $skipped preserved/review; $found failed Snap units inspected"
  [[ $mode == apply ]] || { echo 'AUDIT ONLY: no units changed'; return 0; }
  (( ${#candidates[@]} )) || { echo 'PASS: no orphan Snap mount definitions to clean'; return 0; }
  safe_state || return 1
  backup="/etc/systemd/wrn-snap-orphan-backups/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p -m 0700 -- "$backup/units" "$backup/enablement" || return 1
  printf 'WRN orphan Snap unit backup created %s\n' "$(date -Is)" > "$backup/README.txt"
  # Keep original unit definitions AND enablement symlinks for recovery.
  # No shell globs are used for deletion and no files outside /etc/systemd/system
  # are removed. systemctl disable only removes enablement symlinks for that unit.
  for unit in "${candidates[@]}"; do
    original="/etc/systemd/system/$unit"
    [[ -f $original && ! -L $original ]] || { echo "STOP: changed unit file $unit"; return 1; }
    [[ $(systemctl show "$unit" -p ActiveState --value) == failed ]] || { echo "STOP: changed mount state $unit"; return 1; }
    what="$(systemctl show "$unit" -p What --value)"
    [[ ! -e $what && ! -L $what ]] || { echo "STOP: image appeared for $unit"; return 1; }
    cp -a -- "$original" "$backup/units/$unit" || return 1
    for path in /etc/systemd/system/*.wants/"$unit"; do
      [[ -L $path ]] || continue
      mkdir -p -- "$backup/enablement/$(basename "$(dirname "$path")")" || return 1
      cp -a -- "$path" "$backup/enablement/$(basename "$(dirname "$path")")/$unit" || return 1
    done
    state="$(systemctl is-enabled "$unit" 2>/dev/null || :)"
    printf '%s\t%s\n' "$unit" "$state" >> "$backup/README.txt"
    echo "CLEAN: $unit (backup first; disable, remove orphan unit only)"
    systemctl disable "$unit" || { echo "STOP: unable to disable $unit"; return 1; }
    mv -- "$original" "$backup/units/$unit.removed" || { echo "STOP: unable to retire $unit"; return 1; }
  done
  # Reset only proven orphan failures while the old names remain addressable.
  # Do not reset unrelated services such as dmesg or DHCP.
  systemctl reset-failed "${candidates[@]}" || return 1
  systemctl daemon-reload || return 1
  echo "PASS: retired ${#candidates[@]} verified orphan Snap mount units; backup=$backup"
  echo 'NOTICE: old per-user Snap autostart entries are separate and not removed.'
}
# <<< ORIGINAL

# >>> ORIGINAL wrn_maintenance.sh:725-777
# A failed dmesg.service often represents the factory 3-second timeout from a
# prior boot. Only retry this one-shot service if the effective manager defaults
# have already been restored. It writes /var/log/dmesg but never touches WAVE,
# disk mounts, recording or networking. No reset-failed needed after success.
# Audit mode is strictly read-only. Failed recovery is WARNING, not a blind reset.
dmesg_service_recovery() {
  local mode="${1:-audit}" state load fragment start_timeout stop_timeout
  local result exec_status status
  echo "=== DMESG SERVICE RECOVERY ($mode) ==="
  command -v systemctl >/dev/null 2>&1 || { echo 'WARNING: systemctl unavailable'; return 0; }
  load="$(systemctl show dmesg.service -p LoadState --value 2>/dev/null || :)"
  state="$(systemctl show dmesg.service -p ActiveState --value 2>/dev/null || :)"
  result="$(systemctl show dmesg.service -p Result --value 2>/dev/null || :)"
  exec_status="$(systemctl show dmesg.service -p ExecMainStatus --value 2>/dev/null || :)"
  fragment="$(systemctl show dmesg.service -p FragmentPath --value 2>/dev/null || :)"
  start_timeout="$(systemctl show -p DefaultTimeoutStartUSec --value 2>/dev/null || :)"
  stop_timeout="$(systemctl show -p DefaultTimeoutStopUSec --value 2>/dev/null || :)"
  printf 'dmesg: load=%s state=%s result=%s exec_status=%s fragment=%s\n' "$load" "$state" "$result" "$exec_status" "$fragment"
  printf 'Effective global timeouts: start=%s stop=%s\n' "$start_timeout" "$stop_timeout"
  if [[ $load != loaded ]]; then
    echo 'REVIEW: dmesg unit unavailable; no action'; return 0
  fi
  if [[ $state != failed ]]; then
    echo 'PASS: dmesg not failed; no restart required'; return 0
  fi
  if [[ $result != timeout ]]; then
    echo "REVIEW: dmesg failed for reason $result, not known factory timeout; no action"; return 0
  fi
  # This pilot only handles the stock 90s service-manager defaults that have
  # been qualified on these WRNs. Unknown overrides stop the automatic retry.
  if [[ $start_timeout != '1min 30s' || $stop_timeout != '1min 30s' ]]; then
    echo 'REVIEW: 90-second effective global timeouts not confirmed; do not retry'; return 0
  fi
  if [[ $fragment != /lib/systemd/system/dmesg.service && $fragment != /usr/lib/systemd/system/dmesg.service ]]; then
    echo 'REVIEW: unexpected dmesg unit path; no action'; return 0
  fi
  [[ $mode == apply ]] || { echo 'AUDIT ONLY: eligible for a single guarded service restart; no changes'; return 0; }
  safe_state || { echo 'WARNING: critical safety guard failed; dmesg retry skipped'; return 0; }
  echo 'APPLY: retry dmesg.service once under corrected systemd timeouts'
  if ! timeout -k 5s 110s systemctl restart dmesg.service; then
    echo 'WARNING: dmesg retry unsuccessful/timed out; original failure evidence retained'
    systemctl show dmesg.service -p ActiveState -p Result -p ExecMainStatus || :
    return 0
  fi
  state="$(systemctl show dmesg.service -p ActiveState --value 2>/dev/null || :)"
  result="$(systemctl show dmesg.service -p Result --value 2>/dev/null || :)"
  exec_status="$(systemctl show dmesg.service -p ExecMainStatus --value 2>/dev/null || :)"
  if [[ $state != failed && $result == success && $exec_status == 0 ]]; then
    echo "PASS: dmesg.service completed successfully; state=$state (inactive is normal for oneshot)"
  else
    echo "WARNING: dmesg restart exited but final status unexpected: state=$state result=$result exec=$exec_status"
  fi
}
# <<< ORIGINAL

# >>> ORIGINAL wrn_maintenance.sh:853-898
final_kb_summary() {
  echo '=== FINAL KB / OPERATIONAL SUMMARY ==='
  if rsyslogd -N1 >/dev/null 2>&1 && [[ "$(systemctl is-active rsyslog.service 2>/dev/null)" == active ]] && logrotate -d /etc/logrotate.conf >/dev/null 2>&1; then
    echo 'PASS KB1: rsyslog operational and logrotate configuration parses'
  else
    echo 'FAIL KB1: logging verification requires investigation'; return 1
  fi
  local source fs uuid entry count
  source="$(findmnt -rn -M /mnt/sda -o SOURCE 2>/dev/null)"
  fs="$(findmnt -rn -M /mnt/sda -o FSTYPE 2>/dev/null)"
  uuid="$(blkid -s UUID -o value "$source" 2>/dev/null)"
  entry="$(awk '$1 !~ /^#/ && $2=="/mnt/sda" {print; exit}' /etc/fstab)"
  count="$(awk '$1 !~ /^#/ && $2=="/mnt/sda" {n++} END {print n+0}' /etc/fstab)"
  if [[ "$count" == 1 && "$fs" == ext4 && -n "$uuid" && "$entry" == "UUID=$uuid "* ]] && [[ "$(findmnt -rn -M /mnt/sda -o OPTIONS)" =~ (^|,)rw(,|$) ]]; then
    if [[ "$entry" != *"x-systemd.device-timeout="* || "$entry" != *"x-systemd.mount-timeout="* ]]; then
      echo 'FAIL KB2: explicit archive timeouts missing'; return 1
    fi
    echo 'PASS KB2: mounted rw ext4 archive matches persistent UUID fstab entry and explicit timeouts' 
  else
    echo 'FAIL KB2: mounted archive and fstab mismatch'; return 1
  fi
  # Report only configured optional archive bays that are actually unmounted.
  # The multi-drive helper has already validated mounted archives separately.
  local optional_bay optional_spec
  for optional_bay in /mnt/sdb /mnt/sdc /mnt/sdd; do
    optional_spec="$(awk -v mp="$optional_bay" '$1 !~ /^#/ && $2 == mp {print $1; exit}' /etc/fstab)"
    if [[ -n "$optional_spec" ]] && ! findmnt -rn -M "$optional_bay" >/dev/null 2>&1; then
      echo "NOTICE KB2: optional archive $optional_bay is configured ($optional_spec) but not mounted; entry preserved"
    fi
  done
  if command -v snap >/dev/null 2>&1; then
    local schedule
    schedule="$(snap refresh --time 2>&1)" || { echo 'WARNING SNAP: refresh hold unverified'; return 1; }
    if grep -Eiq '(^|[[:space:]])hold:.*forever|(^|[[:space:]])held:.*forever' <<< "$schedule"; then
      echo 'PASS SNAP: automatic refresh hold is forever'
    else
      echo 'FAIL SNAP: indefinite refresh hold not verified'; return 1
    fi
  fi
  if [[ "$(systemctl is-active hanwha-mediaserver.service 2>/dev/null)" == active ]]; then
    echo 'PASS WAVE: service active (recording and playback require independent user check)'
  else
    echo 'FAIL WAVE: service not active'; return 1
  fi
  echo 'NOTE: logrotate size/schedule warnings may still exist, and historical alerts may remain in WAVE logs'
}
# <<< ORIGINAL

# NEW IN 2.0.0: the LibreOffice package's own removal script prints harmless 'rmdir: failed to remove /var/lib/libreoffice...' lines; hide only those, keep every other apt line and the real exit status.
# >>> ORIGINAL wrn_maintenance.sh:901-978 sed:s#DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get -y --no-install-recommends purge "${selection\[@\]}"; then#( DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get -y --no-install-recommends purge "${selection[@]}" 2>\&1 | grep -v -E "^rmdir: failed to remove .?/var/lib/libreoffice"; exit "${PIPESTATUS[0]}" ); then#
# --- PILOT: guarded optional application removal (tested on WRN #2). ---
APP_ALLOWED=(libreoffice-common libreoffice-core libreoffice-gnome libreoffice-gtk3 libreoffice-help-common libreoffice-help-da libreoffice-help-en-gb libreoffice-help-en-us libreoffice-help-es libreoffice-help-et libreoffice-help-fi libreoffice-help-fr libreoffice-help-it libreoffice-help-nl libreoffice-help-pl libreoffice-help-pt libreoffice-help-pt-br libreoffice-help-sv libreoffice-help-tr libreoffice-l10n-da libreoffice-l10n-en-gb libreoffice-l10n-en-za libreoffice-l10n-es libreoffice-l10n-et libreoffice-l10n-fi libreoffice-l10n-fr libreoffice-l10n-is libreoffice-l10n-it libreoffice-l10n-lt libreoffice-l10n-lv libreoffice-l10n-nl libreoffice-l10n-nn libreoffice-l10n-pl libreoffice-l10n-pt libreoffice-l10n-pt-br libreoffice-l10n-sv libreoffice-l10n-tr libreoffice-math libreoffice-pdfimport libreoffice-voikko mythes-pl python3-uno thunderbird thunderbird-gnome-support thunderbird-locale-da thunderbird-locale-en thunderbird-locale-en-gb thunderbird-locale-en-us thunderbird-locale-es thunderbird-locale-es-ar thunderbird-locale-es-es thunderbird-locale-et thunderbird-locale-fi thunderbird-locale-fr thunderbird-locale-is thunderbird-locale-it thunderbird-locale-lt thunderbird-locale-lv thunderbird-locale-nl thunderbird-locale-nn thunderbird-locale-nn-no thunderbird-locale-pl thunderbird-locale-pt thunderbird-locale-pt-br thunderbird-locale-pt-pt thunderbird-locale-sv thunderbird-locale-sv-se thunderbird-locale-tr)
LEFT_ALLOWED=(libboost-filesystem1.74.0 libboost-iostreams1.74.0 libboost-locale1.74.0 libboost-thread1.74.0 libclucene-contribs1v5 libclucene-core1v5 libeot0 libexttextcat-2.0-0 libexttextcat-data libgpgmepp6 liblangtag-common liblangtag1 libmessaging-menu0 libmhash2 libmythes-1.2-0 liborcus-0.17-0 liborcus-parser-0.17-0 libraptor2-0 librasqal3 librdf0 libreoffice-style-elementary libreoffice-style-yaru librevenge-0.0-0 libuno-cppu3 libuno-cppuhelpergcc3-3 libuno-purpenvhelpergcc3-3 libuno-sal3 libuno-salhelpergcc3-3 libxmlsec1 libxmlsec1-nss libyajl2 uno-libs-private ure)
PROTECTED_PKGS=(ubuntu-desktop ubuntu-desktop-minimal gnome-shell gdm3 network-manager openssh-server cockpit google-chrome-stable snapd)
APP_RESULT=not-run
LEFT_RESULT=not-run

package_guard() {
  safe_state || return 1
  local pkg status
  for pkg in "${PROTECTED_PKGS[@]}"; do
    status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null || true)"
    [[ "$status" == ii* ]] || { echo "BLOCKED: required package missing: $pkg ($status)"; return 1; }
  done
  [[ -z "$(dpkg --audit 2>/dev/null)" ]] || { echo 'BLOCKED: dpkg audit not clean'; return 1; }
  [[ "$(findmnt -rn -M /mnt/sda -o FSTYPE 2>/dev/null)" == ext4 ]] || return 1
}

# Run a fresh APT simulation and permit removal ONLY if every proposed package
# belongs to an explicitly reviewed package list. No broad autoremove executes.
package_stage() {
  local stage="$1" action="$2"; shift 2
  local sim list approved explicit checked pkg
  sim="$(mktemp)" || return 1
  list="$(mktemp)" || { rm -f "$sim"; return 1; }
  approved="$(mktemp)" || { rm -f "$sim" "$list"; return 1; }
  explicit="$(mktemp)" || { rm -f "$sim" "$list" "$approved"; return 1; }
  checked="$(mktemp)" || { rm -f "$sim" "$list" "$approved" "$explicit"; return 1; }
  echo "=== GUARDED $stage ==="
  if ! package_guard; then echo "SKIP $stage: preflight failure"; rm -f "$sim" "$list" "$approved" "$explicit" "$checked"; return 2; fi
  if [[ "$stage" == APPLICATIONS ]]; then
    printf '%s\n' "${APP_ALLOWED[@]}" | sort -u > "$approved"
    if ! apt-get -s --no-install-recommends purge thunderbird libreoffice-core libreoffice-common > "$sim" 2>&1; then
      echo "SKIP $stage: APT simulation failed"; tail -35 "$sim"; rm -f "$sim" "$list" "$approved" "$explicit" "$checked"; return 2
    fi
  else
    printf '%s\n' "${LEFT_ALLOWED[@]}" | sort -u > "$approved"
    if ! apt-get -s autoremove --purge > "$sim" 2>&1; then
      echo "SKIP $stage: APT simulation failed"; tail -35 "$sim"; rm -f "$sim" "$list" "$approved" "$explicit" "$checked"; return 2
    fi
  fi
  awk '$1=="Purg" {print $2}' "$sim" | sort -u > "$list"
  if grep -Eq '^(Inst|Conf|Remv) ' "$sim"; then
    echo "SKIP $stage: APT proposed non-purge transaction"; rm -f "$sim" "$list" "$approved" "$explicit" "$checked"; return 2
  fi
  if [[ ! -s "$list" ]]; then
    echo "SKIP $stage: nothing left to remove"; rm -f "$sim" "$list" "$approved" "$explicit" "$checked"; return 0
  fi
  if [[ -n "$(comm -23 "$list" "$approved")" ]]; then
    echo "SKIP $stage: unexpected packages; no changes"; comm -23 "$list" "$approved"
    rm -f "$sim" "$list" "$approved" "$explicit" "$checked"; return 2
  fi
  mapfile -t selection < "$list"
  # Explicitly purge the exact approved packages, never execute apt autoremove.
  if ! apt-get -s --no-install-recommends purge "${selection[@]}" > "$explicit" 2>&1; then
    echo "SKIP $stage: explicit simulation failed"; tail -35 "$explicit"
    rm -f "$sim" "$list" "$approved" "$explicit" "$checked"; return 2
  fi
  awk '$1=="Purg" {print $2}' "$explicit" | sort -u > "$checked"
  if ! cmp -s "$checked" "$list" || grep -Eq '^(Inst|Conf|Remv) ' "$explicit"; then
    echo "SKIP $stage: explicit transaction changed removal plan"
    diff -u "$list" "$checked" || true
    rm -f "$sim" "$list" "$approved" "$explicit" "$checked"; return 2
  fi
  echo "APPROVED $stage: $(wc -l < "$list") packages"; cat "$list"
  if [[ "$action" == preview ]]; then
    echo "PREVIEW ONLY $stage: no changes made"
    rm -f "$sim" "$list" "$approved" "$explicit" "$checked"
    return 0
  fi
  if ! ( DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get -y --no-install-recommends purge "${selection[@]}" 2>&1 | grep -v -E "^rmdir: failed to remove .?/var/lib/libreoffice"; exit "${PIPESTATUS[0]}" ); then
    echo "ERROR $stage: APT failed. Check dpkg status before more package maintenance."
    rm -f "$sim" "$list" "$approved" "$explicit" "$checked"; return 1
  fi
  rm -f "$sim" "$list" "$approved" "$explicit" "$checked"
  package_guard || { echo "ERROR $stage: post-apply safety check failed"; return 1; }
  echo "COMPLETE $stage: approved packages removed"
}
# <<< ORIGINAL

# >>> ORIGINAL wrn_maintenance.sh:980-1000
# Append a machine-local service entry without claiming playback validation.
record_service_history() {
  local h="$WRN_DIR/WRN-Service-History.txt" before="$1" after="$2" rc="$3" entry
  [[ ! -L "$h" ]] || { echo 'ERROR: service history is a symlink'; return 1; }
  [[ ! -e "$h" || ( -f "$h" && "$(stat -c %h "$h")" == 1 ) ]] || return 1
  entry="$(date -u '+%Y-%m-%d %H:%M:%SZ')"
  {
    [[ -s "$h" ]] || printf 'WRN SERVICE HISTORY\n===================\n'
    printf '\n=== MAINTENANCE VISIT ===\n'
    printf 'Date UTC: %s\nHost: %s\nScript: %s\n' "$entry" "$(hostname -s)" "$WRN_SCRIPT_VERSION"
    printf 'OS initial: %s\nOS final: %s\n' "$before" "$after"
    printf 'Optional applications: %s\nLeftover dependencies: %s\n' "$APP_RESULT" "$LEFT_RESULT"
    printf 'Core maintenance exit code: %s\n' "$rc"
    printf 'WAVE service: %s\n' "$(systemctl is-active hanwha-mediaserver.service 2>/dev/null || true)"
    printf 'Archive: %s\n' "$(findmnt -rn -M /mnt/sda -o SOURCE,FSTYPE,OPTIONS 2>/dev/null || true)"
    printf 'Updates policy: unchanged by this script (audit separately per WRN)\n'
    printf 'Recording/playback: manual verification required (NOT automatically verified)\n'
    printf 'Maintenance report: %s\n' "${WRN_LOG##*/}"
  } >> "$h" || return 1
  chown wave:wave "$h" && chmod 0644 "$h"
}
# <<< ORIGINAL

# True when the LAST visit in the service history succeeded and has not been finalized yet.
# (Pure Bash/awk replacement for the python check in 1.0.0's finalize_visit.)
history_pending() {  # history_pending <history-file>
  awk '/^=== MAINTENANCE VISIT ===/ {v=NR; ok=0}
       /^=== VISIT FINALIZED ===/ {f=NR}
       v && NR>v && /Core maintenance exit code: 0/ {ok=1}
       END {exit !(v && v>f && ok)}' "$1"
}

# >>> ORIGINAL wrn_maintenance.sh:1026-1035
# Explicit end-of-visit finalization, only AFTER technician confirms live video,
# playback and local desktop. This removes top-level regular files including the
# running script but never descends into directories and refuses symlinks.
finalize_visit() {
  local h="$WRN_DIR/WRN-Service-History.txt" f already_confirmed="${1:-no}"
  [[ -f "$h" && -s "$h" && ! -L "$h" && "$(stat -c %h "$h")" == 1 ]] || {
    echo 'STOP: verified permanent history required before deletion'; return 1;
  }
  safe_state || return 1
  # Only allow finalization for a new, successful, not-yet-finalized maintenance visit.
# <<< ORIGINAL
  if ! history_pending "$h"; then
    echo 'STOP: no new successful maintenance visit awaiting finalization'
    return 1
  fi
# >>> ORIGINAL wrn_maintenance.sh:1047-1088
  if find "$WRN_DIR" -mindepth 1 -maxdepth 1 -type l | grep -q .; then
    echo 'STOP: symlinks present in maintenance folder; inspect manually'; return 1
  fi
  if find "$WRN_DIR" -mindepth 1 -maxdepth 1 -type d | grep -q .; then
    echo 'STOP: subdirectories present; inspect manually'; return 1
  fi
  if [[ "$already_confirmed" != yes ]]; then
    # Print the warnings and question through the SAME controlling terminal.
    # The maintenance log uses a separate tee pipeline, which can otherwise
    # reorder stdout and /dev/tty and show the question before its warnings.
    if [[ -w /dev/tty ]]; then
      printf '\n%s\n%s\n' \
        'FINALIZATION: all reports and scripts in the maintenance folder will be deleted.' \
        'Do NOT confirm if desktop, new recording and playback have not all been tested.' > /dev/tty
    else
      echo 'STOP: a controlling terminal is required for finalization.' >&2
      return 2
    fi
    tech_prompt 'I personally verified desktop, new WAVE recording AND playback. Finalize now?' || {
      echo 'Finalization declined or unavailable; no files deleted.'; return 1;
    }
  fi
  # Document finalization itself before removing evidence.
  {
    printf '\n=== VISIT FINALIZED ===\nUTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Technician attestation: desktop, new recording and playback confirmed interactively during --finalize\n'
    printf 'WAVE service: %s\n' "$(systemctl is-active hanwha-mediaserver.service 2>/dev/null || true)"
    printf 'Archive: %s\n' "$(findmnt -rn -M /mnt/sda -o SOURCE,FSTYPE,OPTIONS 2>/dev/null || true)"
    printf 'OS: %s\n' "$(df -h / | awk 'NR==2{print $5 " used, " $4 " free"}')"
  } >> "$h" || return 1
  chown wave:wave "$h" && chmod 0644 "$h" || return 1
  for f in "$WRN_DIR"/* "$WRN_DIR"/.[!.]* "$WRN_DIR"/..?*; do
    [[ -e "$f" ]] || continue
    [[ "$f" == "$h" ]] && continue
    [[ -f "$f" && ! -L "$f" && "$(stat -c %h "$f")" == 1 ]] || {
      echo "STOP: unexpected file type/hardlink, retained: $f"; return 1;
    }
  done
  find "$WRN_DIR" -mindepth 1 -maxdepth 1 -type f ! -name WRN-Service-History.txt -delete || return 1
  echo 'FINALIZED: maintenance folder now contains permanent WRN-Service-History.txt only.'
  ls -la "$WRN_DIR"
}
# <<< ORIGINAL

# >>> ORIGINAL wrn_maintenance.sh:1090-1107
# Interactive technician workflow: available only from a real controlling terminal.
# Declining a critical repair stops before routine maintenance, retaining all reports.
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

# >>> ORIGINAL wrn_maintenance.sh:1174-1189
# All pre-prompt instructions and the actual question go through /dev/tty,
# avoiding interleaving with the tee-backed maintenance transcript.
tech_verification_notice() {
  [[ -w /dev/tty ]] || { echo 'STOP: controlling terminal unavailable' >&2; return 2; }
  printf '\n%s\n%s\n%s\n' \
    '=== TECHNICIAN OPERATIONAL VERIFICATION ===' \
    'Before finalizing, personally verify: Ubuntu desktop, live WAVE recording, and playback.' \
    'If cameras are unavailable, or any check fails, select N and retain the reports.' > /dev/tty
}

tech_after_apply() {
  tech_verification_notice || return 2
  if tech_prompt 'Have you verified ALL three functions and want to clean the maintenance folder?'; then
    # Already attested via guided Y prompt; do not ask twice.
    finalize_visit yes
  else
# <<< ORIGINAL
    echo 'Reports, scripts and history preserved. Run this program again after you have verified desktop, recording and playback, and it will offer to finish.'
# >>> ORIGINAL wrn_maintenance.sh:1191-1192
  fi
}
# <<< ORIGINAL

# ==================================================================================================
# CARRIED OVER FROM THE OLD HELPER SCRIPTS (each now a stage function; run only as a sub-process)
# ==================================================================================================

# --- wrn_systemd_timeout_restore.sh 1.0.0: audit/restore the 3-second systemd defaults ---
stage_timeout_restore() {
  local MODE="$1"   # --preview | --apply
# >>> ORIGINAL wrn_systemd_timeout_restore.sh:5-7
set -Eeuo pipefail
export LC_ALL=C
umask 027
# <<< ORIGINAL
# >>> ORIGINAL wrn_systemd_timeout_restore.sh:21-30
(( EUID == 0 )) || { echo 'ERROR: Run with sudo.' >&2; exit 2; }
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 22.04 ]] || {
  echo "STOP: Expected Ubuntu 22.04; found ${PRETTY_NAME:-unknown}." >&2; exit 2;
}

DIR=/home/wave/Downloads/maintenance
[[ -d "$DIR" && ! -L "$DIR" ]] || { echo "STOP: Missing or symlinked report directory: $DIR" >&2; exit 2; }
CONFIG=/etc/systemd/system.conf
[[ -f "$CONFIG" && ! -L "$CONFIG" ]] || { echo 'STOP: Unexpected systemd config file.' >&2; exit 2; }
# <<< ORIGINAL
# >>> ORIGINAL wrn_systemd_timeout_restore.sh:32-55 sed:s/ v1\.0\.0 / v@VERSION@ /
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$DIR/WRN-Systemd-Timeout-Restore_${MODE#--}_${STAMP}_$$.txt"
( set -C; : > "$REPORT" ) || { echo 'STOP: Could not create report.' >&2; exit 2; }
chmod 640 "$REPORT"
chown wave:wave "$REPORT" || { echo 'STOP: Cannot give report to wave user.' >&2; exit 2; }
# Store all details in report; print only path on exit.
exec 3>&1
exec >> "$REPORT" 2>&1
finish() { rc=$?; echo "===== EXIT STATUS: $rc ====="; printf 'Report saved: %s\n' "$REPORT" >&3; exit "$rc"; }
trap finish EXIT

printf '===== WRN SYSTEMD TIMEOUT RESTORE v2.0.0-rc.4 =====\nMode: %s\nDate: %s\nHost: %s\n' "$MODE" "$(date -Is)" "$(hostname)"
echo '===== BEFORE ====='
systemctl show -p DefaultTimeoutStartUSec -p DefaultTimeoutStopUSec
printf '\nActive settings in main config:\n'
grep -nE '^[[:space:]]*DefaultTimeout(Start|Stop)Sec[[:space:]]*=' "$CONFIG" || true
printf '\nAll systemd configuration sources:\n'
systemd-analyze cat-config systemd/system.conf 2>&1 | grep -E '(^# /|DefaultTimeout(Start|Stop)Sec)' || true
printf '\nArchive mounts (informational):\n'
for mountpoint in /mnt/sda /mnt/sdb; do findmnt -M "$mountpoint" || true; done
printf '\nWAVE status: '; systemctl is-active hanwha-mediaserver || true

# Only allow the exact observed 3-second overrides, or an already-default config.
# Reject conflicting overrides in drop-ins rather than giving a false success.
# <<< ORIGINAL
# --- 2.0.0: the three python snippets of 1.0.0 are re-written in pure Bash/sed below (same rules) ---
CHECK="$(
  seen=''
  for key in DefaultTimeoutStartSec DefaultTimeoutStopSec; do
    mapfile -t values < <(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p" "$CONFIG")
    if (( ${#values[@]} == 0 )); then v=unset
    elif (( ${#values[@]} == 1 )) && [[ "${values[0]}" == 3s ]]; then v=3s
    else echo "STOP: Unexpected $key active values: ${values[*]}" >&2; exit 1; fi
    if [[ -n "$seen" && "$seen" != "$v" ]]; then echo "STOP: Mixed timeout settings: $seen vs $v" >&2; exit 1; fi
    seen="$v"
  done
  echo "$seen"
)" || exit 1
# >>> ORIGINAL wrn_systemd_timeout_restore.sh:75-88
if [[ "$CHECK" == unset ]]; then
  echo 'No active 3s overrides in main config; no changes needed.'
  echo 'Effective settings shown above; investigate drop-ins if they are not 90s.'
  exit 0
fi

# Only proceed when effective settings agree with the two exact main-file overrides.
START="$(systemctl show -P DefaultTimeoutStartUSec)"
STOP="$(systemctl show -P DefaultTimeoutStopUSec)"
if [[ "$START" != 3s || "$STOP" != 3s ]]; then
  echo "STOP: Effective values are not 3s/3s ($START/$STOP). Possible drop-in override."
  exit 1
fi

# <<< ORIGINAL
# Check for active overrides in separate system.conf.d fragments.
for root in /etc/systemd/system.conf.d /run/systemd/system.conf.d /usr/lib/systemd/system.conf.d /lib/systemd/system.conf.d; do
  [[ -d "$root" ]] || continue
  for dropin in "$root"/*.conf; do
    [[ -e "$dropin" ]] || continue
    grc=0; grep -Eq '^[[:space:]]*DefaultTimeout(Start|Stop)Sec[[:space:]]*=' "$dropin" 2>/dev/null || grc=$?
    (( grc != 2 )) || { echo "STOP: Cannot read $dropin"; exit 1; }
    (( grc != 0 )) || { echo "STOP: Timeout override in $dropin; review manually."; exit 1; }
  done
done
# >>> ORIGINAL wrn_systemd_timeout_restore.sh:101-113

if [[ "$MODE" == --preview ]]; then
  echo 'PREVIEW: Eligible for restoring stock 90-second defaults.'
  echo 'No files changed. Apply with: sudo bash wrn_systemd_timeout_restore.sh --apply'
  exit 0
fi

BACKUP="/etc/systemd/system.conf.before-wrn-timeout-restore_${STAMP}.bak"
[[ ! -e "$BACKUP" ]] || { echo "STOP: Backup exists: $BACKUP"; exit 1; }
cp -a -- "$CONFIG" "$BACKUP"
echo "Backup: $BACKUP"

# Atomic replace preserves owner, mode and original file except for those two lines.
# <<< ORIGINAL
# Atomic replace (temp file + mv) preserves owner, mode and the file except for those two lines.
for key in DefaultTimeoutStartSec DefaultTimeoutStopSec; do
  [[ "$(grep -Ec "^[[:space:]]*${key}=3s[[:space:]]*$" "$CONFIG")" == 1 ]] || { echo "STOP: Unexpected ${key} lines; no config replacement."; exit 1; }
done
NEWCONF="$(mktemp "$(dirname "$CONFIG")/.system.conf.wrn-XXXXXXXX")" || { echo 'STOP: cannot stage new config'; exit 1; }
sed -E -e 's/^([[:space:]]*)DefaultTimeoutStartSec=3s[[:space:]]*$/\1# DefaultTimeoutStartSec=90s (systemd default; former 3s override removed)/' \
       -e 's/^([[:space:]]*)DefaultTimeoutStopSec=3s[[:space:]]*$/\1# DefaultTimeoutStopSec=90s (systemd default; former 3s override removed)/' \
       "$CONFIG" > "$NEWCONF" || { rm -f "$NEWCONF"; echo 'STOP: cannot stage new config'; exit 1; }
chmod --reference="$CONFIG" "$NEWCONF" && chown --reference="$CONFIG" "$NEWCONF" || { rm -f "$NEWCONF"; echo 'STOP: cannot stage new config'; exit 1; }
mv -f -- "$NEWCONF" "$CONFIG" || { rm -f "$NEWCONF"; echo 'STOP: cannot install new config'; exit 1; }
# >>> ORIGINAL wrn_systemd_timeout_restore.sh:134-158

echo '===== RELOAD SYSTEMD MANAGER ====='
# daemon-reexec has been validated on WRN lab and customer; no unit restarts requested.
systemctl daemon-reexec
sleep 1
START="$(systemctl show -P DefaultTimeoutStartUSec)"
STOP="$(systemctl show -P DefaultTimeoutStopUSec)"
echo "Effective start timeout: $START"
echo "Effective stop timeout: $STOP"
if [[ "$START" != '1min 30s' || "$STOP" != '1min 30s' ]]; then
  echo 'WARNING: Expected 90s defaults were not observed; restoring backup.'
  cp -a -- "$BACKUP" "$CONFIG"
  systemctl daemon-reexec || true
  exit 1
fi

echo '===== POST-CHANGE SERVICE CHECK ====='
for service in hanwha-mediaserver NetworkManager cockpit.socket; do
  echo "$service: $(systemctl is-active "$service" 2>&1 || true)"
done
for mountpoint in /mnt/sda /mnt/sdb; do
  if findmnt -M "$mountpoint"; then :; else echo "NOTE: $mountpoint is not mounted (no mounting attempted)."; fi
done
printf 'SUCCESS: 3s global overrides removed; effective defaults are 90s.\n'
echo 'No reboot performed. Previous dmesg.service failed state may persist until a new successful run.'
# <<< ORIGINAL
}

# --- wrn_archive_multidrive.sh: UUID + timeout normalization of every MOUNTED archive ---
stage_multidrive() {
  local MODE="$1"   # --audit | --apply
# >>> ORIGINAL wrn_archive_multidrive.sh:4-5
set -Eeuo pipefail
export LC_ALL=C
# <<< ORIGINAL
# >>> ORIGINAL wrn_archive_multidrive.sh:8-126 sed:s/(%s) ===\\n' "\$MODE"/(%s) ===\\n' "${MODE#--}"/
[[ ${EUID:-$(id -u)} == 0 ]] || { echo 'STOP: sudo required' >&2; exit 2; }
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 22.04 ]] || { echo 'STOP: Ubuntu 22.04 only' >&2; exit 2; }
for c in awk blkid findmnt readlink mktemp cp cmp mv chmod chown lsblk tr; do command -v "$c" >/dev/null || { echo "STOP: missing $c" >&2; exit 2; }; done
fstab=/etc/fstab
[[ -f $fstab && ! -L $fstab ]] || { echo 'STOP: fstab not a regular file' >&2; exit 2; }
[[ -d /mnt && ! -L /mnt ]] || { echo 'STOP: unexpected /mnt' >&2; exit 2; }
# Enforce unique archive targets AND sources before any edit.
awk '$1 !~ /^#/ && NF>=4 && $2 ~ /^\/mnt\/sd[a-d]$/ {if (++targets[$2]>1) bad=1; if(++sources[$1]>1) bad=1} END{exit bad}' "$fstab" || { echo 'STOP: duplicate archive target or source; resolve using dedicated guided dedup, then rerun'; exit 1; }
shopt -s nullglob
mounts=( )
for mp in /mnt/sda /mnt/sdb /mnt/sdc /mnt/sdd; do
  if findmnt -rn -M "$mp" >/dev/null 2>&1; then mounts+=("$mp"); fi
done
(( ${#mounts[@]} )) || { echo 'STOP: no mounted archive drives'; exit 1; }
# Need sda even when multiple drives, consistent with Gen2 factory service.
[[ -n $(findmnt -rn -M /mnt/sda -o SOURCE 2>/dev/null || :) ]] || { echo 'STOP: primary /mnt/sda not mounted'; exit 1; }
printf '=== MULTI-DRIVE ARCHIVE PREFLIGHT (%s) ===\n' "${MODE#--}"
normalized=0
expected=0
replacements=$(mktemp) || exit 1
trap 'rm -f -- "$replacements"' EXIT
for mp in /mnt/sda /mnt/sdb /mnt/sdc /mnt/sdd; do
  count=$(awk -v mp="$mp" '$1 !~ /^#/ && $2==mp {n++} END{print n+0}' "$fstab")
  if ! findmnt -rn -M "$mp" >/dev/null 2>&1; then
    if (( count )); then
      spec=$(awk -v mp="$mp" '$1 !~ /^#/ && $2==mp {print $1;exit}' "$fstab")
      # A real configured device present but unmounted is an unresolved fault; never edit other disks.
      resolved=''
      case "$spec" in UUID=*) resolved=$(blkid -U "${spec#UUID=}" 2>/dev/null || :) ;; /dev/*) [[ -b $spec ]] && resolved=$spec ;; esac
      if [[ -n $resolved ]]; then
        echo "STOP: expected archive $mp has a present device but is NOT mounted ($spec); investigate first"
        exit 1
      fi
      echo "WARNING: optional archive $mp is configured but its device is unavailable ($spec). Not edited."
    fi
    continue
  fi
  ((expected+=1))
  [[ $count == 1 ]] || { echo "STOP: mounted $mp requires exactly one fstab entry; found $count"; exit 1; }
  src=$(findmnt -rn -M "$mp" -o SOURCE)
  fs=$(findmnt -rn -M "$mp" -o FSTYPE)
  opts_live=$(findmnt -rn -M "$mp" -o OPTIONS)
  [[ $src == /dev/* && -b $src && $fs == ext4 && ,$opts_live, == *,rw,* ]] || { echo "STOP: $mp has an unexpected device/filesystem or is not read-write"; exit 1; }
  dev=$(readlink -f "$src")
  [[ -b $dev ]] || { echo "STOP: $mp device resolution failed"; exit 1; }
  uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || :)
  type=$(blkid -s TYPE -o value "$dev" 2>/dev/null || :)
  [[ $type == ext4 && $uuid =~ ^[0-9A-Fa-f-]{36}$ ]] || { echo "STOP: $mp ext4 UUID invalid"; exit 1; }
  osdev=$(findmnt -rn -M / -o SOURCE)
  [[ $(readlink -f "$osdev") != "$dev" ]] || { echo "STOP: $mp is OS drive!"; exit 1; }
  old=$(awk -v mp="$mp" '$1 !~ /^#/ && $2==mp {print;exit}' "$fstab")
  read -r oldspec oldmp oldtype oldopts dump pass extra <<< "$old"
  [[ -z ${extra:-} && $oldmp == "$mp" && ( $oldtype == ext4 || $oldtype == auto ) ]] || { echo "STOP: unexpected $mp fstab structure"; exit 1; }
  # A factory whole-disk fstab reference may identify the parent of a mounted
  # partition-backed ext4 archive (e.g. /dev/sdb -> /dev/sdb1).  Accept this
  # ONLY when the mounted block device is a direct child of that exact disk.
  # A device-name prefix match alone is never sufficient.
  if [[ $oldspec != "$src" && $oldspec != "$dev" && $oldspec != "UUID=$uuid" ]]; then
    [[ $oldspec == /dev/* && -b $oldspec ]] || { echo "STOP: $mp configured device differs from mounted source"; exit 1; }
    parent=$(readlink -f "$oldspec")
    [[ $(lsblk -dn -o TYPE "$dev" | tr -d '[:space:]') == part ]] || { echo "STOP: $mp mismatch is not a partition-backed archive"; exit 1; }
    parent_name=$(lsblk -dn -o PKNAME "$dev" | tr -d '[:space:]')
    [[ -n $parent_name && -b /dev/$parent_name && $(readlink -f "/dev/$parent_name") == "$parent" ]] || {
      echo "STOP: $mp mounted partition does not belong to configured parent disk"; exit 1;
    }
    [[ $(lsblk -dn -o TYPE "$parent" | tr -d '[:space:]') == disk ]] || { echo "STOP: $mp configured parent is not a physical disk"; exit 1; }
    # Reject disks with a filesystem of their own, and parent disks used for
    # the OS or any other mounted filesystem. No mount changes are attempted.
    [[ -z $(blkid -s TYPE -o value "$parent" 2>/dev/null || :) ]] || { echo "STOP: $mp parent disk has its own filesystem"; exit 1; }
    [[ $(readlink -f "$osdev") != "$parent" ]] || { echo "STOP: $mp parent is the OS disk"; exit 1; }
    if findmnt -rn -S "$parent" >/dev/null 2>&1; then
      echo "STOP: $mp parent disk is also mounted"; exit 1
    fi
    echo "  VERIFIED PARTITION-BACKED ARCHIVE: $oldspec is the direct parent of $dev"
  fi
  [[ $oldopts =~ ^[a-zA-Z0-9._,=-]+$ && ${dump:-0} =~ ^[0-9]+$ && ${pass:-0} =~ ^[0-9]+$ ]] || { echo "STOP: invalid $mp options or trailing fields"; exit 1; }
  # Detect aliases pointing at the same ext4 UUID, including cross-mounted disks.
  for prior in "${seen_uuids[@]:-}"; do [[ $prior != "$uuid" ]] || { echo "STOP: same UUID on multiple archive mounts"; exit 1; }; done
  seen_uuids+=("$uuid")
  dt=60; mt=120; keep=()
  IFS=, read -r -a tokens <<< "$oldopts"
  for o in "${tokens[@]}"; do
    case $o in
      x-systemd.device-timeout=*) v=${o#*=}; [[ $v =~ ^[0-9]+s?$ ]] || { echo "STOP: unsupported device timeout on $mp"; exit 1; }; v=${v%s}; (( 10#$v > dt )) && dt=$((10#$v)) ;;
      x-systemd.mount-timeout=*) v=${o#*=}; [[ $v =~ ^[0-9]+s?$ ]] || { echo "STOP: unsupported mount timeout on $mp"; exit 1; }; v=${v%s}; (( 10#$v > mt )) && mt=$((10#$v)) ;;
      nofail) ;;
      *) keep+=("$o") ;;
    esac
  done
  joined=$(IFS=,; echo "${keep[*]}")
  [[ -n $joined ]] || joined=defaults
  target="UUID=$uuid $mp ext4 $joined,nofail,x-systemd.device-timeout=${dt}s,x-systemd.mount-timeout=${mt}s ${dump:-0} ${pass:-0}"
  printf 'DRIVE: %-9s device=%-18s UUID=%s\n' "$mp" "$dev" "$uuid"
  if [[ $old != "$target" ]]; then
    printf '  CURRENT: %s\n  PROPOSED: %s\n' "$old" "$target"
    ((normalized+=1))
  else echo '  PASS: already normalized'; fi
  # TSV records are safe since the validated lines contain no tab characters.
  printf '%s\t%s\n' "$mp" "$target" >> "$replacements"
done
printf 'RESULT: %d mounted archives; %d corrections proposed\n' "$expected" "$normalized"
[[ $MODE == --apply && $normalized -gt 0 ]] || { echo 'No modifications made.'; exit 0; }
backup="/etc/fstab.wrn-dev19.$(date -u +%Y%m%dT%H%M%SZ).bak"
draft=$(mktemp /etc/.fstab.wrn19.XXXXXXXX) || exit 1
trap 'rm -f -- "$replacements" "$draft"' EXIT
cp -a -- "$fstab" "$backup" || exit 1
awk -F '\t' 'NR==FNR {r[$1]=$2; next} {split($0,f,/[[:space:]]+/); if(f[1] !~ /^#/ && f[2] in r) print r[f[2]]; else print $0}' "$replacements" "$fstab" > "$draft"
chmod --reference="$fstab" "$draft" && chown --reference="$fstab" "$draft" || exit 1
[[ $(awk '$1 !~ /^#/ && $2 ~ /^\/mnt\/sd[a-d]$/ {n++} END{print n+0}' "$draft") -ge $expected ]] || { echo 'STOP: missing archive entries in staged fstab'; exit 1; }
findmnt --verify --tab-file "$draft" >/dev/null 2>&1 || { echo 'STOP: staged fstab verification failed; original untouched'; exit 1; }
cmp -s "$fstab" "$backup" || { echo 'STOP: fstab changed during staging'; exit 1; }
mv -f -- "$draft" "$fstab" || exit 1
if ! findmnt --verify --tab-file "$fstab" >/dev/null 2>&1; then
  cp -a -- "$backup" "$fstab" || echo 'CRITICAL: rollback failed'
  echo 'STOP: installed fstab verification failed; rolled back'; exit 1
fi
echo "PASS: updated $normalized mounted archive fstab entries; backup=$backup"
echo 'NOTICE: No active mount changed. Reboot persistence validation required.'
# <<< ORIGINAL
}

# --- wrn_archive_spillover.sh: read-only audit of video written to the OS drive ---
stage_spillover() {
  local MODE=--audit
# >>> ORIGINAL wrn_archive_spillover.sh:4-5
set -Eeuo pipefail
export LC_ALL=C
# <<< ORIGINAL
# >>> ORIGINAL wrn_archive_spillover.sh:8-78
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
}

# --- fstab duplicate collapse for EVERY archive slot (NEW in 2.0.0: generalizes wrn_fstab_dedup.sh; pure Bash) ---
# wrn_fstab_dedup.sh 1.0.0 only understood /mnt/sda. Same safety rules, now per slot:
#  * only identical duplicate lines are ever removed; conflicting duplicates STOP for manual review
#  * a MOUNTED slot is also normalized to UUID + 60s/120s timeouts (as 1.0.0 did for sda)
#  * an UNMOUNTED slot only has its exact-duplicate lines collapsed (the line itself is left alone)
#  * candidate fstab must pass findmnt --verify; backup written first; nothing else is touched
stage_fstab_dedup() {
  local MODE="$1"   # --preview | --apply
  set -Eeuo pipefail
  local fstab=/etc/fstab slot mp i n k line stamp backup tmp
  local FACTORY='defaults,nofail,x-systemd.device-timeout=5'
  local -a lines out f dups
  local -A CNT ENT IDX
  stop() { echo "STOP: $* No changes made."; exit 1; }
  [[ -f "$fstab" && ! -L "$fstab" ]] || stop '/etc/fstab missing.'
  mapfile -t lines < "$fstab"
  out=("${lines[@]}")
  for slot in sda sdb sdc sdd; do CNT[$slot]=0; done
  for i in "${!lines[@]}"; do
    line="${lines[$i]}"
    read -ra f <<< "$line" || true
    (( ${#f[@]} )) || continue
    [[ "${f[0]}" != '#'* ]] || continue
    [[ "${f[1]:-}" =~ ^/mnt/(sd[a-d])$ ]] || continue
    slot="${BASH_REMATCH[1]}"
    (( ${#f[@]} == 6 )) || stop "Unexpected fstab fields on line $((i+1))."
    n="${CNT[$slot]}"; ENT[$slot:$n]="${f[*]}"; IDX[$slot:$n]="$i"; CNT[$slot]=$((n+1))
  done
  dups=()
  for slot in sda sdb sdc sdd; do
    n="${CNT[$slot]}"
    (( n <= 2 )) || stop "More than two /mnt/$slot entries."
    if (( n == 2 )); then
      [[ "${ENT[$slot:0]}" == "${ENT[$slot:1]}" ]] || stop "Conflicting entries for /mnt/$slot; manual review needed."
      dups+=("$slot")
    fi
    echo "/mnt/$slot: $n fstab entries"
  done
  if (( ${#dups[@]} == 0 )); then echo 'No duplicate archive entries; nothing to do.'; exit 0; fi
  local source target fs opts nopts dump check src parts uuid mu pk new_entry fstype
  for slot in "${dups[@]}"; do
    mp="/mnt/$slot"
    read -r source target fs opts dump check <<< "${ENT[$slot:0]}"
    # Found on a real unit (PROGRESS item 16): some factory images write the fstab type as "auto" and the device
    # timeout as a bare number ("=60"); both are valid fstab. The mounted-drive checks below still require the live
    # mount itself to be ext4, so "auto" is only ever accepted for a drive that is really ext4 (or an empty bay).
    [[ "$fs" == ext4 || "$fs" == auto ]] || stop "$mp filesystem is $fs, expected ext4 or auto."
    # "60" and "60s" mean the same to systemd: compare the options with an optional "s" after the numbers removed.
    nopts="$(sed -E 's/(x-systemd\.(device|mount)-timeout=[0-9]+)s/\1/g' <<< "$opts")"
    case "$nopts" in
      "$FACTORY"|'defaults,nofail,x-systemd.device-timeout=60'|'defaults,nofail,x-systemd.device-timeout=60,x-systemd.mount-timeout=120') ;;
      *) stop "Unrecognized $mp options; manual review needed." ;;
    esac
    [[ "$dump" == 0 && ( "$check" == 0 || "$check" == 2 ) ]] || stop "Unexpected dump/fsck fields for $mp."
    if parts="$(findmnt -n -M "$mp" -o SOURCE,FSTYPE 2>/dev/null)"; then
      read -r src fstype <<< "$parts"
      [[ -n "$src" && "$fstype" == ext4 ]] || stop "$mp mount is not ext4."
      local realsrc; realsrc="$(readlink -f "$src")"
      uuid="$(blkid -s UUID -o value "$realsrc" 2>/dev/null || true)"
      [[ -n "$uuid" ]] || stop "Cannot read UUID of $realsrc."
      mu="$(findmnt -n -M "$mp" -o UUID 2>/dev/null || true)"
      [[ "$mu" == "$uuid" ]] || stop "Mounted $mp UUID differs from $realsrc UUID."
      pk="$(lsblk -dn -o PKNAME "$realsrc" 2>/dev/null | tr -d '[:space:]')"
      case "$source" in "/dev/$slot"|"$realsrc"|"$src"|"UUID=$uuid") ;; *) stop "$mp fstab device/UUID differs from the mounted drive." ;; esac
      if [[ "$source" == "/dev/$slot" && "$realsrc" != "$source" && "$pk" != "$slot" ]]; then
        stop "$mp fstab device/UUID differs from the mounted drive."
      fi
      new_entry="UUID=$uuid $mp ext4 defaults,nofail,x-systemd.device-timeout=60s,x-systemd.mount-timeout=120s 0 $check"
      out[${IDX[$slot:0]}]="$new_entry"
      echo "$mp: mounted ($realsrc) -> duplicates collapsed AND entry normalized: $new_entry"
    else
      [[ "$source" == UUID=* || "$source" == "/dev/$slot" ]] || stop "$mp source $source not recognized."
      echo "$mp: not mounted -> identical duplicate lines collapsed; entry left as is: ${ENT[$slot:0]}"
    fi
    out[${IDX[$slot:1]}]=$'\x01DROP'
  done
  tmp="$(mktemp /etc/.fstab.wrn-XXXXXXXX)" || stop 'cannot stage candidate fstab.'
  trap "rm -f -- '$tmp'" EXIT
  for line in "${out[@]}"; do [[ "$line" == $'\x01DROP' ]] || printf '%s\n' "$line"; done > "$tmp"
  if cmp -s "$fstab" "$tmp"; then echo 'Changes needed: no'; echo 'Already compliant; no changes made.'; exit 0; fi
  echo 'Changes needed: yes'
  if [[ "$MODE" == --preview ]]; then echo 'PREVIEW ONLY. No changes made.'; exit 0; fi
  chmod --reference="$fstab" "$tmp"
  findmnt --verify --tab-file "$tmp" > /tmp/.wrn-verify.$$ 2>&1 || { cat /tmp/.wrn-verify.$$ >&2; rm -f /tmp/.wrn-verify.$$; stop 'Candidate fstab failed validation.'; }
  rm -f /tmp/.wrn-verify.$$
  backup="/etc/fstab.wrn-dedup-$(date -u +%Y%m%dT%H%M%SZ).bak"
  [[ ! -e "$backup" ]] || stop 'Backup filename collision.'
  cp -p -- "$fstab" "$backup"
  mv -f -- "$tmp" "$fstab"
  echo "Backup: $backup"
  echo 'Updated /etc/fstab. No archive was mounted or unmounted by this step.'
}

# ==================================================================================================
# NEW IN 2.0.0: visit state, stage runner, findings, the one-question flow
# ==================================================================================================

# Visit state is only a bookmark. Every fix re-checks before it changes anything, so an interrupted
# visit never blocks: just run again, or add --fresh to forget the bookmark entirely.
state_set() {  # key value [key value ...]
  local k v
  [[ -e "$WRN_STATE" && ! -L "$WRN_STATE" ]] || { : > "$WRN_STATE"; chmod 600 "$WRN_STATE"; }
  while (( $# >= 2 )); do
    k="$1"; v="$2"; shift 2
    sed -i "/^${k}=/d" "$WRN_STATE"
    printf '%s=%s\n' "$k" "$v" >> "$WRN_STATE"
  done
}
state_get() { sed -n "s/^$1=//p" "$WRN_STATE" 2>/dev/null | tail -1; }

acquire_lock() {
  exec 9>"$WRN_LOCK" || { echo 'STOP: cannot create lock file' >&2; return 1; }
  if ! flock -n 9; then
    echo "STOP: another wrn_maintenance.sh run is active on this recorder (pid $(cat "$WRN_LOCK" 2>/dev/null || echo unknown))." >&2
    echo '      Wait for it to finish. (A crashed run releases its lock automatically.)' >&2
    return 1
  fi
  echo "$$" > "$WRN_LOCK"
}

STAGE_SUMMARY=()
run_stage() {  # run_stage <stage-name> "<plain label>"
  local name="$1" label="${2:-$1}" rc
  state_set STAGE_LAST "$name" STAGE_STATUS running
  printf '\n--- %s ---\n' "$label"
  WRN_STAGE_CHILD=1 bash "$WRN_SELF" --stage "$name"
  rc=$?
  if (( rc )); then
    state_set STAGE_STATUS "failed($rc)"
    STAGE_SUMMARY+=("FAILED  $label (exit $rc)")
    echo "STAGE FAILED: $label (exit $rc)"
  else
    state_set STAGE_STATUS ok
    STAGE_SUMMARY+=("ok      $label")
    echo "stage ok: $label"
  fi
  return "$rc"
}
stage_quiet() {  # stage_quiet <stage-name> <outfile>: run a read-only stage, keep output in a file
  WRN_STAGE_CHILD=1 bash "$WRN_SELF" --stage "$1" > "$2" 2>&1
}

# Child-process entry: the ONLY place stage functions are invoked.
run_child_stage() {
  case "$1" in
    timeout_preview)   stage_timeout_restore --preview ;;
    timeout_apply)     stage_timeout_restore --apply ;;
    dedup_preview)     stage_fstab_dedup --preview ;;
    dedup_apply)       stage_fstab_dedup --apply ;;
    multidrive_audit)  stage_multidrive --audit ;;
    multidrive_apply)  stage_multidrive --apply ;;
    spillover_audit)   stage_spillover ;;
    snap_refresh_hold) snap_refresh_hold ;;
    logging_kb)        logging_kb ;;
    snap_cleanup)      snap_cleanup ;;
    snap_active_cleanup) snap_active_cleanup_pilot ;;
    snap_orphan_audit) snap_orphan_cleanup audit ;;
    snap_orphan_apply) snap_orphan_cleanup apply ;;
    dmesg_audit)       dmesg_service_recovery audit ;;
    dmesg_apply)       dmesg_service_recovery apply ;;
    final_kb_summary)  final_kb_summary ;;
    package_apps_preview)  package_stage APPLICATIONS preview ;;
    package_left_preview)  package_stage LEFTOVERS preview ;;
    package_apps_apply)    package_stage APPLICATIONS apply ;;
    package_left_apply)    package_stage LEFTOVERS apply ;;
    diagnose_full)     bash "$WRN_DIR/wrn_diagnose.sh" --full ;;
    recovery_inspect)  WRN_FROM_MAINTENANCE=1 bash "$WRN_DIR/wrn_recovery.sh" --inspect ;;
    recovery_recover)  WRN_FROM_MAINTENANCE=1 bash "$WRN_DIR/wrn_recovery.sh" --recover ;;
    os_video_delete)   WRN_FROM_MAINTENANCE=1 bash "$WRN_DIR/wrn_recovery.sh" --os-video-delete ;;
    *) echo "Unknown stage: $1" >&2; return 2 ;;
  esac
}

# ---------------------------------- read-only findings ----------------------------------
declare -A M_CNT M_SPEC M_STATE
scan_slots() {   # mounted / stale (mounted from a device that is gone or now has another name) / offline (drive present) / absent (configured, no drive) / unconfigured
  local slot spec present src byuuid
  for slot in "${SLOTS[@]}"; do
    M_CNT[$slot]="$(awk -v mp="/mnt/$slot" '$1 !~ /^#/ && $2==mp {n++} END{print n+0}' /etc/fstab)"
    M_SPEC[$slot]="$(awk -v mp="/mnt/$slot" '$1 !~ /^#/ && $2==mp {print $1; exit}' /etc/fstab)"
    if findmnt -rn -M "/mnt/$slot" >/dev/null 2>&1; then
      M_STATE[$slot]=mounted
      src="$(findmnt -rn -M "/mnt/$slot" -o SOURCE 2>/dev/null | head -1 | sed 's/\[.*//')"
      if [[ "$src" == /dev/* ]]; then
        if [[ ! -b "$src" ]]; then M_STATE[$slot]=stale
        elif [[ "${M_SPEC[$slot]}" == UUID=* ]]; then
          byuuid="$(blkid -U "${M_SPEC[$slot]#UUID=}" 2>/dev/null || :)"
          [[ -z "$byuuid" || "$(readlink -f "$byuuid")" == "$(readlink -f "$src")" ]] || M_STATE[$slot]=stale
        fi
      fi
    elif (( ${M_CNT[$slot]} == 0 )); then M_STATE[$slot]=unconfigured
    else
      spec="${M_SPEC[$slot]}"; present=''
      case "$spec" in
        UUID=*) present="$(blkid -U "${spec#UUID=}" 2>/dev/null || :)" ;;
        /dev/*) [[ -b "$spec" ]] && present="$spec" ;;
      esac
      if [[ -n "$present" ]]; then M_STATE[$slot]=offline; else M_STATE[$slot]=absent; fi
    fi
  done
}
dup_count() { awk '$1 !~ /^#/ && $2 ~ /^\/mnt\/sd[a-d]$/ {m[$2]++} END{n=0; for(k in m) if(m[k]>1) n++; print n}' /etc/fstab; }

human_bytes() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }
say() { printf '  [%-5s] %s\n' "$1" "$2"; }
A_BLOCK=(); A_OFFLINE=(); A_NEED_TIMEOUT=0; A_NEED_DEDUP=0; A_ROUTINE_OK=1; A_OS_DIRS=0; A_OS_BYTES=0

assess() {
  local slot start stop usage tmp line nmounted=0 dups
  A_BLOCK=(); A_OFFLINE=(); A_NEED_TIMEOUT=0; A_NEED_DEDUP=0; A_ROUTINE_OK=1
  printf '\n=== WHAT I FOUND (read-only) ===\n'
  printf 'Recorder: %s   OS drive: %s\n' "$(hostname -s)" "$(df -h / | awk 'NR==2{print $5 " used, " $4 " free"}')"
  # --- systemd timeouts (do this first: a 3-second timeout can make drives drop offline) ---
  start="$(systemctl show -P DefaultTimeoutStartUSec 2>/dev/null || true)"
  stop="$(systemctl show -P DefaultTimeoutStopUSec 2>/dev/null || true)"
  if [[ "$start" == 3s && "$stop" == 3s ]]; then
    say FIX "System time-out is the factory 3 seconds (too short; can make drives drop offline). Will restore the normal 90 seconds."
    A_NEED_TIMEOUT=1
  elif [[ "$start" == '1min 30s' && "$stop" == '1min 30s' ]]; then
    say OK "System time-out is the normal 90 seconds."
  else
    say STOP "System time-outs are unusual ($start / $stop). Not changing them; escalate."
    A_BLOCK+=("unrecognized systemd global timeouts: $start / $stop")
  fi
  # --- archive drives ---
  scan_slots
  for slot in "${SLOTS[@]}"; do
    case "${M_STATE[$slot]}" in
      mounted) nmounted=$((nmounted+1)); say OK "/mnt/$slot archive is mounted." ;;
      stale) say STOP "/mnt/$slot still shows as mounted, but the drive it was mounted from is gone (it was removed, or came back under a different name). Restart the recorder to clear this. If the drive is still missing afterwards, a hardware check is needed."; A_BLOCK+=("/mnt/$slot is a stale mount") ;;
      offline) A_OFFLINE+=("$slot"); say STOP "/mnt/$slot archive drive is present but NOT mounted (offline). WAVE may be writing video to the OS drive." ;;
      absent)
        if [[ $slot == sda ]]; then say STOP "Primary archive /mnt/sda is configured (${M_SPEC[sda]}) but its drive was not found. Hardware check needed."; A_BLOCK+=("primary archive drive not found")
        else say NOTE "/mnt/$slot is configured (${M_SPEC[$slot]}) but no drive is installed there; entry left alone (optional bay)."; fi ;;
      unconfigured)
        if [[ $slot == sda ]]; then say STOP "Primary archive /mnt/sda is not configured in fstab."; A_BLOCK+=("primary archive not configured in fstab"); fi ;;
    esac
  done
  say NOTE "Archive free space is not judged: WAVE keeps about 30 GB free on each archive by design."
  dups="$(dup_count)"
  if [[ "$dups" =~ ^[0-9]+$ ]] && (( dups > 0 )); then
    say FIX "$dups archive mount point(s) have duplicate lines in /etc/fstab. Will remove the duplicates (backup first)."
    A_NEED_DEDUP=1
  else
    say OK "No duplicate archive lines in /etc/fstab."
  fi
  # --- safety state needed for routine maintenance ---
  [[ "$(systemctl is-active hanwha-mediaserver.service 2>/dev/null)" == active ]] && say OK "WAVE service is running." || { say STOP "WAVE service is not running."; A_ROUTINE_OK=0; }
  [[ "$(systemctl is-active display-manager.service 2>/dev/null)" == active ]] && say OK "Desktop is running." || { say STOP "Desktop (display manager) is not running."; A_ROUTINE_OK=0; }
  [[ "$(findmnt -rn -o SOURCE /)" == /dev/mmcblk* ]] && say OK "OS drive layout is the expected eMMC." || { say STOP "OS drive layout is unexpected (not eMMC)."; A_BLOCK+=("unexpected OS drive layout"); }
  usage="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
  if [[ "$usage" =~ ^[0-9]+$ ]] && (( usage >= 80 )); then say NOTE "OS drive is ${usage}% full (a fallback-recording or log problem is likely; see below)."; fi
  # --- read-only audits (details kept in files) ---
  tmp="$(mktemp)"
  stage_quiet spillover_audit "$tmp" || true
  line="$(grep -m1 '^TOTAL:' "$tmp" || true)"
  if [[ -n "$line" ]]; then
    if [[ "$line" =~ ^TOTAL:\ ([0-9]+)\ dated\ directories\;\ ([0-9]+)\ allocated ]]; then A_OS_DIRS="${BASH_REMATCH[1]}"; A_OS_BYTES="${BASH_REMATCH[2]}"; fi
    if (( A_OS_DIRS == 0 )); then say OK "No WAVE video found on the OS drive."
    else say NOTE "WAVE video was recorded onto the OS drive ($(human_bytes "$A_OS_BYTES")). I will offer to delete it at the end, once every archive drive is back."; fi
  fi
  # --- WAVE analytics (metadata) storage: report-only; the check itself lives in wrn_diagnose.sh ---
  if [[ -f "$WRN_DIR/wrn_diagnose.sh" && ! -L "$WRN_DIR/wrn_diagnose.sh" ]]; then
    line="$(bash "$WRN_DIR/wrn_diagnose.sh" --metadata 2>/dev/null | grep -m1 '^FINDING' || true)"
    if [[ -n "$line" ]]; then
      say NOTE "WAVE's analytics data is being stored on the OS drive instead of the archive drive - this slowly fills the OS drive over time."
      say NOTE "Switch this in WAVE's Drive settings to point to the archive drive. This tool does not change it."
    fi
  fi
  if (( ${#A_OFFLINE[@]} == 0 && ${#A_BLOCK[@]} == 0 )) && [[ "${M_STATE[sda]}" == mounted ]]; then
    stage_quiet snap_orphan_audit "$tmp" || true
    line="$(grep -m1 '^SNAP ORPHANS:' "$tmp" || true)"; [[ -z "$line" ]] || say NOTE "${line}"
    stage_quiet dmesg_audit "$tmp" || true
    line="$(grep -m1 -E '^(PASS|REVIEW|AUDIT ONLY)' "$tmp" || true)"; [[ -z "$line" ]] || say NOTE "dmesg service: ${line}"
    stage_quiet package_apps_preview "$tmp" || true
    line="$(grep -m1 -E '^(APPROVED|SKIP)' "$tmp" || true)"; [[ -z "$line" ]] || say NOTE "Unneeded desktop applications: ${line}"
  fi
  rm -f "$tmp"
}

helper_ok() {  # the companion file must be present and the same version as this one
  local f="$WRN_DIR/$1" v
  [[ -f "$f" && ! -L "$f" ]] || { echo "STOP: $1 is missing. Please download the toolkit again."; return 1; }
  v="$(bash "$f" --version 2>/dev/null)"
  [[ "$v" == "$WRN_SCRIPT_VERSION" ]] || { echo "STOP: $1 is a different version ('$v'). Please download the toolkit again."; return 1; }
}
diag_stage() { helper_ok wrn_diagnose.sh && run_stage diagnose_full "$1"; }

tech_choice() {  # tech_choice "<question>" "<option 1>" "<option 2>"  -> sets CHOICE to 1 or 2
  local r
  if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then echo "STOP: interactive confirmation required: $1 (no terminal available)" >&2; return 2; fi
  while true; do
    printf '\n%s\n  1) %s\n  2) %s\nType 1 or 2: ' "$1" "$2" "$3" > /dev/tty
    IFS= read -r r < /dev/tty || { echo 'STOP: confirmation input unavailable'; return 2; }
    case "${r// /}" in 1) CHOICE=1; return 0 ;; 2) CHOICE=2; return 0 ;; *) printf 'Please type 1 or 2.\n' > /dev/tty ;; esac
  done
}

# History says the last visit succeeded and was not finalized yet?
visit_awaiting_finalize() {
  local h="$WRN_DIR/WRN-Service-History.txt"
  [[ -f "$h" && -s "$h" && ! -L "$h" ]] || return 1
  history_pending "$h"
}

finish_report() {  # finish_report <ok|fail>
  local s
  printf '\n=== RESULT ===\n'
  for s in "${STAGE_SUMMARY[@]}"; do echo "  $s"; done
  if [[ "$1" == ok && -n "${RESTART_NOTE:-}" ]]; then echo "IMPORTANT: $RESTART_NOTE"; fi
  if [[ "$1" == ok ]]; then echo 'RESULT: maintenance completed successfully.'
  else echo 'RESULT: maintenance did NOT complete. Nothing further was changed. Save this output and escalate if the cause is not clear.'; fi
}

# ---------------------------------- the visit ----------------------------------
guided() {
  local start stop slot line n them
  acquire_lock || return 1
  maintenance_log_setup || return 1
  echo "=== WRN MAINTENANCE $WRN_SCRIPT_VERSION ==="
  # ---- an earlier visit that was interrupted or never signed off: ask, do not make anyone type options ----
  if (( !FRESH )); then
    # A 'running' bookmark is always the newest visit, so it is asked about before any older unsigned visit.
    if [[ "$(state_get STATUS)" == running ]]; then
      tech_choice "An earlier visit (started $(state_get STARTED)) was interrupted during '$(state_get STAGE_LAST)'." 'Continue where it left off (every step re-checks first)' 'Start over' || return 1
      [[ "$CHOICE" == 2 ]] && FRESH=1
    elif visit_awaiting_finalize; then
      tech_choice 'An earlier visit finished successfully but was never signed off.' 'Finish it now (re-check, then tidy up)' 'Start a new visit' || return 1
      if [[ "$CHOICE" == 1 ]]; then
        verify_and_finish && return 0
        tech_prompt 'The re-check did not pass. Start a new full visit now?' || return 1
      fi
      FRESH=1
    fi
  fi
  if (( FRESH )); then rm -f "$WRN_STATE"; echo 'Starting a new visit.'; fi
  state_set STATUS running STARTED "$(date -u +%Y-%m-%dT%H:%M:%SZ)" VERSION "$WRN_SCRIPT_VERSION" STAGE_LAST none STAGE_STATUS none

  assess
  if (( ${#A_BLOCK[@]} )); then
    printf '\nSTOP: %s\n' "${A_BLOCK[*]}"
    echo 'This is a safeguard, not a reason to force a repair. Save the output and contact engineering/support.'
    state_set STATUS stopped; return 1
  fi

  local plan=()
  (( A_NEED_TIMEOUT )) && plan+=("restore the normal 90-second system time-out")
  (( A_NEED_DEDUP )) && plan+=("remove duplicate archive lines from /etc/fstab (backup first)")
  if (( ${#A_OFFLINE[@]} )); then
    plan+=("ask you about re-mounting the offline archive drive(s): ${A_OFFLINE[*]}, then carry on with routine maintenance")
  elif (( !A_ROUTINE_OK )); then
    echo; echo 'STOP: WAVE or the desktop is not running, so routine maintenance is not safe. Nothing changed.'; state_set STATUS stopped; return 1
  else
    plan+=("normalize the archive mounts, clean logs/Snaps/unneeded apps, retry the dmesg service, record the visit")
  fi
  printf '\n=== PLANNED CHANGES ===\n'
  local i=0; for line in "${plan[@]}"; do i=$((i+1)); printf '  %d. %s\n' "$i" "$line"; done
  # Fail early (before asking) if a fix cannot even be previewed.
  local pv; pv="$(mktemp)"
  if (( A_NEED_TIMEOUT )); then
    stage_quiet timeout_preview "$pv" || { echo 'STOP: time-out inspection failed:'; cat "$pv"; rm -f "$pv"; state_set STATUS stopped; return 1; }
  fi
  if (( A_NEED_DEDUP )); then
    stage_quiet dedup_preview "$pv" || { echo 'STOP: fstab duplicate preview failed:'; cat "$pv"; rm -f "$pv"; state_set STATUS stopped; return 1; }
    echo; echo 'fstab duplicate repair preview:'; sed 's/^/    /' "$pv"
  fi
  rm -f "$pv"
  tech_prompt 'Apply these changes now?' || { echo 'Nothing was changed.'; state_set STATUS stopped; return 1; }

  INITIAL_SPACE="$(df -h / | awk 'NR==2{print $5 " used, " $4 " free"}')"
  # ---- Step 1: system time-out FIRST. A 3-second time-out can itself make drives drop offline. ----
  if (( A_NEED_TIMEOUT )); then
    run_stage timeout_apply 'Restore the 90-second system time-out' || { finish_report fail; state_set STATUS failed; return 1; }
    start="$(systemctl show -P DefaultTimeoutStartUSec 2>/dev/null || true)"
    stop="$(systemctl show -P DefaultTimeoutStopUSec 2>/dev/null || true)"
    [[ "$start" == '1min 30s' && "$stop" == '1min 30s' ]] || { echo "STOP: post-repair timeouts unexpected: $start / $stop"; finish_report fail; state_set STATUS failed; return 1; }
    echo 'PASS: systemd global timeout restoration verified (90 seconds).'
  fi
  # ---- Step 2: duplicate fstab lines (needed before any archive can be re-mounted or normalized) ----
  if (( A_NEED_DEDUP )); then
    run_stage dedup_apply 'Remove duplicate archive lines from fstab' || { finish_report fail; state_set STATUS failed; return 1; }
    systemctl daemon-reload || { finish_report fail; state_set STATUS failed; return 1; }
    [[ "$(dup_count)" == 0 ]] || { echo 'STOP: duplicate archive entries remain'; finish_report fail; state_set STATUS failed; return 1; }
    echo 'PASS: fstab duplicate repair verified.'
  fi
  # ---- Step 3: archives must be online before anything else is touched. Offer to fix them right here. ----
  scan_slots; A_OFFLINE=()
  for slot in "${SLOTS[@]}"; do [[ "${M_STATE[$slot]}" == offline ]] && A_OFFLINE+=("$slot"); done
  if (( ${#A_OFFLINE[@]} )); then
    echo; echo 'An archive drive is offline, so routine maintenance cannot run yet.'
    helper_ok wrn_recovery.sh || { finish_report fail; state_set STATUS stopped; return 1; }
    run_stage recovery_inspect 'Read-only inspection of the offline archive drive(s)' || true
    n=${#A_OFFLINE[@]}
    if (( n == 1 )); then them='it'; elif (( n == 2 )); then them='both'; else them='all'; fi
    tech_prompt "I found $n archive drive(s) that are offline (${A_OFFLINE[*]}). Fix $them now?" || {
      echo 'Nothing more was changed. The offline drive(s) must be fixed before routine maintenance can run.'
      finish_report fail; state_set STATUS stopped; return 1; }
    run_stage recovery_recover 'Re-mount the offline archive drive(s)' || {
      echo 'Not every archive drive could be fixed. Save this output and contact engineering/support. Do not reboot.'
      finish_report fail; state_set STATUS failed; return 1; }
    scan_slots
    for slot in "${SLOTS[@]}"; do
      [[ "${M_STATE[$slot]}" != offline ]] || { echo "STOP: /mnt/$slot is still offline."; finish_report fail; state_set STATUS failed; return 1; }
    done
    RESTART_NOTE="WAVE may not start using the re-mounted drive(s) (${A_OFFLINE[*]}) until WAVE is restarted. In WAVE's Drive view, check that each one shows as in use; if not, restart the recorder."
  fi
  if [[ "${M_STATE[sda]}" != mounted ]]; then
    echo 'STOP: the primary archive is not mounted. Save this output and contact engineering/support.'
    finish_report fail; state_set STATUS stopped; return 1
  fi
  apply_routine || { finish_report fail; state_set STATUS failed; return 1; }
  finish_report ok
  state_set STATUS applied
  tech_after_apply
}

apply_routine() {
  echo '=== BEFORE ==='
  safe_state || return 1
  df -h /
  diag_stage 'Collect diagnostics (before)' || return 1
  safe_state || return 1
  run_stage snap_refresh_hold 'Hold automatic Snap refreshes' || return 1
  safe_state || return 1
  run_stage logging_kb 'Check logging and trim the journal' || return 1
  safe_state || return 1
  echo '=== ALL MOUNTED ARCHIVES: GUARDED UUID/TIMEOUT NORMALIZATION ==='
  run_stage multidrive_apply 'Normalize every mounted archive in fstab' || return 1
  safe_state || return 1
  run_stage snap_cleanup 'Clean disabled Snap revisions and cache' || return 1
  safe_state || return 1
  echo '=== AFTER ==='
  echo "FINAL Snap refresh schedule:"; snap refresh --time 2>&1 || true
  df -h /
  diag_stage 'Collect diagnostics (after)' || return 1
  safe_state || return 1
  run_stage final_kb_summary 'Verify logging, archive and Snap state' || return 1
  echo '=== MULTI-DRIVE FINAL VERIFICATION ==='
  run_stage multidrive_audit 'Re-audit every mounted archive' || return 1
  echo '=== GUARDED OPTIONAL SOFTWARE STAGES ==='
  APP_RESULT=skipped
  LEFT_RESULT=skipped
  if run_stage package_apps_apply 'Remove approved unneeded applications'; then APP_RESULT='completed-or-not-needed'; else APP_RESULT='blocked'; echo 'STOP: application stage failed its guard'; return 1; fi
  safe_state || return 1
  if run_stage package_left_apply 'Remove leftover dependencies'; then LEFT_RESULT='completed-or-not-needed'; else LEFT_RESULT='blocked'; echo 'STOP: leftovers stage failed its guard'; return 1; fi
  safe_state || return 1
  run_stage snap_active_cleanup 'Remove approved active Snaps' || return 1
  safe_state || return 1
  run_stage snap_orphan_apply 'Retire orphan Snap mount units' || return 1
  safe_state || return 1
  # dmesg retry is best-effort (as in 1.0.0): it reports a WARNING instead of failing the visit.
  # It runs AFTER the time-out fix, which it requires (it refuses to retry while timeouts are 3s).
  run_stage dmesg_apply 'Retry the dmesg service' || true
  safe_state || return 1
  # ---- OS-drive video: all archives are mounted now, so offer to delete what WAVE wrote to the OS drive ----
  if (( A_OS_DIRS > 0 )) && helper_ok wrn_recovery.sh; then
    if tech_prompt "I found about $(human_bytes "$A_OS_BYTES") of WAVE video on the OS drive (recorded there while archive drives were offline). Delete it now?"; then
      run_stage os_video_delete 'Delete the video from the OS drive' || echo 'NOTE: the OS-drive video was not deleted (declined or stopped). It is still there.'
    else
      echo 'OS-drive video left in place.'
    fi
  fi
  echo '=== FINAL FREE SPACE ==='; df -h /
  record_service_history "$INITIAL_SPACE" "$(df -h / | awk 'NR==2{print $5 " used, " $4 " free"}')" 0 || return 1
  echo "PERMANENT HISTORY UPDATED — $WRN_DIR/WRN-Service-History.txt"
  echo 'Verify desktop and WAVE recording/playback before finalization.'
  echo "Maintenance log: $WRN_LOG"
}

# A visit that succeeded earlier but was never finalized: re-verify, then offer to finish.
verify_and_finish() {
  local slot
  echo 'Re-checking the recorder (read-only) before finishing...'
  safe_state || { echo 'The recorder is not in a safe state right now.'; return 1; }
  scan_slots
  for slot in "${SLOTS[@]}"; do
    [[ "${M_STATE[$slot]}" != offline ]] || { echo "/mnt/$slot is offline now."; return 1; }
    [[ "${M_STATE[$slot]}" != stale ]] || { echo "/mnt/$slot is a stale mount now. Restart the recorder."; return 1; }
  done
  run_stage final_kb_summary 'Verify logging, archive and Snap state' || return 1
  run_stage multidrive_audit 'Re-audit every mounted archive' || return 1
  finish_report ok
  tech_after_apply
}

# ---------------------------------- dispatch ----------------------------------
case "$MODE" in
  stage)    run_child_stage "$STAGE_NAME"; exit $? ;;
  finalize) finalize_visit; exit $? ;;
  check)    assess
            if (( ${#A_BLOCK[@]} )); then printf '\nSTOP: %s\n' "${A_BLOCK[*]}"; exit 1; fi
            (( ${#A_OFFLINE[@]} )) && { echo; echo "Offline archive drive(s): ${A_OFFLINE[*]}. A normal maintenance run will offer to fix them."; }
            echo; echo '--check: nothing was changed.'; exit 0 ;;
  guided)   guided; exit $? ;;
esac
