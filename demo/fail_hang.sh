#!/usr/bin/env bash
#
# demo/fail_hang.sh - Simulates a cron script hanging indefinitely
# Simulates a deadlocked process, network hang, or unkillable wait.
# When wrapped with 'cronwatch run --timeout 5', timeout will kill it.
#

echo "[info] Starting simulated data synchronization job..."
echo "[info] Attempting to acquire distributed lock on s3://prod-data-lock..."
echo "[info] Waiting for remote API socket response (hanging)..." >&2

# Sleep longer than the configured timeout threshold
sleep 60

echo "[info] This line should never be reached if timeout killed the job."
exit 0

