#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Login Production
# @raycast.mode compact

# Optional parameters:
# @raycast.icon ./images/hashi-vault.png
# @raycast.packageName Hashi Vault

# Documentation:
# @raycast.author stefan.schwetschke
# @raycast.authorURL https://github.com/geggo98
# @raycast.description Login to the production Vault with Hashi Vault CLI, opens a web browser.

export PATH="/run/current-system/sw/bin:/etc/profiles/per-user/${USER}/bin:${HOME}/.nix-profile/bin:${PATH}:/opt/homebrew/bin/:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin"
exec "/etc/profiles/per-user/${USER}/bin/+vault-login-production"
