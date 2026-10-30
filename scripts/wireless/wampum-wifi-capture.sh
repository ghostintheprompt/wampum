#!/usr/bin/env bash
# wampum-wifi-capture.sh — RoE-aware Wi-Fi capture for the Wampum workflow.
#
# Runs INSIDE the Kali (Linux) UTM guest, with the Alfa RTL8812AU passed through.
# It captures ONLY the BSSIDs you declare in a scope file — the rules of engagement —
# and writes each capture plus a SHA-256 manifest that Wampum (on macOS) ingests and
# pins into the case ledger as host evidence.
#
# It is fail-closed: no valid scope file, no declared targets, or no usable adapter ⇒
# it refuses to capture. It only ever locks onto the BSSIDs/channels you authorized;
# it does not sweep or capture networks you did not declare.
#
# AUTHORIZATION: capturing Wi-Fi you are not authorized to test is illegal. Only list
# BSSIDs covered by a written RoE (client engagement) or that you own (lab building).
#
# Usage:
#   sudo ./wampum-wifi-capture.sh --scope scope.json [--out DIR] [--validate]
#
# scope.json:
# {
#   "engagement_id": "client-x-2026-11",
#   "operator": "MDRN Red Team Sec",
#   "authorization": "Written RoE on file; capture limited to the BSSIDs below.",
#   "duration_seconds": 300,
#   "targets": [
#     { "bssid": "AA:BB:CC:DD:EE:FF", "channel": 36, "essid": "ClientCorp" }
#   ]
# }
set -euo pipefail

SCOPE=""
OUT=""
VALIDATE_ONLY=0
MON=""
BASE_IFACE=""

log()  { printf '[wampum-wifi] %s\n' "$*" >&2; }
die()  { printf '[wampum-wifi] ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  # Always try to restore managed mode and networking, even on error/Ctrl-C.
  if [ -n "$MON" ]; then airmon-ng stop "$MON" >/dev/null 2>&1 || true; fi
  systemctl start NetworkManager >/dev/null 2>&1 || service NetworkManager start >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

while [ $# -gt 0 ]; do
  case "$1" in
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --validate) VALIDATE_ONLY=1; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[ "$(id -u)" = "0" ] || die "Run with sudo (monitor mode needs root)."
[ -n "$SCOPE" ] || die "Declare a scope file: --scope scope.json"
[ -f "$SCOPE" ] || die "Scope file not found: $SCOPE"
command -v jq >/dev/null 2>&1 || die "jq is required. Install: sudo apt install -y jq"
command -v airmon-ng >/dev/null 2>&1 || die "aircrack-ng is required. Install: sudo apt install -y aircrack-ng"

# --- Parse and validate scope (fail-closed) ---------------------------------
ENGAGEMENT="$(jq -r '.engagement_id // empty' "$SCOPE")"
OPERATOR="$(jq -r '.operator // "unspecified"' "$SCOPE")"
AUTHZ="$(jq -r '.authorization // empty' "$SCOPE")"
DURATION="$(jq -r '.duration_seconds // 300' "$SCOPE")"
TARGET_COUNT="$(jq '.targets | length' "$SCOPE" 2>/dev/null || echo 0)"

[ -n "$ENGAGEMENT" ] || die "scope.engagement_id is required."
[ -n "$AUTHZ" ] || die "scope.authorization is required — record the RoE/ownership basis for this capture."
[ "$TARGET_COUNT" -ge 1 ] || die "Declare at least one target BSSID in scope.targets. Fail-closed: nothing is captured without a declared, authorized target."

# Validate every target has a well-formed BSSID and a channel before touching the radio.
BSSID_RE='^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
for i in $(seq 0 $((TARGET_COUNT - 1))); do
  B="$(jq -r ".targets[$i].bssid // empty" "$SCOPE")"
  C="$(jq -r ".targets[$i].channel // empty" "$SCOPE")"
  [[ "$B" =~ $BSSID_RE ]] || die "targets[$i].bssid is not a valid MAC: '$B'"
  [[ "$C" =~ ^[0-9]+$ ]] || die "targets[$i].channel must be a number: '$C'"
done
[[ "$DURATION" =~ ^[0-9]+$ ]] && [ "$DURATION" -ge 1 ] || die "duration_seconds must be a positive integer."

OUT="${OUT:-$PWD/wampum-captures/$ENGAGEMENT}"
mkdir -p "$OUT"

# --- Identify the Alfa interface --------------------------------------------
# Prefer an RTL8812AU; otherwise the first non-built-in wlan the guest exposes.
detect_iface() {
  local dev
  for dev in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
    echo "$dev"; return 0
  done
  return 1
}
BASE_IFACE="$(detect_iface || true)"
[ -n "$BASE_IFACE" ] || die "No wireless interface found. Confirm the Alfa (0bda:8812) is passed through to this guest and the rtl8812au driver is loaded (dmesg | grep 8812)."
log "Wireless interface: $BASE_IFACE"
log "Engagement: $ENGAGEMENT / operator: $OPERATOR / targets: $TARGET_COUNT / duration: ${DURATION}s each"

if [ "$VALIDATE_ONLY" = "1" ]; then
  log "Validate-only: scope OK, interface present. No monitor mode, no capture performed."
  exit 0
fi

# --- Monitor mode -----------------------------------------------------------
log "Stopping interfering services and enabling monitor mode (this drops Wi-Fi networking in the guest)."
airmon-ng check kill >/dev/null 2>&1 || true
airmon-ng start "$BASE_IFACE" >/dev/null 2>&1 || die "airmon-ng could not enable monitor mode on $BASE_IFACE."
# Resolve the monitor interface name (often <iface>mon, or the same name on newer drivers).
MON="$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | grep -E 'mon' || true)"
[ -n "$MON" ] || MON="$BASE_IFACE"
log "Monitor interface: $MON"

# --- Capture each declared target -------------------------------------------
STARTED="$(date -u +%FT%TZ)"
declare -a CAPFILES=()
INDEX=0
for i in $(seq 0 $((TARGET_COUNT - 1))); do
  B="$(jq -r ".targets[$i].bssid" "$SCOPE")"
  C="$(jq -r ".targets[$i].channel" "$SCOPE")"
  E="$(jq -r ".targets[$i].essid // \"\"" "$SCOPE")"
  INDEX=$((INDEX + 1))
  STEM="$OUT/cap-$(printf '%02d' "$INDEX")-${B//:/}"
  log "Capturing BSSID $B on channel $C (${E:-no-essid}) for ${DURATION}s → $STEM"
  # Locked to the one authorized BSSID and channel. timeout bounds the run.
  timeout "${DURATION}s" airodump-ng --bssid "$B" -c "$C" -w "$STEM" --output-format pcap,csv "$MON" >/dev/null 2>&1 || true
  for f in "$STEM"-01.cap "$STEM"-01.csv; do
    [ -f "$f" ] && CAPFILES+=("$f")
  done
done

# --- Manifest (hashed) ------------------------------------------------------
ENDED="$(date -u +%FT%TZ)"
MANIFEST="$OUT/manifest.json"
{
  printf '{\n'
  printf '  "tool": "wampum-wifi-capture",\n'
  printf '  "engagement_id": %s,\n' "$(jq -c '.engagement_id' "$SCOPE")"
  printf '  "operator": %s,\n' "$(jq -c '.operator // "unspecified"' "$SCOPE")"
  printf '  "authorization": %s,\n' "$(jq -c '.authorization' "$SCOPE")"
  printf '  "adapter": "RTL8812AU (0bda:8812)",\n'
  printf '  "interface": "%s",\n' "$MON"
  printf '  "started": "%s",\n' "$STARTED"
  printf '  "ended": "%s",\n' "$ENDED"
  printf '  "scope_sha256": "%s",\n' "$(sha256sum "$SCOPE" | awk '{print $1}')"
  printf '  "targets": %s,\n' "$(jq -c '.targets' "$SCOPE")"
  printf '  "files": [\n'
  n=${#CAPFILES[@]}
  for idx in "${!CAPFILES[@]}"; do
    f="${CAPFILES[$idx]}"
    h="$(sha256sum "$f" | awk '{print $1}')"
    sz="$(stat -c %s "$f" 2>/dev/null || wc -c < "$f")"
    sep=","
    [ "$idx" -eq $((n - 1)) ] && sep=""
    printf '    { "path": "%s", "sha256": "%s", "bytes": %s }%s\n' "$(basename "$f")" "$h" "$sz" "$sep"
  done
  printf '  ]\n'
  printf '}\n'
} > "$MANIFEST"

log "Done. Captured ${#CAPFILES[@]} file(s)."
log "Manifest: $MANIFEST"
log "Copy $OUT/ to the macOS host; Wampum ingests manifest.json + the .cap/.csv as host evidence."
