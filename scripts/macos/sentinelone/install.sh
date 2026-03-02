#!/bin/bash
set -euo pipefail

###############################################################################
# SentinelOne macOS install (MDM Script) - v2 hardened
# - Silent install (installer)
# - Skip if already installed (sentinelctl + receipts + app)
# - Logs to local file + stdout (MDM captures stdout)
###############################################################################

### ====== CONFIG ==============================================================
S1_PKG_URL="https://github.com/AsadAgnostic/mdm-installers/releases/download/s1-macos-25.4.1-8462/Sentinel-Release-25-4-1-8462_macos_v25_4_1_8462.pkg"
S1_SITE_TOKEN="PASTE_YOUR_SITE_TOKEN_HERE"

# Optional integrity and signing checks (recommended)
EXPECTED_SHA256=""                 # sha256 of pkg (leave blank to skip)
EXPECTED_TEAM_ID=""                # set if you want to enforce pkg signer Team ID (leave blank to skip)

FORCE_REINSTALL="false"
LOG_FILE="/var/log/mdm-sentinelone-install.log"
### ===========================================================================

umask 077
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log(){ echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fail(){ log "ERROR: $*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "Must run as root/admin. Configure your MDM to run scripts as root."

SENTINELCTL="/usr/local/bin/sentinelctl"

# Try to detect a SentinelOne package receipt (names vary by version/vendor packaging)
has_s1_receipt() {
  # Common patterns; adjust if you know the exact receipt id from your installer
  pkgutil --pkgs 2>/dev/null | grep -Ei 'sentinelone|sentinel' >/dev/null 2>&1
}

is_s1_installed() {
  if [[ -x "$SENTINELCTL" ]] && "$SENTINELCTL" status >/dev/null 2>&1; then return 0; fi
  if [[ -d "/Applications/SentinelOne" ]]; then return 0; fi
  if has_s1_receipt; then return 0; fi
  # Narrower daemon check than "sentinel" to reduce false positives
  if /bin/ls /Library/LaunchDaemons 2>/dev/null | /usr/bin/grep -qi "sentinelone"; then return 0; fi
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
curl -fLsS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 900 -o "$PKG_PATH" "$S1_PKG_URL" || fail "Download failed"

# Ensure it’s a real pkg
if ! file "$PKG_PATH" | grep -qi "xar archive"; then
  log "Downloaded file type: $(file "$PKG_PATH")"
  fail "Downloaded file does not look like a macOS .pkg (XAR). Check the URL."
fi

# Optional checksum verification
if [[ -n "$EXPECTED_SHA256" ]]; then
  ACTUAL_SHA256="$(shasum -a 256 "$PKG_PATH" | awk '{print $1}')"
  [[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || fail "SHA256 mismatch"
  log "SHA256 verified."
else
  log "SHA256 not set; skipping checksum verification."
fi

# Optional signature verification
if [[ -n "$EXPECTED_TEAM_ID" ]]; then
  SIG_OUT="$(/usr/sbin/pkgutil --check-signature "$PKG_PATH" 2>/dev/null || true)"
  echo "$SIG_OUT" | grep -qi "Status: signed" || fail "PKG does not appear signed"
  echo "$SIG_OUT" | grep -q "$EXPECTED_TEAM_ID" || fail "Signer Team ID mismatch (expected $EXPECTED_TEAM_ID)"
  log "PKG signature verified (Team ID matched)."
else
  log "EXPECTED_TEAM_ID not set; skipping signature verification."
fi

# Stage token (do not log it)
if [[ -n "$S1_SITE_TOKEN" ]]; then
  TOKEN_STAGING="/var/tmp/com.sentinelone.registration-token"
  printf "%s" "$S1_SITE_TOKEN" > "$TOKEN_STAGING"
  chmod 600 "$TOKEN_STAGING"
  chown root:wheel "$TOKEN_STAGING" || true
  log "Staged registration token file at $TOKEN_STAGING (token not logged)."
else
  log "WARNING: No S1_SITE_TOKEN set. Install may succeed but may not register correctly."
fi

log "Installing SentinelOne silently..."
/usr/sbin/installer -pkg "$PKG_PATH" -target / || fail "installer failed"

# Wait for sentinelctl
for _ in {1..30}; do
  [[ -x "$SENTINELCTL" ]] && break
  sleep 2
done

# Token fallback via sentinelctl (silent)
if [[ -n "$S1_SITE_TOKEN" ]] && [[ -x "$SENTINELCTL" ]]; then
  log "Applying registration token via sentinelctl (token not logged)..."
  "$SENTINELCTL" set registration-token -- "$S1_SITE_TOKEN" >/dev/null 2>&1 || true
fi

# Validate
if is_s1_installed; then
  log "SUCCESS: SentinelOne installed and detected as present."
  exit 0
fi

fail "Install did not validate. Check $LOG_FILE and the SentinelOne console."
