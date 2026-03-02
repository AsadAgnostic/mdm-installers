#!/bin/bash
set -euo pipefail

###############################################################################
# SentinelOne macOS installer (MDM-friendly)
# - Silent install
# - Skip if already installed
# - Logs to local file + stdout (MDM captures stdout)
#
# Required env vars:
#   S1_PKG_URL      = direct URL to SentinelOne PKG
#   S1_SITE_TOKEN   = SentinelOne site token (DO NOT commit to git)
#
# Optional env vars:
#   EXPECTED_SHA256 = verify download integrity
#   FORCE_REINSTALL = "true" to force reinstall/upgrade
###############################################################################

LOG_FILE="/var/log/mdm-sentinelone-install.log"
umask 077
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log(){ echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fail(){ log "ERROR: $*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "Must run as root/admin (MDM should run scripts as root)."

S1_PKG_URL="${S1_PKG_URL:-}"
S1_SITE_TOKEN="${S1_SITE_TOKEN:-}"
EXPECTED_SHA256="${EXPECTED_SHA256:-}"
FORCE_REINSTALL="${FORCE_REINSTALL:-false}"

[[ -n "$S1_PKG_URL" ]] || fail "S1_PKG_URL is required."
[[ -n "$S1_SITE_TOKEN" ]] || log "WARNING: S1_SITE_TOKEN not set. Install may succeed but may not register correctly."

SENTINELCTL="/usr/local/bin/sentinelctl"

is_s1_installed() {
  if [[ -x "$SENTINELCTL" ]] && "$SENTINELCTL" status >/dev/null 2>&1; then return 0; fi
  if [[ -d "/Applications/SentinelOne" ]]; then return 0; fi
  if /bin/ls /Library/LaunchDaemons 2>/dev/null | /usr/bin/grep -qi "sentinel"; then return 0; fi
  return 1
}

if [[ "$FORCE_REINSTALL" != "true" ]] && is_s1_installed; then
  log "SKIP: SentinelOne already installed. No action taken."
  exit 0
fi

TMP_DIR="$(mktemp -d)"
PKG_PATH="$TMP_DIR/SentinelOne.pkg"
trap 'rm -rf "$TMP_DIR" 2>/dev/null || true' EXIT

log "Downloading SentinelOne PKG..."
curl -fLsS --retry 3 --retry-delay 2 -o "$PKG_PATH" "$S1_PKG_URL" || fail "Download failed"

if ! file "$PKG_PATH" | grep -qi "xar archive"; then
  log "Downloaded file type: $(file "$PKG_PATH")"
  fail "Downloaded file does not look like a macOS .pkg. Check the URL."
fi

if [[ -n "$EXPECTED_SHA256" ]]; then
  ACTUAL_SHA256="$(shasum -a 256 "$PKG_PATH" | awk '{print $1}')"
  [[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || fail "SHA256 mismatch"
  log "SHA256 verified."
else
  log "SHA256 not set; skipping checksum verification."
fi

if [[ -n "$S1_SITE_TOKEN" ]]; then
  TOKEN_STAGING="/var/tmp/com.sentinelone.registration-token"
  printf "%s" "$S1_SITE_TOKEN" > "$TOKEN_STAGING"
  chmod 600 "$TOKEN_STAGING"
  chown root:wheel "$TOKEN_STAGING" || true
  log "Staged registration token file at $TOKEN_STAGING (token not logged)."
fi

log "Installing SentinelOne silently..."
/usr/sbin/installer -pkg "$PKG_PATH" -target / || fail "installer failed"

for _ in {1..20}; do [[ -x "$SENTINELCTL" ]] && break; sleep 2; done

if [[ -n "$S1_SITE_TOKEN" ]] && [[ -x "$SENTINELCTL" ]]; then
  log "Applying registration token via sentinelctl (token not logged)..."
  "$SENTINELCTL" set registration-token -- "$S1_SITE_TOKEN" >/dev/null 2>&1 || true
fi

if is_s1_installed; then
  log "SUCCESS: SentinelOne installed and detected as present."
  exit 0
fi

fail "Install did not validate. Check $LOG_FILE and the SentinelOne console."
