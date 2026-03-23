#!/bin/bash
set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

symlink() {
  local src="$1"
  local dest="$2"
  local name="$(basename "$dest")"

  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    echo "  $name: already symlinked, skipping"
  elif [ -L "$dest" ] || [ -e "$dest" ]; then
    mv "$dest" "${dest}.bak"
    ln -s "$src" "$dest"
    echo "  $name: symlinked (existing backed up to ${name}.bak)"
  else
    ln -s "$src" "$dest"
    echo "  $name: symlinked"
  fi
}

# CLI tools
"$REPO_DIR/install_tools.sh"

# Claude config
mkdir -p "$CLAUDE_DIR"
echo "Setting up ~/.claude symlinks..."
symlink "$REPO_DIR/claude/CLAUDE.md"      "$CLAUDE_DIR/CLAUDE.md"
symlink "$REPO_DIR/claude/skills"         "$CLAUDE_DIR/skills"
symlink "$REPO_DIR/claude/settings.json"  "$CLAUDE_DIR/settings.json"

# Dotfiles
echo "Setting up dotfile symlinks..."
if [ -L "$HOME/.zshrc" ] && [ "$(readlink "$HOME/.zshrc")" = "$REPO_DIR/dotfiles/zshrc" ]; then
  echo "  .zshrc: already symlinked, skipping"
elif [ -e "$HOME/.zshrc" ] || [ -L "$HOME/.zshrc" ]; then
  echo ""
  echo "  An existing .zshrc was found."
  echo ""
  echo "  [r] Replace (recommended) — backs up existing to .zshrc.bak"
  echo "  [s] Source — appends a source line to your existing .zshrc"
  echo "  [c] Claude merge — use Claude Code to intelligently merge the configs"
  echo "  [n] Skip — leave your .zshrc unchanged"
  echo ""
  printf "  Your choice [r/s/c/n]: "
  read -r choice
  case "$choice" in
    r|R|"")
      mv "$HOME/.zshrc" "$HOME/.zshrc.bak"
      ln -s "$REPO_DIR/dotfiles/zshrc" "$HOME/.zshrc"
      echo "  .zshrc: replaced (backup at ~/.zshrc.bak)"
      ;;
    s|S)
      SOURCE_LINE="source \"$REPO_DIR/dotfiles/zshrc\""
      if grep -qF "$SOURCE_LINE" "$HOME/.zshrc" 2>/dev/null; then
        echo "  .zshrc: source line already present, skipping"
      else
        echo "" >> "$HOME/.zshrc"
        echo "# Added by ai-agent-army setup" >> "$HOME/.zshrc"
        echo "$SOURCE_LINE" >> "$HOME/.zshrc"
        echo "  .zshrc: source line appended"
      fi
      ;;
    c|C)
      echo "  .zshrc: skipping for now"
      echo ""
      echo "  Run this after setup to merge with Claude:"
      echo "    claude \"Merge $REPO_DIR/dotfiles/zshrc into ~/.zshrc — deduplicate, preserve my customizations, prefer the repo config for any conflicts\""
      echo ""
      ;;
    n|N)
      echo "  .zshrc: skipped"
      ;;
    *)
      echo "  .zshrc: unrecognized choice, skipping"
      ;;
  esac
else
  ln -s "$REPO_DIR/dotfiles/zshrc" "$HOME/.zshrc"
  echo "  .zshrc: symlinked"
fi

# Zsh plugins
ZSH_PLUGIN_DIR="$HOME/.zsh"
mkdir -p "$ZSH_PLUGIN_DIR"

clone_plugin() {
  local repo="$1"
  local name="$(basename "$repo")"
  if [ -d "$ZSH_PLUGIN_DIR/$name" ]; then
    echo "  $name: already installed, skipping"
  else
    git clone --depth=1 "https://github.com/$repo.git" "$ZSH_PLUGIN_DIR/$name"
    echo "  $name: installed"
  fi
}

echo "Setting up zsh plugins..."
clone_plugin "zsh-users/zsh-autosuggestions"
clone_plugin "zsh-users/zsh-syntax-highlighting"

# Zsh completions
echo "Setting up zsh completions..."
for f in "$REPO_DIR/dotfiles/zsh-completions"/_*; do
  symlink "$f" "$ZSH_PLUGIN_DIR/$(basename "$f")"
done

# Claude Code permissions
"$REPO_DIR/claude_setup.sh"

echo "Done. Restart your shell for changes to take effect."
