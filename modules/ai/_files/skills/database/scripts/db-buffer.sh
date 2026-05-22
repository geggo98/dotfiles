#!/usr/bin/env bash
# db-buffer.sh — buffer stdin to a tempfile and either inline the content
# (≤ threshold) or print a path + preview (> threshold).
#
# Standalone counterpart to the buffer_output helper in _lib.sh, useful
# for any command whose output might or might not fit in the LLM context.

set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

usage() {
  cat <<'EOF'
Usage:
  <producer> | db-buffer.sh [options]

Buffers stdin to a tempfile (in $TMPDIR). When the captured size is
within the threshold, prints content to stdout and deletes the tempfile.
When over the threshold, prints a short header, the absolute path, and
the first N lines as a preview; the file is left on disk.

Options:
  --max-bytes N          Threshold in bytes (default: 32768, or
                         $DB_OUTPUT_MAX_BYTES env var)
  --label TEXT           Label shown in truncation header (default: "output")
  --preview-lines N      Lines to show as preview when over threshold (default: 20)
  -h, --help             This help

Examples:
  # Inline if small, path+preview if large:
  psql -X -c "SELECT * FROM big_table" | db-buffer.sh --label psql

  # Tighter budget:
  ls -la /var/log | db-buffer.sh --max-bytes 4096 --preview-lines 5
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

buffer_output "$@"
