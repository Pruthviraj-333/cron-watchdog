#!/usr/bin/env bash
#
# demo/fail_exit1.sh - Simulates a cron script failing with exit code 1
# Writes diagnostic error details to stderr.
#

echo "[info] Starting simulated database backup job..."
echo "[info] Connecting to database cluster postgres-prod-01..." >&2

# Simulate error after 1 second
sleep 1
echo "pg_dump: error: connection to server on socket \"/var/run/postgresql/.s.PGSQL.5432\" failed: Connection refused" >&2
echo "pg_dump: error: Is the server running locally and accepting connections?" >&2
echo "pg_dump: error: fatal: database backup aborted due to connection failure" >&2

exit 1

