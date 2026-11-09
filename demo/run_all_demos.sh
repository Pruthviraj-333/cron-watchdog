#!/usr/bin/env bash
#
# demo/run_all_demos.sh - End-to-end demonstration of cron-watchdog failure modes
#
# Runs in an isolated sandbox directory (using environment variable overrides)
# so it can be executed safely as an unprivileged user without modifying /var or /etc.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CRONWATCH="${REPO_ROOT}/bin/cronwatch"

echo "============================================================"
echo "    cron-watchdog - Silent Failure Modes Demonstration      "
echo "============================================================"

# Create isolated sandbox directories
SANDBOX_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cronwatch-demo.XXXXXX" 2>/dev/null || mktemp -d)
trap 'rm -rf "${SANDBOX_DIR}"' EXIT

export CRONWATCH_LOG_DIR="${SANDBOX_DIR}/log"
export CRONWATCH_LOG_FILE="${SANDBOX_DIR}/log/jobs.log"
export CRONWATCH_STATE_DIR="${SANDBOX_DIR}/state"
export CRONWATCH_HEARTBEAT_DIR="${SANDBOX_DIR}/state/heartbeats"
export CRONWATCH_CONFIG_DIR="${SANDBOX_DIR}/config"
export CRONWATCH_CONFIG_FILE="${SANDBOX_DIR}/config/jobs.conf"

mkdir -p "$CRONWATCH_LOG_DIR" "$CRONWATCH_HEARTBEAT_DIR" "$CRONWATCH_CONFIG_DIR"

# Configure jobs to monitor
cat <<EOF > "$CRONWATCH_CONFIG_FILE"
# Format: <job-name> <max_age_minutes> [max_duration_seconds]
healthy-job        10    60
failed-exit1-job   10    60
hung-timeout-job   10    2
path-broken-job    10    60
unscheduled-job    5     60
EOF

echo "[*] Sandbox initialized at: ${SANDBOX_DIR}"
echo "[*] Monitored jobs in ${CRONWATCH_CONFIG_FILE}:"
cat "$CRONWATCH_CONFIG_FILE"
echo ""

# 1. Run healthy job
echo "------------------------------------------------------------"
echo "DEMO 1: Running a healthy job (should succeed)"
echo "------------------------------------------------------------"
"$CRONWATCH" run healthy-job -- bash -c "echo 'Healthy job ran successfully'; exit 0"
echo "[+] Healthy job exited 0. Heartbeat created at: ${CRONWATCH_HEARTBEAT_DIR}/healthy-job"
echo ""

# 2. Run failing job (exit 1 with stderr)
echo "------------------------------------------------------------"
echo "DEMO 2: Running a failing job (exit code 1 with stderr)"
echo "------------------------------------------------------------"
set +e
"$CRONWATCH" run failed-exit1-job -- bash "${SCRIPT_DIR}/fail_exit1.sh"
echo "[+] Wrapper caught non-zero exit. Heartbeat NOT updated."
set -e
echo ""

# 3. Run hanging job (timeout)
echo "------------------------------------------------------------"
echo "DEMO 3: Running a hung job with 2s timeout"
echo "------------------------------------------------------------"
set +e
"$CRONWATCH" run hung-timeout-job --timeout 2 -- bash "${SCRIPT_DIR}/fail_hang.sh"
echo "[+] Wrapper killed hung job with SIGKILL after timeout. Heartbeat NOT updated."
set -e
echo ""

# 4. Run PATH failure job
echo "------------------------------------------------------------"
echo "DEMO 4: Running a job that fails due to missing PATH tool"
echo "------------------------------------------------------------"
set +e
"$CRONWATCH" run path-broken-job -- bash "${SCRIPT_DIR}/fail_path.sh"
echo "[+] Wrapper caught missing binary error."
set -e
echo ""

# 5. Note on unscheduled job
echo "------------------------------------------------------------"
echo "DEMO 5: Unscheduled job (never ran, no heartbeat)"
echo "------------------------------------------------------------"
echo "[+] 'unscheduled-job' was intentionally never executed."
echo ""

# 6. Run cronwatch check
echo "============================================================"
echo "DEMO 6: Running 'cronwatch check' (detects all failures)"
echo "============================================================"
set +e
"$CRONWATCH" check
CHECK_STATUS=$?
set -e
echo ""
echo "Exit code of cronwatch check: ${CHECK_STATUS} (1 indicates failures detected)"
echo ""

# 7. Run cronwatch doctor
echo "============================================================"
echo "DEMO 7: Running 'cronwatch doctor' (environment diagnostics)"
echo "============================================================"
set +e
"$CRONWATCH" doctor "${SCRIPT_DIR}"/fail_*.sh
set -e
echo ""

# 8. Test alerting
echo "============================================================"
echo "DEMO 8: Testing alert dispatch via 'cronwatch test-alert'"
echo "============================================================"
"$CRONWATCH" test-alert "demo-alert-check"
echo ""

echo "============================================================"
echo "        Demonstration of all failure modes complete!        "
echo "============================================================"

