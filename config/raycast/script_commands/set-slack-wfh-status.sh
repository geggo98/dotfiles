#!/bin/bash

# API: https://api.slack.com/methods/users.profile.set

# Parameters

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Set WFH Status in Slack
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName Slack
# @raycast.icon images/slack-logo.png

# Documentation:
# @raycast.description Set your status in Slack to WFH or WFO depending on your WiFi
# @raycast.author alongat
# @raycast.authorURL https://github.com/alongat

# Configuration
# To create a new API token, do the following:
# 1. Create a new Slack app at https://api.slack.com/authentication/basics
# 2. Add `users.profile:write` to the user token scopes
# 3. Install the app to your workplace
# 4. Insert your OAuth access token below
# 5. Fill you OFFICE_WIFI + HOME_WIFI - this will set different emoji when WFH vs WFO

# SLACK Token
if [[ -n "$SLACK_C24_API_KEY" ]]; then
  API_TOKEN="$SLACK_C24_API_KEY"
else
  secret_file="$HOME/.config/sops-nix/secrets/slack_c24_api_key"
  if [[ -f "$secret_file" ]]; then
    API_TOKEN=$(cat "$secret_file" | tr -d '\n\r')
  else
    echo "Slack API key not found in environment variable or secret file."
    exit 1
  fi
fi

# Minutes until the the status will expire (Empty string will not expire the status)
STATUS_EXPIRATION_IN_MINUTES="540" # 9 hours
CURRENT_UNIX_TIME=$(date +%s)
STATUS_EXPIRATION=$(($CURRENT_UNIX_TIME + ($STATUS_EXPIRATION_IN_MINUTES * 60)))

# Define home and office WiFi
HOME_WIFI="Schwetschke-MUC"
OFFICE_WIFI="C24-Employee"

# Main program
if [[ -z "$API_TOKEN" ]]
then
  echo "No API token provided"
  exit 1
fi

wifi_names=system_profiler SPAirPortDataType | \
perl -ne '
  if (/^\s+([^:]+):\s*$/) {
    $s = $1;
  }
  elsif ($s && /^\s+(?:Channel|Security):/) {
    push @ssids, $s unless $seen{$s}++;
    undef $s;
  }
  END {
    print "$_\n" for @ssids;
  }
'

for line in "${wifi_array[@]}"; do
  if [[ "$line" == "$HOME_WIFI" ]]; then
      STATUS_EMOJI=":house_with_garden:"
      TEXT="Home-Office";
      break;
  elif [[ "$wifi_name" == " $OFFICE_WIFI" ]]; then
      STATUS_EMOJI=":office:"
      TEXT="Im Büro";
      break;
  fi
done

RESPONSE=$(
    curl \
      --header "Content-Type: application/json" \
      --header "Authorization: Bearer $API_TOKEN" \
      --request POST \
      --data "{ 'profile': { 'status_text': '$TEXT', 'status_emoji': '$STATUS_EMOJI', 'status_expiration': $STATUS_EXPIRATION } }" \
      --silent \
      --show-error \
      --fail \
      "https://slack.com/api/users.profile.set"
    )

if [[ "$RESPONSE" =~ "error" ]]
then
  echo "Failed to set status in Slack"
  exit 1
else
  echo "Status set to $STATUS_EMOJI : $TEXT"
  exit 0
fi
