#!/usr/bin/env bash
# Forward the iOS SIMULATOR's VoCal os_log output into the unified pipeline log
# (.logs/server.log), each line prefixed [ios] — so one grep follows a meal across
# server stages ([audio] [transcript] [parse] [store] [nudge]) AND the client.
#
# HONEST LIMITATION: this streams from a BOOTED SIMULATOR on this Mac (xcrun simctl).
# A fully headless agent with no simulator gets no [ios] lines — the server-side tags
# still trace the whole pipeline via /__dev/capture. A REAL DEVICE's logs are not
# reachable this way at all (use Console.app / the app's debug-events.jsonl).
#
# Usage: scripts/ios-log-stream.sh [udid]   (default: the pinned voice-test simulator
# from AGENTS.md, else the booted device)

set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .logs

UDID="${1:-B3428495-B3FC-42EA-8BCD-F743732FA1B7}"
xcrun simctl list devices | grep -q "$UDID.*Booted" || UDID="booted"

echo "[ios-log-stream] streaming VoCal logs from simulator ($UDID) -> .logs/server.log (tag [ios]) — Ctrl-C to stop"
xcrun simctl spawn "$UDID" log stream \
    --style compact \
    --predicate 'subsystem CONTAINS "com.vo-cal" OR subsystem CONTAINS "com.vocal" OR process == "VoCal"' \
  | sed -u 's/^/[ios] /' >> .logs/server.log
