#!/usr/bin/env bats
#
# tests/cronwatch.bats - BATS test suite for cronwatch
# Executed in CI pipeline (GitHub Actions)
#

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    CRONWATCH="${REPO_ROOT}/bin/cronwatch"

    TEST_TMP="$(mktemp -d)"
    export CRONWATCH_LOG_DIR="${TEST_TMP}/log"
    export CRONWATCH_LOG_FILE="${TEST_TMP}/log/jobs.log"
    export CRONWATCH_STATE_DIR="${TEST_TMP}/state"
    export CRONWATCH_HEARTBEAT_DIR="${TEST_TMP}/state/heartbeats"
    export CRONWATCH_CONFIG_DIR="${TEST_TMP}/config"
    export CRONWATCH_CONFIG_FILE="${TEST_TMP}/config/jobs.conf"
    export CRONWATCH_SNS_TOPIC_ARN=""

    mkdir -p "$CRONWATCH_LOG_DIR" "$CRONWATCH_HEARTBEAT_DIR" "$CRONWATCH_CONFIG_DIR"
}

teardown() {
    rm -rf "$TEST_TMP"
}

@test "cronwatch --version prints version" {
    run "$CRONWATCH" --version
    [ "$status" -eq 0 ]
    [[ "$output" =~ "cronwatch version" ]]
}

@test "cronwatch run: creates heartbeat on success and records JSON metric" {
    run "$CRONWATCH" run bats-ok -- echo "success"
    [ "$status" -eq 0 ]
    [ -f "${CRONWATCH_HEARTBEAT_DIR}/bats-ok" ]
    [ -f "$CRONWATCH_LOG_FILE" ]
    grep -q '"job_name":"bats-ok"' "$CRONWATCH_LOG_FILE"
    grep -q '"status":"SUCCESS"' "$CRONWATCH_LOG_FILE"
}

@test "cronwatch run: propagates exit code and omits heartbeat on failure" {
    run "$CRONWATCH" run bats-fail -- bash -c "echo 'sample error' >&2; exit 7"
    [ "$status" -eq 7 ]
    [ ! -f "${CRONWATCH_HEARTBEAT_DIR}/bats-fail" ]
    grep -q '"status":"FAILED"' "$CRONWATCH_LOG_FILE"
    grep -q '"exit_code":7' "$CRONWATCH_LOG_FILE"
    grep -q "sample error" "$CRONWATCH_LOG_FILE"
}

@test "cronwatch run: kills hung process and records TIMED_OUT" {
    run "$CRONWATCH" run bats-slow --timeout 1 -- sleep 5
    [ "$status" -eq 124 ] || [ "$status" -eq 137 ]
    [ ! -f "${CRONWATCH_HEARTBEAT_DIR}/bats-slow" ]
    grep -q '"status":"TIMED_OUT"' "$CRONWATCH_LOG_FILE"
}

@test "cronwatch check: reports healthy when heartbeat is fresh" {
    echo "bats-check-ok 10" > "$CRONWATCH_CONFIG_FILE"
    "$CRONWATCH" run bats-check-ok -- echo "done"
    run "$CRONWATCH" check
    [ "$status" -eq 0 ]
    [[ "$output" =~ "[OK]   bats-check-ok: healthy" ]]
}

@test "cronwatch check: detects never-ran job" {
    echo "bats-never-ran 10" > "$CRONWATCH_CONFIG_FILE"
    run "$CRONWATCH" check
    [ "$status" -eq 1 ]
    [[ "$output" =~ "NEVER_RAN" ]]
}

@test "cronwatch check: detects last run exit non-zero" {
    echo "bats-bad-exit 10" > "$CRONWATCH_CONFIG_FILE"
    run "$CRONWATCH" run bats-bad-exit -- bash -c "echo 'bad failure' >&2; exit 2"
    run "$CRONWATCH" check
    [ "$status" -eq 1 ]
    [[ "$output" =~ "EXIT_NONZERO" ]]
    [[ "$output" =~ "bad failure" ]]
}

@test "cronwatch doctor: detects Windows CRLF line endings" {
    local crlf_file="${TEST_TMP}/bad_crlf.sh"
    printf '#!/usr/bin/env bash\r\necho "hi"\r\n' > "$crlf_file"
    chmod +x "$crlf_file"
    run "$CRONWATCH" doctor "$crlf_file"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Windows CRLF (\r\n) line endings detected" ]]
}

@test "cronwatch doctor: detects missing executable permissions" {
    local noexec_file="${TEST_TMP}/bad_noexec.sh"
    printf '#!/usr/bin/env bash\necho "hi"\n' > "$noexec_file"
    chmod -x "$noexec_file"
    run "$CRONWATCH" doctor "$noexec_file"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Script is not marked executable" ]]
}
