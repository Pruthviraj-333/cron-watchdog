# cron-watchdog

> A lightweight, zero-dependency Bash tool that detects **silent cron job failures** on Linux.
> Built for production cloud environments (AWS EC2 / Ubuntu) with automated alerting via syslog and AWS SNS.

[![CI](https://github.com/Pruthviraj-333/cron-watchdog/actions/workflows/ci.yml/badge.svg)](https://github.com/Pruthviraj-333/cron-watchdog/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/Language-Pure%20Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![AWS Free-Tier](https://img.shields.io/badge/AWS-Free--Tier%20Eligible-orange.svg)](#)

---

## 1. The Problem: Why Cron Jobs Fail Silently

On modern Linux servers, cron jobs fail quietly every day without anyone noticing until critical data is lost:
1. **The job never ran:** The cron daemon crashed, someone commented out the crontab, or the server rebooted. Because traditional monitoring only alerts on error logs, an un-executed job produces **zero logs** and triggers **zero alerts**.
2. **The job exited non-zero:** The script crashed with exit code 1 or 127. Cron attempts to deliver output to `/var/mail/$USER` via local `sendmail`, which is disabled or unmonitored on almost all modern cloud servers.
3. **The job hung indefinitely:** A database lock deadlocked, an HTTP call hung without a socket timeout, or a subshell waited for unreachable stdin. The process stays alive forever, blocking subsequent runs.
4. **Environment and PATH differences:** Cron executes in a stripped-down, non-interactive `/bin/sh` shell with `PATH=/usr/bin:/bin`. Scripts that run perfectly when manually executed by an engineer fail under cron because tools in `/usr/local/bin` (`aws`, `node`, `jq`) cannot be found.
5. **The Vixie Cron Trailing Newline Trap:** Classic Vixie Cron (default on Ubuntu and Debian) **silently drops the last line** of any crontab file that lacks a trailing ASCII newline character (`\n`), printing no warning or error.
6. **Windows CRLF line endings:** Scripts committed or edited across operating systems contain `\r\n`, causing `/bin/bash^M: bad interpreter: No such file or directory`.
7. **Wrong file permissions:** System cron directories (`/etc/cron.d/`, `/etc/cron.daily/`) reject scripts that are not owned by `root:root` or that are group/world-writable (`BAD FILE MODE`).

`cron-watchdog` solves every one of these failure modes with zero unnecessary frameworks.

---

## 2. Architecture

```
                  CRONTAB SCHEDULES
    +-----------------------------------------------+
    | 0 2 * * * cronwatch run backup-db -- /opt/bk.sh
    | */5 * * * * cronwatch check --quiet          |
    +-----------------------------------------------+
                           │
             ┌─────────────┴─────────────┐
             ▼                           ▼
    +-----------------+         +-----------------+
    |  cronwatch run  |         | cronwatch check |
    +-----------------+         +-----------------+
             │                           │
    ┌────────┴────────┐                  │
    ▼                 ▼                  ▼
[Heartbeat]     [jobs.log]      Inspects Heartbeat Age &
/var/lib/...    /var/log/...    Recent Log Status in jobs.log
(On Success)    (JSON-lines)             │
                                         ▼
                               (Condition Detected?)
                                         │
                         ┌───────────────┴───────────────┐
                         ▼                               ▼
                 [Local Syslog]                      [AWS SNS]
               logger -t cronwatch               aws sns publish
             (journalctl / syslog)            (IAM Instance Profile)
                         │                               │
                         ▼                               ▼
               Host Logs & Forwarders            On-Call Team Email
```

---

## 3. Core Components

### 1. `cronwatch run <job-name> [--timeout N] -- <command...>`
A transparent execution wrapper placed in front of your cron command:
- Records start time, end time, duration, and exit status.
- Securely captures `stderr` and preserves standard Unix pipeline behavior by echoing it back to `stderr` (`fd 2`).
- Enforces execution limits using `timeout -k 10 N` (sends `SIGTERM`, followed by uncatchable `SIGKILL` if deadlocked).
- On success (`exit 0`), atomically updates the heartbeat file:
  `/var/lib/cron-watchdog/heartbeats/<job-name>`
- Appends structured metric records to `/var/log/cron-watchdog/jobs.log` in JSON-lines format.
- Propagates the command's original exit code.

### 2. `cronwatch check [--quiet]`
Scheduled in cron every 5 minutes (`*/5 * * * * cronwatch check --quiet`).
Reads `/etc/cron-watchdog/jobs.conf` and monitors three core conditions:
1. **Missed Schedules / Never Ran ("Dead Man's Snitch"):** Computes `now - last_heartbeat_time`. Flags `MISSED_HEARTBEAT` if older than allowed, or `NEVER_RAN` if no heartbeat exists.
2. **Execution Errors:** Inspects the latest run in `jobs.log`. Flags `EXIT_NONZERO` or `TIMED_OUT` and extracts the last 20 lines of `stderr`.
3. **Runtime Anomalies:** Flags `DURATION_EXCEEDED` if runtime exceeds explicit thresholds in `jobs.conf`, or `DURATION_ANOMALY` if a run took $\ge 3\times$ its historical baseline average (minimum 15s noise floor).

### 3. `cronwatch doctor [scripts...]`
Automated environment diagnostic tool. Runs 7 host health checks:
- **Cron Service:** Checks if `cron` or `crond` is active via `systemctl`.
- **Syslog Activity:** Checks if cron executions are being recorded in `journalctl`.
- **Crontab Trailing Newline:** Inspects `/etc/crontab`, `/etc/cron.d/*`, and `crontab -l` for missing final newlines.
- **CRLF Detection:** Scans scripts for Windows carriage returns (`\r\n`).
- **Executable Bit:** Verifies scripts are marked `+x`.
- **File Modes:** Verifies root ownership (UID 0) and non-writable permissions for system cron directories.
- **PATH & Environment:** Identifies tools residing outside cron's default search path (`/usr/bin:/bin`).

### 4. Alerting Pipeline
- **Syslog (`logger`):** Always logs failures with severity levels `user.err` (critical) or `user.warning`.
- **AWS SNS (`aws sns publish`):** When `CRONWATCH_SNS_TOPIC_ARN` is configured, delivers structured alerts via AWS SNS.
  - **Zero Static Keys:** Uses the EC2 IAM Instance Profile automatically via IMDSv2.
  - **Defensive Truncation:** Enforces AWS SNS's 100-character subject limit.

---

## 4. Installation & Configuration

### Quick Install (Ubuntu / Debian / RHEL / Linux)
```bash
# 1. Clone repository
git clone https://github.com/Pruthviraj-333/cron-watchdog.git /opt/cron-watchdog
cd /opt/cron-watchdog

# 2. Symlink binary to system PATH
sudo ln -sf /opt/cron-watchdog/bin/cronwatch /usr/local/bin/cronwatch

# 3. Create standard FHS directories
sudo mkdir -p /var/log/cron-watchdog /var/lib/cron-watchdog/heartbeats /etc/cron-watchdog
sudo chmod 755 /var/log/cron-watchdog /var/lib/cron-watchdog /etc/cron-watchdog

# 4. Copy configuration template
sudo cp conf/jobs.conf.example /etc/cron-watchdog/jobs.conf
sudo cp conf/cronwatch.env.example /etc/cron-watchdog/cronwatch.env
```

### Configuration (`/etc/cron-watchdog/jobs.conf`)
Format: `<job-name> <max_allowed_age_minutes> [max_duration_seconds]`
```conf
# /etc/cron-watchdog/jobs.conf
backup-database    15    120   # Runs every 10m, alert if missed for 15m or takes >120s
generate-reports   65          # Runs hourly (60m + 5m grace period)
daily-cleanup      1450  300   # Runs daily (24h + 10m grace period)
```

### Environment Configuration (`/etc/cron-watchdog/cronwatch.env`)
```bash
# AWS SNS Topic ARN (leave empty for syslog only)
CRONWATCH_SNS_TOPIC_ARN="arn:aws:sns:ap-south-1:130063747569:cron-watchdog-alerts"
AWS_REGION="ap-south-1"
```

---

## 5. Usage Examples

### 1. Wrapping a Cron Job
In your crontab (`crontab -e`):
```cron
# Database backup with 60-second timeout enforcement
0 2 * * * cronwatch run backup-database --timeout 60 -- /opt/scripts/backup.sh

# Run monitoring check every 5 minutes (quiet mode suppresses healthy output)
*/5 * * * * cronwatch check --quiet
```

### 2. Manual Diagnostics
```bash
# Run host diagnostics
cronwatch doctor

# Test specific scripts
cronwatch doctor /opt/scripts/*.sh

# Verify syslog and AWS SNS alerting pipeline
cronwatch test-alert my-test-job
```

---

## 6. Live EC2 Test Run & Captured Verification

The following outputs were captured from a **real test execution** on an EC2 Ubuntu 24.04 `t3.micro` instance in `ap-south-1`:

### 1. Automated Test Suite (10/10 Passed)
```
$ ./tests/run_tests.sh
============================================================
          cronwatch automated test suite                    
============================================================
Running test_run_success... PASS
Running test_run_failure_propagation... fatal database error
PASS
Running test_run_timeout... PASS
Running test_check_healthy... ok
PASS
Running test_check_missed_heartbeat... PASS
Running test_check_never_ran... PASS
Running test_check_last_run_failed... ok
db connection dropped
PASS
Running test_doctor_detects_crlf... PASS
Running test_doctor_detects_non_executable... PASS
Running test_test_alert... PASS
============================================================
Tests finished: 10/10 passed, 0 failed.
============================================================
```

### 2. BATS Declarative Test Suite (9/9 Passed)
```
$ bats tests/cronwatch.bats
1..9
ok 1 cronwatch --version prints version
ok 2 cronwatch run: creates heartbeat on success and records JSON metric
ok 3 cronwatch run: propagates exit code and omits heartbeat on failure
ok 4 cronwatch run: kills hung process and records TIMED_OUT
ok 5 cronwatch check: reports healthy when heartbeat is fresh
ok 6 cronwatch check: detects never-ran job
ok 7 cronwatch check: detects last run exit non-zero
ok 8 cronwatch doctor: detects Windows CRLF line endings
ok 9 cronwatch doctor: detects missing executable permissions
```

### 3. Failure Demonstration (`cronwatch check`)
```
$ cronwatch check
[OK]   healthy-job: healthy (last success 0m ago, last duration 0s)
[FAIL] failed-exit1-job: NEVER_RAN (no heartbeat file found); EXIT_NONZERO (exit code 1 at 2026-11-09T11:36:48Z)
       stderr: [info] Connecting to database cluster postgres-prod-01...
pg_dump: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed: Connection refused
pg_dump: error: Is the server running locally and accepting connections?
pg_dump: error: fatal: database backup aborted due to connection failure
[FAIL] hung-timeout-job: NEVER_RAN (no heartbeat file found); TIMED_OUT (killed after 2s at 2026-11-09T11:36:50Z)
       stderr: [info] Waiting for remote API socket response (hanging)...
[FAIL] path-broken-job: NEVER_RAN (no heartbeat file found); EXIT_NONZERO (exit code 127 at 2026-11-09T11:36:50Z)
       stderr: aws-custom-uploader: command not found
Error: Required deployment tool 'aws-custom-uploader' is missing from PATH (/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
[FAIL] unscheduled-job: NEVER_RAN (no heartbeat file found)

Summary: 5 checked, 4 failed, 0 warnings.
```

### 4. System Diagnostics (`cronwatch doctor`)
```
$ cronwatch doctor demo/fail_crlf.sh demo/fail_perms.sh
============================================================
          cronwatch doctor - Cron Health Diagnostics        
============================================================
[PASS] Cron Service: Active and running (cron)
[PASS] Syslog/Journal: Cron execution events detected in journalctl (7 recent entries)
[FAIL] Crontab Newline: File missing trailing newline (Vixie cron silently drops the last line!):
       - /etc/crontab
       - /etc/cron.d/e2scrub_all
       - /etc/cron.d/sysstat
       Hint: Run 'echo "" >> <file>' or ensure your text editor inserts a trailing newline.
[FAIL] Line Endings: Windows CRLF (\r\n) line endings detected (causes '/bin/bash^M: bad interpreter'):
       - demo/fail_crlf.sh
       Hint: Run 'sed -i "s/\r$//" <script>' or 'dos2unix <script>' to convert to Unix LF.
[FAIL] Executable Bit: Script is not marked executable:
       - demo/fail_perms.sh
       Hint: Run 'chmod +x <script>' so cron can execute it.
[PASS] File Permissions: System cron directory files have secure ownership & permissions
[WARN] PATH & Environment: Tools located outside cron's default search PATH (/usr/bin:/bin):
       - 'aws' is at /usr/local/bin/aws (outside cron default PATH: /usr/bin:/bin)
       Hint: Add 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' at the top of crontab, or use absolute paths.
============================================================
Diagnostic Summary: 5 PASS, 3 FAIL, 1 WARN
Status: Issues detected that could cause silent cron job failures.
```

### 5. Live Syslog Stream (`journalctl -t cronwatch`)
```
Nov 09 11:36:50 ip-172-31-6-47 cronwatch[3728]: CRITICAL: [cronwatch] Job 'failed-exit1-job' alert NEVER_RAN: NEVER_RAN | Details: Heartbeat file missing
Nov 09 11:36:50 ip-172-31-6-47 cronwatch[3738]: CRITICAL: [cronwatch] Job 'failed-exit1-job' alert EXIT_NONZERO: EXIT_NONZERO (exit code 1) | Details: Failed with exit code 1
Nov 09 11:36:50 ip-172-31-6-47 cronwatch[3761]: CRITICAL: [cronwatch] Job 'hung-timeout-job' alert TIMED_OUT: TIMED_OUT (killed after 2s) | Details: Process exceeded timeout duration
Nov 09 11:36:50 ip-172-31-6-47 cronwatch[3784]: CRITICAL: [cronwatch] Job 'path-broken-job' alert EXIT_NONZERO: EXIT_NONZERO (exit code 127) | Details: Failed with exit code 127
Nov 09 11:40:44 ip-172-31-6-47 cronwatch[4401]: WARNING: [cronwatch] Job 'ec2-production-test' alert TEST_ALERT: Synthetic test alert generated by 'cronwatch test-alert'
```

---

## 7. Linux Systems & Cloud Engineering Deep Dive (Technical Q&A)

This project was engineered to demonstrate foundational Linux, systems engineering, and AWS troubleshooting skills. Here is how each concept maps to common interview questions:

### Q1: "How do you detect when a job silently failed to run at all?"
> **Candidate Explanation:** "Traditional log monitoring only catches jobs that generate error lines. If the cron daemon crashes, the node reboots, or someone disables crontab, no logs are created. We implemented the **Dead Man's Snitch / Heartbeat pattern**: every successful run touches `/var/lib/cron-watchdog/heartbeats/<job-name>`. A separate watchdog runs every 5 minutes comparing `(now_epoch - heartbeat_mtime)`. If the delta exceeds the allowed threshold, it immediately triggers an alert."

### Q2: "Why can't you use access keys on an EC2 instance, and how does your script authenticate to AWS?"
> **Candidate Explanation:** "Hardcoding `AWS_ACCESS_KEY_ID` or placing static keys in `.env` files is a major security risk because keys can leak into source control or process tables. Instead, we use an **IAM Instance Profile** attached to the EC2 instance. The AWS CLI queries the **EC2 Instance Metadata Service (IMDSv2)** at `http://169.254.169.254/latest/meta-data/` to retrieve temporary, rotating credentials. Our IAM policy follows least privilege: it allows ONLY `sns:Publish` on the specific `cron-watchdog-alerts` Topic ARN."

### Q3: "What happens when a cron job hangs, and how does your wrapper prevent zombie processes?"
> **Candidate Explanation:** "We wrap execution with GNU `timeout -k 10 ${SECS} "${CMD[@]}"`. When the timeout expires, `timeout` sends `SIGTERM` (signal 15) to request a graceful shutdown. If the process is deadlocked and ignores `SIGTERM`, `-k 10` sends `SIGKILL` (signal 9) after 10 seconds. `SIGKILL` cannot be caught or ignored by the process, guaranteeing that hung jobs are killed and logged with exit code 124 or 137 as `TIMED_OUT`."

### Q4: "Why do scripts run by hand in an SSH session fail under cron?"
> **Candidate Explanation:** "An interactive SSH session is a login shell that sources `/etc/profile`, `/etc/environment`, and `~/.bashrc`, giving a rich `PATH` including `/usr/local/bin` and custom environment variables. Cron runs tasks under `/bin/sh` with a stripped-down `PATH` (typically `/usr/bin:/bin`). Our `cronwatch doctor` command scans system binaries and flags any commands residing outside `/usr/bin:/bin`."

### Q5: "Why do you use atomic writes when updating heartbeat files?"
> **Candidate Explanation:** "If a reader process (`cronwatch check`) inspects a file at the exact millisecond `cronwatch run` is writing it, reading a half-written file causes syntax errors. We write the updated heartbeat to a temporary file (`${file}.tmp.$$`) and replace the target with `mv -f`. In POSIX filesystems, `rename(2)` / `mv` on the same filesystem is guaranteed to be atomic."

---

## 8. Design Decisions

1. **Pure Bash + Coreutils:** Zero dependencies on external runtime engines like Python, Node.js, or Ruby. Runs out-of-the-box on minimal cloud distributions.
2. **Standard FHS Paths with Environment Overrides:** Adheres to Linux Filesystem Hierarchy Standard (`/var/log`, `/var/lib`, `/etc`), but allows variable overrides (`CRONWATCH_LOG_DIR`, `CRONWATCH_STATE_DIR`) for unprivileged sandbox testing.
3. **Structured JSON-Lines:** Every run logs a single-line JSON record for easy ingestion by central log management systems (CloudWatch Logs Agent, FluentBit, Datadog).
4. **Noise Floor for Duration Anomalies:** Jobs must run for at least 15 seconds before triggering a $>3\times$ baseline anomaly warning, preventing alert fatigue from sub-second fluctuations (e.g. 0.1s to 0.4s).

---

## 9. Known Limitations & Future Work

### Known Limitations
- Heartbeat age checks require system clocks to be reasonably synchronized via NTP / `systemd-timesyncd`.
- In-memory historical baseline calculation parses the last 10 entries from `jobs.log`. On systems with millions of historical runs, log rotation (via `logrotate`) is recommended.

### Future Work
- [ ] Integration with AWS CloudWatch Embedded Metric Format (EMF) for automated dashboarding.
- [ ] Native Slack / PagerDuty webhook dispatch alongside AWS SNS.
- [ ] Distributed lock coordinator using DynamoDB or local flock to prevent overlapping runs.

