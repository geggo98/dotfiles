#!/usr/bin/env bash
# Find running Slidev dev server instances by scanning ports 3030-4000.
# Slidev injects <meta name="slidev:version"> into its HTML, so we can
# detect it by curling each port and checking for the marker.

set -euo pipefail

found=0
for port in $(seq 3030 4000); do
  if curl -s --connect-timeout 0.2 "http://localhost:$port" 2>/dev/null | grep -q "slidev"; then
    echo "Slidev running on port $port → http://localhost:$port"
    found=1
  fi
done

if [ "$found" -eq 0 ]; then
  echo "No Slidev instance found on ports 3030-4000."
  echo ""
  echo "Alternative: check node processes listening on any port:"
  echo "  lsof -i -P | grep node | grep LISTEN"
  exit 1
fi
