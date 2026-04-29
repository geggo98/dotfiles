#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title pmset: Standby (RAM, hibernatemode 3, default)
# @raycast.mode compact

# Optional parameters:
# @raycast.icon 🛌
# @raycast.packageName Power Management
# @raycast.needsConfirmation false

# Documentation:
# @raycast.author stefan.schwetschke
# @raycast.authorURL https://github.com/geggo98
# @raycast.description Set hibernatemode=3 (Apple Silicon default): sleep keeps RAM powered, copy on disk as fallback. Fast wake.

export PATH="/run/current-system/sw/bin:/etc/profiles/per-user/${USER}/bin:${HOME}/.nix-profile/bin:${PATH}"
exec gtimeout 10 /usr/bin/sudo -n /run/current-system/sw/bin/pmset-hibernatemode standby-ram
