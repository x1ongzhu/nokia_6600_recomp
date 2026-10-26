#!/bin/sh
# check_thumb.sh LOG MIN - assert the Thumb instruction count in LOG is >= MIN.
#
# Round 111: application tests used to assert the *outer* stop reason.  With the
# mask-ROM hand-off (NK_HANDOFF_PC) the application thread is dispatched from a
# kernel that has already reached its entry sentinel, so when the application
# returns, the supervisor resumes into that sentinel and the run reports
# "self-branch at 0x50312b88" instead of an unwind through the harness frame.
# The application-side signal is the Thumb instruction count, so assert that.
set -eu
log=$1
min=$2
thumb=$(sed -n 's/.*Thumb \([0-9][0-9]*\)).*/\1/p' "$log" | tail -1)
if [ -z "$thumb" ] || [ "$thumb" -lt "$min" ]; then
    echo "FAIL: $log ran ${thumb:-0} Thumb instructions, expected at least $min" >&2
    exit 1
fi
echo "    $(basename "$log"): Thumb $thumb (>= $min)"
