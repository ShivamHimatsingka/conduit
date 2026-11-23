#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Shivam Himatsingka
#
# Cross-process end-to-end test of Phase 2: a driver host process (stand-in for
# coreaudiod) and a separate Swift client (conduitctl) talking over Mach IPC +
# shared memory. Verifies handshake, routing matrix, gains, mute/solo, meters
# and app->driver injection with its published clock. No sudo needed.
set -uo pipefail
cd "$(dirname "$0")/.."
HOST=build/driver_host
CTL=.build/release/conduitctl
DRIVER=build/Conduit.driver/Contents/MacOS/Conduit
export CONDUIT_IPC_ALLOW_REGISTER=1

fails=0
check() { # name actual-expression expected-lo expected-hi
    if awk -v v="$2" -v lo="$3" -v hi="$4" 'BEGIN{exit !(v>=lo && v<=hi)}'; then printf "  ok    %-44s %s\n" "$1" "$2"
    else printf "  FAIL  %-44s %s (want %s..%s)\n" "$1" "$2" "$3" "$4"; fails=$((fails+1)); fi
}
val() { awk -v k="$1" -v c="$2" -v f="$3" '$1==k && $2==c {print $f}' <<<"$METERS"; }  # kind ch -> peak(4)/rms(6)
sample() { sleep 0.15; METERS="$($CTL meters "${1:-0.5}")"; }

"$HOST" "$DRIVER" 30 > build/host.log 2>&1 &
HPID=$!
trap 'kill $HPID 2>/dev/null; wait $HPID 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -q READY build/host.log && break; sleep 0.1; done
grep -q READY build/host.log || { echo "host failed to start:"; cat build/host.log; exit 1; }
sleep 0.5

echo "handshake"
INFO="$($CTL info)" || { echo "FAIL connect"; exit 1; }
check "channels" "$(awk '$1=="channels"{print $2}' <<<"$INFO")" 16 16
check "clock running" "$(awk '$1=="clock"{print ($5=="true")}' <<<"$INFO")" 1 1

echo "default identity routing"
$CTL reset; sample
check "in0 peak ~0.5" "$(val in 0 4)" 0.45 0.55
check "bus0 peak ~0.5" "$(val bus 0 4)" 0.45 0.55
check "bus3 silent" "$(val bus 3 4)" 0 0.001
check "in0 rms ~0.354" "$(val in 0 6)" 0.30 0.40

echo "routing matrix: in0 -> bus3 only"
$CTL route 3 0 1.0; $CTL route 0 0 0; sample
check "bus3 peak ~0.5" "$(val bus 3 4)" 0.45 0.55
check "bus0 silent" "$(val bus 0 4)" 0 0.001

echo "strip gain -6 dB"
$CTL gain in 0 -6; sample
check "bus3 peak ~0.25" "$(val bus 3 4)" 0.22 0.28
check "in0 meter is pre-fader (~0.5)" "$(val in 0 4)" 0.45 0.55

echo "bus gain -6 dB (cumulative -12 dB)"
$CTL gain bus 3 -6; sample
check "bus3 peak ~0.125" "$(val bus 3 4)" 0.11 0.14

echo "mute / solo"
$CTL gain in 0 0; $CTL gain bus 3 0; $CTL mute 0 on; sample
check "muted strip -> bus3 silent" "$(val bus 3 4)" 0 0.001
$CTL mute 0 off; $CTL solo 5 on; sample
check "other strip soloed -> bus3 silent" "$(val bus 3 4)" 0 0.001
$CTL solo 5 off; $CTL busmute 3 on; sample
check "bus muted -> bus3 silent" "$(val bus 3 4)" 0 0.001
$CTL busmute 3 off; sample
check "all restored -> bus3 ~0.5" "$(val bus 3 4)" 0.45 0.55

echo "app injection ring (Swift producer -> driver consumer, device clock)"
$CTL reset
$CTL tone 7 3 440 0.4 &
TPID=$!
sleep 1.0; sample 0.5
check "bus7 carries injected tone" "$(val bus 7 4)" 0.35 0.45
check "bus1 untouched" "$(val bus 1 4)" 0 0.001
wait $TPID

echo "unauthorised / bad service"
$CTL --service com.conduit.nonexistent info >/dev/null 2>&1; check "unknown service fails cleanly" "$?" 1 1

echo
kill $HPID 2>/dev/null; wait $HPID 2>/dev/null; trap - EXIT
if (( fails )); then echo "IPC E2E FAILED ($fails)"; exit 1; fi
echo "IPC E2E PASSED"
