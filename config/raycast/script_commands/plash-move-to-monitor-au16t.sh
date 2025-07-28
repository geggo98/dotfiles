#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Move to AU16t
# @raycast.mode compact

# Optional parameters:
# @raycast.icon ./images/plash.png
# @raycast.packageName Plash

# Documentation:
# @raycast.author Stefan Schwetschke
# @raycast.authorURL https://github.com/geggo98
# @raycast.description Move Plash browser window to monitor "AU16T"

osascript -e 'tell application "Plash" to quit'
defaults write com.sindresorhus.Plash display "F07C06B9-8DE6-47AD-BBAD-C6099C6CE317"
osascript -e 'tell application "Plash" to activate'
