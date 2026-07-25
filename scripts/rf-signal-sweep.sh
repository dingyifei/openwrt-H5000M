#!/usr/bin/env bash
#
# rf-signal-sweep.sh — rough RF signal-vs-TXpower sweep for the H5000M, measured
# from THIS macOS machine's Wi-Fi radio. Meant to be run MANUALLY, next to the
# router at a fixed distance.
#
# Two modes:
#   passive  — CoreWLAN active scan for the AP's BEACON RSSI. Does NOT associate,
#              does NOT touch your internet. LIMITATION (measured 2026-07-25 on this
#              unit): beacon RSSI is ~flat across a 20 dB TXpower swing, so this mode
#              canNOT actually sense TXpower changes. Kept for a quick "is it alive /
#              how strong" reading only.
#   assoc    — briefly associates en0 to the H5000M, reads the LIVE associated RSSI
#              (real-time, not scan-cached) across a router TXpower sweep, then
#              DISASSOCIATES and reconnects your original Wi-Fi network. This is the
#              only mode that reliably reflects router TXpower. It interrupts en0
#              internet for the duration of the run (~1-2 min); ethernet is untouched.
#
# EVERYTHING is restored on exit (even Ctrl-C): router TXpower -> auto, and in assoc
# mode your Mac Wi-Fi -> original network.
#
# Usage:
#   KEY=<ap-pass> ./rf-signal-sweep.sh              # assoc mode, 5 GHz, default power list
#   MODE=passive ./rf-signal-sweep.sh               # non-disruptive beacon scan (no KEY needed)
#   KEY=<ap-pass> BAND=24 ./rf-signal-sweep.sh      # 2.4 GHz
#   KEY=<ap-pass> POWERS="6 10 14 20 23" ./rf-signal-sweep.sh
#
set -uo pipefail

# ---- config (override via env) ------------------------------------------------
ROUTER=${ROUTER:-root@192.168.10.1}
SSID=${SSID:-H5000M}
KEY=${KEY:-}                  # AP passphrase — set via env for assoc mode, e.g. KEY=xxxx ./rf-signal-sweep.sh
WIFI_IF=${WIFI_IF:-en0}
MODE=${MODE:-assoc}            # assoc | passive
BAND=${BAND:-5}               # 5 | 24
SETTLE=${SETTLE:-6}          # seconds to settle after each TXpower change
SCANS=${SCANS:-3}            # samples per power level
if [ "$BAND" = "5" ]; then AP=phy0.1-ap0; CHMIN=36; POWERS=${POWERS:-"3 6 10 14 18 20 23"};
else                       AP=phy0.0-ap0; CHMIN=0;  POWERS=${POWERS:-"3 6 10 14 17 20"}; fi

SSH() { ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 "$ROUTER" "$@"; }

# ---- CoreWLAN scanner (passive RSSI, no association) ---------------------------
SWIFT=$(mktemp /tmp/rfscan.XXXXXX.swift)
cat > "$SWIFT" <<'SW'
import CoreWLAN
let name = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "H5000M"
guard let i = CWWiFiClient.shared().interface() else { print("ERR"); exit(1) }
if let ns = try? i.scanForNetworks(withName: name) {
  for n in ns { print("\(n.wlanChannel?.channelNumber ?? 0) \(n.rssiValue)") }
}
SW
scan_beacon() { swift "$SWIFT" "$SSID" 2>/dev/null | awk -v c="$CHMIN" -v b="$BAND" \
  '{ if ((b=="5" && $1>=36) || (b=="24" && $1<=14)) print $2 }' | sort -n | tail -1; }

# live associated RSSI from macOS (real-time, not scan-cached)
assoc_rssi() { system_profiler SPAirPortDataType 2>/dev/null \
  | awk '/Current Network Information/{f=1} f&&/Signal \/ Noise/{print $4; exit}'; }

# ---- restore handler ----------------------------------------------------------
ORIG_NET=""
restore() {
  echo ""
  echo ">> restoring router TXpower ($AP) -> auto"
  SSH "iw dev $AP set txpower auto" 2>/dev/null || true
  if [ "$MODE" = "assoc" ]; then
    echo ">> restoring Mac Wi-Fi ($WIFI_IF)"
    networksetup -removepreferredwirelessnetwork "$WIFI_IF" "$SSID" >/dev/null 2>&1 || true
    networksetup -setairportpower "$WIFI_IF" off >/dev/null 2>&1 || true
    networksetup -setairportpower "$WIFI_IF" on  >/dev/null 2>&1 || true
    if [ -n "$ORIG_NET" ] && [ "$ORIG_NET" != "none" ]; then
      networksetup -setairportnetwork "$WIFI_IF" "$ORIG_NET" >/dev/null 2>&1 || true
      echo "   (asked $WIFI_IF to rejoin '$ORIG_NET'; it may also auto-rejoin)"
    fi
  fi
  rm -f "$SWIFT"
}
trap restore EXIT INT TERM

# ---- preflight ----------------------------------------------------------------
echo "== rf-signal-sweep =="
echo "router=$ROUTER  ap=$AP  band=${BAND}GHz  mode=$MODE  powers=[$POWERS]"
if ! SSH true 2>/dev/null; then echo "ERROR: cannot ssh $ROUTER"; exit 1; fi
if ! command -v swift >/dev/null 2>&1; then echo "ERROR: swift (Xcode CLT) required"; exit 1; fi

if [ "$MODE" = "assoc" ]; then
  if [ -z "$KEY" ]; then echo "ERROR: assoc mode needs the AP passphrase: KEY=xxxx $0"; exit 1; fi
  cur=$(networksetup -getairportnetwork "$WIFI_IF" 2>/dev/null | sed 's/^.*: //')
  case "$cur" in *"not associated"*) ORIG_NET="none";; *) ORIG_NET="$cur";; esac
  echo "Mac original network: ${ORIG_NET}"
  echo ">> associating $WIFI_IF -> $SSID (en0 internet will be interrupted until restore)"
  networksetup -setairportnetwork "$WIFI_IF" "$SSID" "$KEY" >/dev/null 2>&1
  sleep 5
fi

# ---- sweep --------------------------------------------------------------------
printf "\n%-14s %-16s %-s\n" "set(dBm)" "router_actual" "measured_RSSI(dBm)"
for p in $POWERS; do
  SSH "iw dev $AP set txpower fixed $((p*100))" 2>/dev/null
  act=$(SSH "iw dev $AP info 2>/dev/null | grep -oE '[0-9.]+ dBm' | head -1")
  sleep "$SETTLE"
  best=""; samples=""
  for s in $(seq 1 "$SCANS"); do
    if [ "$MODE" = "assoc" ]; then v=$(assoc_rssi); else v=$(scan_beacon); fi
    v=${v//[!0-9-]/}
    [ -n "$v" ] && { samples="$samples $v"; { [ -z "$best" ] || [ "$v" -gt "$best" ]; } && best=$v; }
    sleep 1
  done
  # also grab the router-side view of this Mac (uplink signal + rates), assoc only
  extra=""
  if [ "$MODE" = "assoc" ]; then
    extra=$(SSH "iw dev $AP station dump 2>/dev/null | grep -E 'signal:|tx bitrate' | tr '\n' ' '")
  fi
  printf "%-14s %-16s best=%-6s [%s ] %s\n" "$p" "${act:-?}" "${best:-n/a}" "$samples" "$extra"
done

echo ""
echo "note: 'passive' beacon RSSI does not track TXpower on this unit (measured);"
echo "      use assoc mode for a real signal-vs-power curve. All settings restored on exit."
