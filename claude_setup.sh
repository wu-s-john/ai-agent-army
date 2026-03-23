#!/bin/bash
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"

setup_permissions() {
  local target="$CLAUDE_DIR/settings.local.json"

  # Start from existing file or empty object
  local existing='{}'
  if [[ -f "$target" ]]; then
    existing=$(cat "$target")
  fi

  local allow_rules='[
    "Bash(grep *)",
    "Bash(rg *)",
    "Bash(find *)",
    "Bash(fd *)",
    "Bash(ls *)",
    "Bash(cat *)",
    "Bash(head *)",
    "Bash(tail *)",
    "Bash(wc *)",
    "Bash(sort *)",
    "Bash(uniq *)",
    "Bash(diff *)",
    "Bash(git status*)",
    "Bash(git diff*)",
    "Bash(git log*)",
    "Bash(git branch*)",
    "Bash(git show*)",
    "Bash(git blame*)",
    "Bash(git rev-parse*)",
    "Bash(git remote -v*)",
    "Bash(which *)",
    "Bash(echo *)",
    "Bash(pwd)",
    "Bash(env)",
    "Write(//tmp/*)",
    "Edit(//tmp/*)"
  ]'

  local deny_rules='[
    "Bash(rm -rf //*)",
    "Bash(git push --force*)",
    "Bash(git reset --hard*)"
  ]'

  local before_count=0
  if [[ "$existing" != '{}' ]]; then
    before_count=$(echo "$existing" | jq '((.permissions.allow // []) + (.permissions.deny // [])) | length')
  fi

  echo "$existing" | jq \
    --argjson new_allow "$allow_rules" \
    --argjson new_deny "$deny_rules" \
    '.permissions.allow = ((.permissions.allow // []) + $new_allow | unique) |
     .permissions.deny  = ((.permissions.deny  // []) + $new_deny  | unique)' \
    > "$target.tmp" && mv "$target.tmp" "$target"

  local after_count
  after_count=$(jq '((.permissions.allow // []) + (.permissions.deny // [])) | length' "$target")
  local added=$((after_count - before_count))

  if [[ "$added" -gt 0 ]]; then
    echo "  permissions: added $added rules to $target"
  else
    echo "  permissions: already up to date"
  fi
}

# ─── Main ───
mkdir -p "$CLAUDE_DIR"
echo "Setting up Claude Code..."
setup_permissions
echo "Done."
