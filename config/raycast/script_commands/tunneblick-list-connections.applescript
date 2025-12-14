#!/usr/bin/osascript

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Tunnelblick: List Configurations
# @raycast.mode fullOutput
# @raycast.packageName TunnelBlick
#
# Optional parameters:
# @raycast.icon images/tunnelblick.png

on run argv
  tell application "Tunnelblick"
    return (get name of configurations) as string
  end tell
end run
