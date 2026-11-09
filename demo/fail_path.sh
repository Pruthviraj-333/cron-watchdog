#!/usr/bin/env bash
#
# demo/fail_path.sh - Simulates a script breaking due to cron's minimal PATH
#
# Cron defaults to PATH=/usr/bin:/bin. Custom binaries in /usr/local/bin,
# ~/.local/bin, or /opt/bin will fail with "command not found".
#

echo "[info] Current PATH is: $PATH"

# Simulate invoking a binary expected in /usr/local/bin or custom path
# We explicitly invoke a command assuming full environment, demonstrating failure
if ! command -v aws-custom-uploader >/dev/null 2>&1; then
    echo "aws-custom-uploader: command not found" >&2
    echo "Error: Required deployment tool 'aws-custom-uploader' is missing from PATH ($PATH)" >&2
    echo "Hint: Did you forget to set PATH in your crontab?" >&2
    exit 127
fi

echo "[info] Upload completed successfully."
exit 0
