#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."

verify_log=build/release-verify-job.log
cross_log=build/release-cross-job.log
bash release/verify.sh >"$verify_log" 2>&1 &
verify_pid=$!
bash release/cross_check.sh >"$cross_log" 2>&1 &
cross_pid=$!
status=0
wait "$verify_pid" || status=1
wait "$cross_pid" || status=1
cat "$verify_log" "$cross_log"
exit "$status"
