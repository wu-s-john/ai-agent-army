#!/usr/bin/env bash
# Start or resume a Codex thread for a Linear-driven agent session.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  codex-linear-run.sh start --cwd DIR --issue LIN-123 --title TITLE --url URL --branch BRANCH --description-file FILE
  codex-linear-run.sh resume --cwd DIR --thread-id THREAD --issue LIN-123 --sender NAME --title TITLE --url URL --message-file FILE

This helper only normalizes prompts and invokes Codex. It does not verify
webhook signatures, acquire locks, call Linear APIs, or update session state.
EOF
}

mode="${1:-}"
if [[ -z "$mode" || "$mode" == "--help" || "$mode" == "-h" ]]; then
  usage
  exit 0
fi
shift

cwd=""
thread_id=""
issue=""
sender=""
title=""
url=""
branch=""
description_file=""
message_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) cwd="${2:-}"; shift 2 ;;
    --thread-id) thread_id="${2:-}"; shift 2 ;;
    --issue) issue="${2:-}"; shift 2 ;;
    --sender) sender="${2:-}"; shift 2 ;;
    --title) title="${2:-}"; shift 2 ;;
    --url) url="${2:-}"; shift 2 ;;
    --branch) branch="${2:-}"; shift 2 ;;
    --description-file) description_file="${2:-}"; shift 2 ;;
    --message-file) message_file="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "codex-linear-run.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

require() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo "codex-linear-run.sh: missing required $name" >&2
    usage >&2
    exit 2
  fi
}

require_file() {
  local name="$1"
  local file="$2"
  require "$name" "$file"
  if [[ ! -f "$file" ]]; then
    echo "codex-linear-run.sh: $name is not a file: $file" >&2
    exit 2
  fi
}

case "$mode" in
  start)
    require "--cwd" "$cwd"
    require "--issue" "$issue"
    require "--title" "$title"
    require "--url" "$url"
    require "--branch" "$branch"
    require_file "--description-file" "$description_file"

    description="$(<"$description_file")"
    prompt=$(printf 'You are working on Linear issue %s: %s\nURL: %s\n\nDescription:\n%s\n\nUse the linear-agent-session workflow. Keep Linear updated at start, blocker, and final result. Create or use branch %s if code changes are needed.\n' \
      "$issue" "$title" "$url" "$description" "$branch")

    exec codex exec -C "$cwd" --json "$prompt"
    ;;

  resume)
    require "--cwd" "$cwd"
    require "--thread-id" "$thread_id"
    require "--issue" "$issue"
    require "--title" "$title"
    require "--url" "$url"
    require_file "--message-file" "$message_file"

    sender="${sender:-unknown}"
    message="$(<"$message_file")"
    normalized=$(printf '[Linear %s from %s]\n%s\n\nIssue: %s\nURL: %s\n' \
      "$issue" "$sender" "$message" "$title" "$url")

    printf '%s\n' "$normalized" | exec codex exec -C "$cwd" resume --json "$thread_id" -
    ;;

  *)
    echo "codex-linear-run.sh: mode must be start or resume" >&2
    usage >&2
    exit 2
    ;;
esac
