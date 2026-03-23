#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Move to Lenovo P27
# @raycast.mode compact

# Optional parameters:
# @raycast.icon ./images/plash.png
# @raycast.packageName Plash

# Documentation:
# @raycast.author Stefan Schwetschke
# @raycast.authorURL https://github.com/geggo98
# @raycast.description Move Plash browser window to monitor "Lenovo p27"

osascript -e 'tell application "Plash" to quit'
defaults write com.sindresorhus.Plash display "4F6FCDF4-FCD2-47D0-97E8-EDE23C763755"
osascript -e 'tell application "Plash" to activate'
