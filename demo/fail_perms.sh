#!/usr/bin/env bash
#
# demo/fail_perms.sh - Demonstrates failure when a cron script lacks executable bit (+x)
# Cron attempts to execve() this script directly and fails with EACCES (Permission denied).
#
echo "If you can execute this directly, chmod +x is set. If chmod -x is set, execution fails."
exit 0

