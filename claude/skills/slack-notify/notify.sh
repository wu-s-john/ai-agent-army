#!/usr/bin/env bash
# slack-notify: DM the user via the ai-agent-army Slack bot.
# See SKILL.md in this directory for usage and design notes.

set -euo pipefail

OP_VAULT="${SLACK_NOTIFY_OP_VAULT:-ai-agent-army}"
OP_ITEM="${SLACK_NOTIFY_OP_ITEM:-Slack}"

usage() {
  cat <<EOF
Usage: notify.sh [--done | --blocked | --info] <message>

DM the user via the ai-agent-army Slack bot.

Flags:
  --done       Prefix with ":white_check_mark: Done: "
  --blocked    Prefix with ":warning: Blocked: "
  --info       Prefix with ":information_source: "
  --help, -h   Show this help

Env overrides:
  SLACK_NOTIFY_OP_VAULT   1Password vault (default: ai-agent-army)
  SLACK_NOTIFY_OP_ITEM    1Password item  (default: Slack)

Credentials read from 1Password:
  op://\$OP_VAULT/\$OP_ITEM/Bot User Auth Token
  op://\$OP_VAULT/\$OP_ITEM/MemberID
EOF
}

prefix=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --done)    prefix=":white_check_mark: Done: "; shift ;;
    --blocked) prefix=":warning: Blocked: "; shift ;;
    --info)    prefix=":information_source: "; shift ;;
    --help|-h) usage; exit 0 ;;
    --)        shift; break ;;
    -*)        echo "notify.sh: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)         break ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "notify.sh: message required" >&2
  usage >&2
  exit 2
fi

message="${prefix}$*"

token="${SLACK_BOT_TOKEN:-}"
if [[ -z "$token" ]]; then
  token=$(op read "op://${OP_VAULT}/${OP_ITEM}/Bot User Auth Token")
fi

user_id="${SLACK_USER_ID:-}"
if [[ -z "$user_id" ]]; then
  user_id=$(op read "op://${OP_VAULT}/${OP_ITEM}/MemberID")
fi

payload=$(jq -n --arg channel "$user_id" --arg text "$message" \
  '{channel:$channel, text:$text}')

response=$(curl -sS -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $token" \
  -H "Content-type: application/json; charset=utf-8" \
  --data "$payload")

if [[ "$(jq -r .ok <<<"$response")" != "true" ]]; then
  err=$(jq -r .error <<<"$response")
  echo "notify.sh: slack error: $err" >&2
  exit 1
fi

ts=$(jq -r .ts <<<"$response")
echo "sent ts=$ts"
