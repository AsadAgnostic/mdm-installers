# SentinelOne macOS Deployment (MDM-Agnostic)

This guide provides a silent, idempotent SentinelOne macOS install script that works in most MDMs.

## Requirements
- MDM must run scripts as **root/admin**
- A direct-download URL to the SentinelOne **PKG**
- A SentinelOne **Site Token**

> Do not commit tokens to GitHub.

## Configure
Set environment variables in your MDM/script runner:

- `S1_PKG_URL` (required)
- `S1_SITE_TOKEN` (recommended)
- `EXPECTED_SHA256` (optional)
- `FORCE_REINSTALL=true` (optional)

## Install behavior
- If SentinelOne is already installed → script prints: `SKIP: SentinelOne already installed.`
- If not installed → downloads + installs silently + logs to:
  - `/var/log/mdm-sentinelone-install.log`
  - stdout (captured by the MDM)

## Notes on “silent / no user prompts”
The PKG install is silent, but macOS may still prompt users unless you deploy the required MDM configuration profiles:
- System/Network Extension allowlist
- PPPC/TCC permissions (as required by your S1 configuration)
- Notifications (optional)

See your SentinelOne macOS deployment documentation for the exact identifiers needed.
