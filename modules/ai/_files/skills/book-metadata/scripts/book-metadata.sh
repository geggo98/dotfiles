#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Thin wrapper: 5-minute cap around the uv script. Wraps calibre's CLI, see ../UPSTREAM.md.
set -euo pipefail
exec gtimeout 5m "${0:A:h}/book_metadata.py" "$@"
