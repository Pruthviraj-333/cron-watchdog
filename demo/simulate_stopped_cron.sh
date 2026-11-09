#!/usr/bin/env bash
#
# demo/simulate_stopped_cron.sh - Demonstrates stopping the cron daemon to trigger doctor failure
#
set -euo pipefail

echo "Stopping cron service to simulate cron daemon failure..."
if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl stop cron 2>/dev/null || sudo systemctl stop crond 2>/dev/null || true
elif command -v service >/dev/null 2>&1; then
    sudo service cron stop 2>/dev/null || sudo service crond stop 2>/dev/null || true
fi

echo "Cron daemon stopped. Running 'cronwatch doctor' to diagnose..."
bin/cronwatch doctor || true

echo ""
echo "Restarting cron service..."
if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl start cron 2>/dev/null || sudo systemctl start crond 2>/dev/null || true
elif command -v service >/dev/null 2>&1; then
    sudo service cron start 2>/dev/null || sudo service crond start 2>/dev/null || true
fi
echo "Cron service restored."

