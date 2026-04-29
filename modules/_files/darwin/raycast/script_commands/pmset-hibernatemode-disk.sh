#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title pmset: Hibernate (disk, hibernatemode 25)
# @raycast.mode compact

# Optional parameters:
# @raycast.icon 💤
# @raycast.packageName Power Management
# @raycast.needsConfirmation false

# Documentation:
# @raycast.author stefan.schwetschke
# @raycast.authorURL https://github.com/geggo98
# @raycast.description Set hibernatemode=25: write RAM to disk and power memory off during sleep. Saves battery on long sleeps; slower wake.

export PATH="/run/current-system/sw/bin:/etc/profiles/per-user/${USER}/bin:${HOME}/.nix-profile/bin:${PATH}"
exec gtimeout 10 /usr/bin/sudo -n /run/current-system/sw/bin/pmset-hibernatemode disk
