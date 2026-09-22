#!/bin/sh
set -eu

client_id=${1:-}
if [ -z "$client_id" ]; then
  exit 2
fi

IFS= read -r refresh_token
if [ -z "$refresh_token" ]; then
  exit 3
fi

printf '%s' "$refresh_token" | secret-tool store \
  --label='OmagTasks refresh token' \
  service omagtasks \
  kind refresh-token \
  client-id "$client_id"
