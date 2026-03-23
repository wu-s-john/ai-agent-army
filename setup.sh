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

# Claude config
mkdir -p "$CLAUDE_DIR"
echo "Setting up ~/.claude symlinks..."
symlink "$REPO_DIR/claude/CLAUDE.md"      "$CLAUDE_DIR/CLAUDE.md"
symlink "$REPO_DIR/claude/skills"         "$CLAUDE_DIR/skills"
symlink "$REPO_DIR/claude/settings.json"  "$CLAUDE_DIR/settings.json"

# Dotfiles
echo "Setting up dotfile symlinks..."
symlink "$REPO_DIR/dotfiles/zshrc"        "$HOME/.zshrc"

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
