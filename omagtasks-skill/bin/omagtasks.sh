#!/usr/bin/env bash
# Helper for the omagtasks Claude Code skill: talks to Google Tasks using the
# same client-id/secret/refresh-token the omagtasks Omarchy plugin already
# uses (read live from shell.json + GNOME Keyring — nothing duplicated or
# hardcoded here), then nudges the running plugin to refresh its bar/panel.
set -euo pipefail

SHELL_JSON="$HOME/.config/omarchy/shell.json"
PLUGIN_ID="io.github.subjektivdk.omagtasks"

fail() { echo "omagtasks: $*" >&2; exit 1; }

widget_field() {
  jq -r --arg id "$PLUGIN_ID" --arg key "$1" \
    '.bar.layout.right[]? | select(.id==$id) | .[$key] // empty' "$SHELL_JSON"
}

access_token() {
  local cid csecret rt token
  cid=$(widget_field clientId)
  csecret=$(widget_field clientSecret)
  [[ -n $cid ]] || fail "no clientId set for $PLUGIN_ID in $SHELL_JSON"
  rt=$(secret-tool lookup service omagtasks kind refresh-token client-id "$cid") \
    || fail "no stored refresh token — log in via the bar widget first"
  [[ -n $rt ]] || fail "no stored refresh token — log in via the bar widget first"
  token=$(curl -sf -X POST https://oauth2.googleapis.com/token \
    -d client_id="$cid" -d client_secret="$csecret" \
    -d grant_type=refresh_token -d refresh_token="$rt" | jq -r '.access_token // empty')
  [[ -n $token ]] || fail "token refresh failed"
  printf '%s' "$token"
}

refresh_widget() {
  omarchy-shell "$PLUGIN_ID" refresh >/dev/null 2>&1 || true
}

cmd_create() {
  local title="${1:-}" due="${2:-}" notes="${3:-}"
  [[ -n $title ]] || fail "usage: omagtasks.sh create <title> [YYYY-MM-DD] [notes]"
  local token body
  token=$(access_token)
  body=$(jq -n --arg title "$title" --arg due "$due" --arg notes "$notes" '
    {title: $title}
    + (if $due   != "" then {due: ($due + "T00:00:00.000Z")} else {} end)
    + (if $notes != "" then {notes: $notes} else {} end)
  ')
  curl -sf -X POST "https://tasks.googleapis.com/tasks/v1/lists/@default/tasks" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d "$body" | jq -r '"\(.title)\t\(.due // "ingen dato")\t\(.id)"'
  refresh_widget
}

cmd_list() {
  local token
  token=$(access_token)
  curl -sf "https://tasks.googleapis.com/tasks/v1/lists/@default/tasks?showCompleted=false&showHidden=false&maxResults=100" \
    -H "Authorization: Bearer $token" \
    | jq -r '.items[]? | "\(.due // "ingen dato")\t\(.title)\t\(.id)"' | sort
}

cmd_complete() {
  local task_id="${1:-}"
  [[ -n $task_id ]] || fail "usage: omagtasks.sh complete <task-id>"
  local token
  token=$(access_token)
  curl -sf -X PATCH "https://tasks.googleapis.com/tasks/v1/lists/@default/tasks/$task_id" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d '{"status":"completed"}' | jq -r '"\(.title)\tcompleted"'
  refresh_widget
}

cmd_delete() {
  local task_id="${1:-}"
  [[ -n $task_id ]] || fail "usage: omagtasks.sh delete <task-id>"
  local token
  token=$(access_token)
  curl -sf -X DELETE "https://tasks.googleapis.com/tasks/v1/lists/@default/tasks/$task_id" \
    -H "Authorization: Bearer $token"
  echo "deleted $task_id"
  refresh_widget
}

cmd_refresh() { refresh_widget && echo "refreshed"; }

case "${1:-}" in
  create)   shift; cmd_create "$@" ;;
  list)     cmd_list ;;
  complete) shift; cmd_complete "$@" ;;
  delete)   shift; cmd_delete "$@" ;;
  refresh)  cmd_refresh ;;
  *) fail "usage: $0 {create <title> [YYYY-MM-DD] [notes] | list | complete <id> | delete <id> | refresh}" ;;
esac
