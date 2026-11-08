#!/usr/bin/env bash
# Hanwha WRN installer 2.0.0-rc.2
# NOTICE: This is an independent field-support tool, developed through hands-on testing on Hanwha WRN
# recorders. It is NOT an official Hanwha product and is NOT supported by Hanwha. It is provided as-is,
# based on real-world field experience. Use it at your own discretion and judgment.
# Downloads and verifies the scripts. It starts maintenance ONLY if the technician answers yes at the end.
# Production: wget -qO- https://raw.githubusercontent.com/bbradford1/wrn-patch/main/installer.sh | bash
# Lab-only: bash installer.sh --local-source PATH --target-dir PATH   (or --offline-bundle ABSOLUTE_DIR)
#   Ubuntu 22.04 (Gen 2): wrn_maintenance.sh + wrn_diagnose.sh + wrn_recovery.sh
#   Ubuntu 18.04 (Gen 1): wrn_legacy_maintenance.sh + wrn_diagnose.sh
# >>> ORIGINAL installer.sh:6-8
set -Eeuo pipefail
export LC_ALL=C
umask 077
# <<< ORIGINAL
VERSION='2.0.0-rc.2'
BASE_URL='https://raw.githubusercontent.com/bbradford1/wrn-patch/main'
# >>> ORIGINAL installer.sh:11-29
LOCAL_SOURCE=''
TARGET_DIR=''
OFFLINE_BUNDLE='' 
fail(){ echo "STOP: $*" >&2; exit 1; }
usage(){ printf '%s\n' 'Usage: bash installer.sh --offline-bundle ABSOLUTE_DIR' 'Or: bash installer.sh --local-source DIR --target-dir DIR' 'Default (no flags) downloads from GitHub; use offline-bundle to avoid network.'; }
while (( $# )); do
  case "$1" in
    --offline-bundle) (( $# >= 2 )) || fail 'Missing --offline-bundle path'; OFFLINE_BUNDLE="$2"; shift 2 ;;
    --local-source) (( $# >= 2 )) || fail 'Missing --local-source path'; LOCAL_SOURCE="$2"; shift 2 ;;
    --target-dir) (( $# >= 2 )) || fail 'Missing --target-dir path'; TARGET_DIR="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unexpected argument: $1" ;;
  esac
done
(( EUID != 0 )) || fail 'Run installer as normal wave user (not sudo).'
[[ -r /etc/os-release ]] || fail 'Missing OS release information.'
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || fail "Unsupported OS: ${PRETTY_NAME:-unknown}"
case "${VERSION_ID:-}" in
# <<< ORIGINAL
  22.04) FILES=(wrn_maintenance.sh wrn_diagnose.sh wrn_recovery.sh) ;;
  18.04) FILES=(wrn_legacy_maintenance.sh wrn_diagnose.sh) ;;
# >>> ORIGINAL installer.sh:32-57
  *) fail "Unsupported Ubuntu release: ${VERSION_ID:-unknown}" ;;
esac
[[ -n "${HOME:-}" && "$HOME" == /* && -d "$HOME" ]] || fail 'Unrecognized home directory.'
if [[ -n "$OFFLINE_BUNDLE" ]]; then
  [[ -z "$LOCAL_SOURCE" && -z "$TARGET_DIR" ]] || fail 'Cannot combine offline-bundle with other source/target flags.'
  [[ "$OFFLINE_BUNDLE" == /* && -d "$OFFLINE_BUNDLE" && ! -L "$OFFLINE_BUNDLE" ]] || fail 'Offline bundle must be an absolute real directory.'
  LOCAL_SOURCE="$OFFLINE_BUNDLE"
  TARGET_DIR="$HOME/Downloads/maintenance"
  echo 'MODE: OFFLINE BUNDLE; GitHub not accessed and maintenance will NOT run.'
elif [[ -n "$LOCAL_SOURCE" || -n "$TARGET_DIR" ]]; then
  [[ -n "$LOCAL_SOURCE" && -n "$TARGET_DIR" ]] || fail 'Lab mode requires BOTH --local-source and --target-dir.'
  [[ "$LOCAL_SOURCE" == /* && -d "$LOCAL_SOURCE" && ! -L "$LOCAL_SOURCE" ]] || fail 'Local source must be an absolute real directory.'
  [[ "$TARGET_DIR" == "$HOME"/Downloads/* && "$TARGET_DIR" != "$HOME/Downloads/maintenance" ]] || fail 'Lab destination must be a separate absolute directory under ~/Downloads (not production maintenance).'
  [[ "$TARGET_DIR" != "$LOCAL_SOURCE" ]] || fail 'Source and target cannot match.'
  echo 'MODE: LOCAL TEST; GitHub not accessed and maintenance will NOT run.'
else
  TARGET_DIR="$HOME/Downloads/maintenance"
  echo 'MODE: DOWNLOAD ONLY; GitHub source, no maintenance actions.'
fi
for cmd in sha256sum mktemp mv chmod mkdir rm grep bash head; do command -v "$cmd" >/dev/null || fail "Missing tool: $cmd"; done
mkdir -p -- "$TARGET_DIR"
[[ -d "$TARGET_DIR" && ! -L "$TARGET_DIR" && -w "$TARGET_DIR" ]] || fail 'Target path is not a writable real directory.'
[[ ! -e "$TARGET_DIR/WRN-Service-History.txt" || -f "$TARGET_DIR/WRN-Service-History.txt" ]] || fail 'Unexpected service history file type.'
# All downloads are staged and independently checked before installing ANY script.
STAGE="$(mktemp -d "$TARGET_DIR/.wrn-install-stage.XXXXXXXX")" || fail 'Cannot make secure staging folder.'
trap 'rm -rf -- "$STAGE"' EXIT
# <<< ORIGINAL
# SHA-256 pins are written by tools/build.py from the exact files in this commit.
expected_sha(){ case "$1" in
  wrn_maintenance.sh) printf "%s\n" "aed20880801a7cd09058fe05566b05ade552670a1488cf2e0ec2da8f153b52dd";;
  wrn_diagnose.sh) printf "%s\n" "c46db07d62220002c38a91b8f885b3dab2fc496886288e9f703071791202e869";;
  wrn_recovery.sh) printf "%s\n" "8cecb13c6e194852aaa19ae819dafa1ef8e695f23dea04ebfa5ca465a1ec38cb";;
  wrn_legacy_maintenance.sh) printf "%s\n" "9d5ff78c44fe30141d17a372a8101f0e7cf36b10ea7d067625a6ca7a37c9fe2c";;
  *) return 1;;
esac; }
# >>> ORIGINAL installer.sh:70-99
for f in "${FILES[@]}"; do
  case "$f" in wrn_*.sh) ;; *) fail 'Unsafe installer manifest name';; esac
  out="$STAGE/$f"
  if [[ -n "$LOCAL_SOURCE" ]]; then
    [[ -f "$LOCAL_SOURCE/$f" && ! -L "$LOCAL_SOURCE/$f" ]] || fail "Missing local source: $f"
    cp -- "$LOCAL_SOURCE/$f" "$out" || fail "Copy failed: $f"
  else
    if command -v wget >/dev/null 2>&1; then
      wget -q --https-only --timeout=20 --tries=2 -O "$out" "$BASE_URL/$f" || fail "Download failed: $f"
    elif command -v curl >/dev/null 2>&1; then
      curl --fail --location --silent --show-error --connect-timeout 10 --max-time 90 --proto '=https' --proto-redir '=https' --output "$out" "$BASE_URL/$f" || fail "Download failed: $f"
    else fail 'Requires wget or curl'; fi
  fi
  [[ -s "$out" ]] || fail "Empty script: $f"
  actual="$(sha256sum "$out" | awk '{print $1}')"
  [[ "$actual" == "$(expected_sha "$f")" ]] || fail "SHA-256 mismatch for $f; NO scripts published"
  bash -n "$out" || fail "Bash syntax failed for $f"
  [[ "$(head -n1 "$out")" == '#!/usr/bin/env bash' ]] || fail "Invalid script header for $f"
  if grep -q $'\r' "$out"; then fail "CRLF line ending rejected for $f"; fi
  chmod 0644 "$out"
  printf 'VERIFIED %s %s\n' "$f" "$actual"
done
# Refuse symlink destination replacement; do not disturb pre-existing service history.
for f in "${FILES[@]}"; do
  [[ ! -L "$TARGET_DIR/$f" ]] || fail "Target symlink rejected: $f"
done
for f in "${FILES[@]}"; do
  mv -f -- "$STAGE/$f" "$TARGET_DIR/$f" || fail "Publishing failed: $f"
done
printf '\nINSTALL COMPLETE: %s verified scripts in %s\n' "${#FILES[@]}" "$TARGET_DIR"
# <<< ORIGINAL
if [[ "${VERSION_ID:-}" == 18.04 ]]; then
  RUN_CMD='sudo bash wrn_legacy_maintenance.sh'; WHAT='maintenance'
else
  RUN_CMD='sudo bash wrn_maintenance.sh'; WHAT='maintenance'
fi
ANSWER=''
if ( : < /dev/tty ) 2>/dev/null && ( : > /dev/tty ) 2>/dev/null; then
  while true; do
    printf '\nStart %s now? (yes/no): ' "$WHAT" > /dev/tty
    IFS= read -r ANSWER < /dev/tty || { ANSWER=no; break; }
    case "${ANSWER,,}" in y|yes) ANSWER=yes; break ;; n|no) ANSWER=no; break ;; *) echo 'Please type yes or no.' > /dev/tty ;; esac
  done
else
  ANSWER=no
fi
if [[ "$ANSWER" == yes ]]; then
  rm -rf -- "$STAGE"
  cd "$TARGET_DIR" && exec $RUN_CMD < /dev/tty
fi
printf '\nOK, nothing has been started. When you are ready, type exactly this and press Enter:\n\n    cd %s && %s\n\n' "$TARGET_DIR" "$RUN_CMD"
