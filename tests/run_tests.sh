#!/usr/bin/env bash
#
# tests/run_tests.sh - Comprehensive automated test suite for cronwatch
#
# Runs pure Bash unit and integration tests in an isolated sandbox.
# Requires no external test frameworks (works on any Linux environment).
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CRONWATCH="${REPO_ROOT}/bin/cronwatch"

PASSED=0
FAILED=0
TOTAL=0

# Colors for terminal output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-assertion failed}"
    if [[ "$expected" != "$actual" ]]; then
        echo -e "${RED}[FAIL]${NC} ${msg}: expected '$expected', got '$actual'" >&2
        return 1
    fi
    return 0
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-assertion failed}"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo -e "${RED}[FAIL]${NC} ${msg}: '$needle' not found in output" >&2
        return 1
    fi
    return 0
}

run_test() {
    local test_name="$1"
    TOTAL=$(( TOTAL + 1 ))
    echo -n "Running ${test_name}... "

    # Set up per-test isolated sandbox
    local test_sandbox
    test_sandbox=$(mktemp -d "${TMPDIR:-/tmp}/cronwatch-test.XXXXXX" 2>/dev/null || mktemp -d)

    # Export test environment variables
    export CRONWATCH_LOG_DIR="${test_sandbox}/log"
    export CRONWATCH_LOG_FILE="${test_sandbox}/log/jobs.log"
    export CRONWATCH_STATE_DIR="${test_sandbox}/state"
    export CRONWATCH_HEARTBEAT_DIR="${test_sandbox}/state/heartbeats"
    export CRONWATCH_CONFIG_DIR="${test_sandbox}/config"
    export CRONWATCH_CONFIG_FILE="${test_sandbox}/config/jobs.conf"
    export CRONWATCH_SNS_TOPIC_ARN=""

    mkdir -p "$CRONWATCH_LOG_DIR" "$CRONWATCH_HEARTBEAT_DIR" "$CRONWATCH_CONFIG_DIR"

    # Execute the test function
    local status=0
    if "$test_name" "$test_sandbox"; then
        echo -e "${GREEN}PASS${NC}"
        PASSED=$(( PASSED + 1 ))
    else
        echo -e "${RED}FAIL${NC}"
        FAILED=$(( FAILED + 1 ))
        status=1
    fi

    # Clean up sandbox
    rm -rf "$test_sandbox"
    return "$status"
}

# ==============================================================================
# Test Cases
# ==============================================================================

# Test 1: Successful job execution updates heartbeat and logs JSON record
test_run_success() {
    local sandbox="$1"
    local out
    out=$("$CRONWATCH" run sample-job -- bash -c "echo 'all good'; exit 0")

    # Verify exit code
    assert_equals "0" "$?" "Job should exit 0"

    # Verify heartbeat exists
    local hb="${CRONWATCH_HEARTBEAT_DIR}/sample-job"
    if [[ ! -f "$hb" ]]; then
        echo "Heartbeat file missing: $hb" >&2
        return 1
    fi

    # Verify JSON log file contents
    if [[ ! -f "$CRONWATCH_LOG_FILE" ]]; then
        echo "Log file missing: $CRONWATCH_LOG_FILE" >&2
        return 1
    fi

    local log_content
    log_content=$(cat "$CRONWATCH_LOG_FILE")
    assert_contains "$log_content" '"job_name":"sample-job"' "Log should contain job_name"
    assert_contains "$log_content" '"status":"SUCCESS"' "Log should contain status SUCCESS"
    assert_contains "$log_content" '"exit_code":0' "Log should contain exit_code 0"
}

# Test 2: Failing job propagates exit code and does NOT update heartbeat
test_run_failure_propagation() {
    local sandbox="$1"
    set +e
    "$CRONWATCH" run fail-job -- bash -c "echo 'fatal database error' >&2; exit 42"
    local code=$?
    set -e

    assert_equals "42" "$code" "Wrapper must propagate exit code 42"

    # Heartbeat must NOT be created
    local hb="${CRONWATCH_HEARTBEAT_DIR}/fail-job"
    if [[ -f "$hb" ]]; then
        echo "Heartbeat should not exist for failed job: $hb" >&2
        return 1
    fi

    # Stderr must be recorded in jobs.log
    local log_content
    log_content=$(cat "$CRONWATCH_LOG_FILE")
    assert_contains "$log_content" '"status":"FAILED"' "Log status should be FAILED"
    assert_contains "$log_content" '"exit_code":42' "Log exit_code should be 42"
    assert_contains "$log_content" "fatal database error" "Log stderr_tail should capture error"
}

# Test 3: Hung job times out and is recorded as TIMED_OUT
test_run_timeout() {
    local sandbox="$1"
    set +e
    "$CRONWATCH" run slow-job --timeout 1 -- sleep 5
    local code=$?
    set -e

    # Exit code for timeout is 124 or 137
    if [[ "$code" -ne 124 && "$code" -ne 137 ]]; then
        echo "Expected timeout exit code (124/137), got $code" >&2
        return 1
    fi

    local log_content
    log_content=$(cat "$CRONWATCH_LOG_FILE")
    assert_contains "$log_content" '"status":"TIMED_OUT"' "Log status should be TIMED_OUT"
}

# Test 4: Check reports OK when job heartbeat is healthy
test_check_healthy() {
    local sandbox="$1"
    echo "healthy-job 15 60" > "$CRONWATCH_CONFIG_FILE"

    # Run job to create heartbeat
    "$CRONWATCH" run healthy-job -- echo "ok"

    local check_out
    check_out=$("$CRONWATCH" check)
    local code=$?

    assert_equals "0" "$code" "Check should exit 0 for healthy jobs"
    assert_contains "$check_out" "[OK]   healthy-job: healthy" "Check output should report healthy"
}

# Test 5: Check reports FAIL when a job missed its heartbeat
test_check_missed_heartbeat() {
    local sandbox="$1"
    echo "missed-job 5 60" > "$CRONWATCH_CONFIG_FILE"

    # Create stale heartbeat file from 2 hours ago (7200 seconds ago)
    mkdir -p "$CRONWATCH_HEARTBEAT_DIR"
    local past_epoch=$(( $(date +%s) - 7200 ))
    cat <<EOF > "${CRONWATCH_HEARTBEAT_DIR}/missed-job"
JOB_NAME=missed-job
LAST_SUCCESS_ISO=2026-11-09T00:00:00Z
LAST_SUCCESS_EPOCH=${past_epoch}
LAST_DURATION_SECONDS=5
EOF

    set +e
    local check_out
    check_out=$("$CRONWATCH" check)
    local code=$?
    set -e

    assert_equals "1" "$code" "Check should exit 1 on missed heartbeat"
    assert_contains "$check_out" "MISSED_HEARTBEAT" "Check output should flag MISSED_HEARTBEAT"
}

# Test 6: Check reports FAIL when a job never ran (no heartbeat file)
test_check_never_ran() {
    local sandbox="$1"
    echo "ghost-job 10 60" > "$CRONWATCH_CONFIG_FILE"

    set +e
    local check_out
    check_out=$("$CRONWATCH" check)
    local code=$?
    set -e

    assert_equals "1" "$code" "Check should exit 1 on never-ran job"
    assert_contains "$check_out" "NEVER_RAN" "Check output should flag NEVER_RAN"
}

# Test 7: Check reports FAIL when the latest run exited non-zero
test_check_last_run_failed() {
    local sandbox="$1"
    echo "broken-job 60" > "$CRONWATCH_CONFIG_FILE"

    # Run job once with success
    "$CRONWATCH" run broken-job -- echo "ok"

    # Run job second time with failure
    set +e
    "$CRONWATCH" run broken-job -- bash -c "echo 'db connection dropped' >&2; exit 1"
    set -e

    set +e
    local check_out
    check_out=$("$CRONWATCH" check)
    local code=$?
    set -e

    assert_equals "1" "$code" "Check should exit 1 when last run failed"
    assert_contains "$check_out" "EXIT_NONZERO" "Check output should flag EXIT_NONZERO"
    assert_contains "$check_out" "db connection dropped" "Check should print stderr snippet"
}

# Test 8: Doctor detects Windows CRLF line endings
test_doctor_detects_crlf() {
    local sandbox="$1"
    local crlf_script="${sandbox}/crlf_test.sh"
    printf '#!/usr/bin/env bash\r\necho "test"\r\n' > "$crlf_script"
    chmod +x "$crlf_script"

    set +e
    local doc_out
    doc_out=$("$CRONWATCH" doctor "$crlf_script")
    local code=$?
    set -e

    assert_equals "1" "$code" "Doctor should exit 1 on CRLF detection"
    assert_contains "$doc_out" "Windows CRLF (\r\n) line endings detected" "Doctor should flag CRLF"
}

# Test 9: Doctor detects missing executable bit
test_doctor_detects_non_executable() {
    local sandbox="$1"
    local noexec_script="${sandbox}/noexec_test.sh"
    printf '#!/usr/bin/env bash\necho "test"\n' > "$noexec_script"
    chmod -x "$noexec_script"

    set +e
    local doc_out
    doc_out=$("$CRONWATCH" doctor "$noexec_script")
    local code=$?
    set -e

    assert_equals "1" "$code" "Doctor should exit 1 on non-executable script"
    assert_contains "$doc_out" "Script is not marked executable" "Doctor should flag non-executable"
}

# Test 10: Test-alert command execution
test_test_alert() {
    local sandbox="$1"
    local alert_out
    alert_out=$("$CRONWATCH" test-alert "verify-job")
    assert_contains "$alert_out" "[OK] Syslog alert logged via logger" "test-alert should log to syslog"
}

# ==============================================================================
# Runner
# ==============================================================================
echo "============================================================"
echo "          cronwatch automated test suite                    "
echo "============================================================"

run_test test_run_success
run_test test_run_failure_propagation
run_test test_run_timeout
run_test test_check_healthy
run_test test_check_missed_heartbeat
run_test test_check_never_ran
run_test test_check_last_run_failed
run_test test_doctor_detects_crlf
run_test test_doctor_detects_non_executable
run_test test_test_alert

echo "============================================================"
echo "Tests finished: ${PASSED}/${TOTAL} passed, ${FAILED} failed."
echo "============================================================"

if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0

