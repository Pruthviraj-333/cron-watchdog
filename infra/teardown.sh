#!/usr/bin/env bash
#
# infra/teardown.sh - Cleanly destroys all AWS resources created for cron-watchdog
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "============================================================"
echo "    cron-watchdog Infrastructure Teardown                   "
echo "============================================================"
echo "This will destroy all resources tagged project=cron-watchdog."
read -p "Are you sure you want to proceed with teardown? (y/N): " -r confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Teardown cancelled."
    exit 0
fi

echo "Running terraform destroy..."
terraform destroy -auto-approve

echo "Teardown complete. All AWS resources deleted."

