#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Login
# @raycast.mode compact

# Optional parameters:
# @raycast.icon ./images/boundary.png
# @raycast.packageName Boundary

# Documentation:
# @raycast.author stefan.schwetschke
# @raycast.authorURL https://github.com/geggo98
# @raycast.description Login with Boundary CLI, opens a web browser.

export PATH="/run/current-system/sw/bin:/etc/profiles/per-user/${USER}/bin:${HOME}/.nix-profile/bin:${PATH}"
exec "/etc/profiles/per-user/${USER}/bin/+boundary-login"
