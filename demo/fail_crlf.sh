#!/usr/bin/env bash
#
# demo/fail_crlf.sh - Demonstrates failure caused by Windows CRLF (\r\n) line endings
# When run on Linux, '#!/usr/bin/env bash\r' causes 'bad interpreter' or syntax errors.
#
echo "This script contains carriage returns (\r\n)."
exit 0
