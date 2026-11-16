#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/iso.sh"

download_iso "$DEBIAN_ISO_URL" "$DEBIAN_ISO_PATH" "$DEBIAN_SHA256SUMS_URL"
download_iso "$PROXMOX_ISO_URL" "$PROXMOX_ISO_PATH" "$PROXMOX_SHA256SUMS_URL"
