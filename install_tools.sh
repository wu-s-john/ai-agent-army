#!/bin/bash
set -euo pipefail

# Idempotently install CLI tools across macOS (Homebrew) and Linux (apt/snap/cargo)

BREW_TOOLS=(
  eza
  bat
  ripgrep
  fd
  dust
  zellij
  zoxide
  fzf
  starship
  jq
  just
  uv
  syncthing
  node
  supabase/tap/supabase
)

BREW_CASKS=(
  codex
  docker
  ghostty
  tailscale
)

install_macos() {
  if ! command -v brew &>/dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

  echo "Installing tools via Homebrew..."
  for tool in "${BREW_TOOLS[@]}"; do
    if brew list "$tool" &>/dev/null; then
      echo "  $tool: already installed, skipping"
    else
      brew install "$tool"
      echo "  $tool: installed"
    fi
  done

  # Enable pnpm via corepack (ships with Node)
  echo "Enabling pnpm via corepack..."
  sudo corepack enable
  corepack prepare pnpm@latest --activate
  echo "  pnpm: enabled"

  echo "Installing cask apps via Homebrew..."
  for cask in "${BREW_CASKS[@]}"; do
    if brew list --cask "$cask" &>/dev/null; then
      echo "  $cask: already installed, skipping"
    else
      brew install --cask "$cask"
      echo "  $cask: installed"
    fi
  done
}

install_linux() {
  echo "Installing tools on Linux..."

  # apt packages
  local apt_needed=()
  declare -A apt_map=(
    [bat]="bat"
    [ripgrep]="ripgrep"
    [fd]="fd-find"
    [fzf]="fzf"
    [jq]="jq"
    [syncthing]="syncthing"
  )

  for tool in "${!apt_map[@]}"; do
    if command -v "$tool" &>/dev/null || command -v "${apt_map[$tool]}" &>/dev/null; then
      echo "  $tool: already installed, skipping"
    else
      apt_needed+=("${apt_map[$tool]}")
    fi
  done

  if [[ ${#apt_needed[@]} -gt 0 ]]; then
    sudo apt-get update -qq
    sudo apt-get install -y "${apt_needed[@]}"
  fi

  # fd-find creates fdfind on Ubuntu — symlink to fd
  if command -v fdfind &>/dev/null && ! command -v fd &>/dev/null; then
    mkdir -p ~/.local/bin
    ln -sf "$(which fdfind)" ~/.local/bin/fd
    echo "  fd: symlinked fdfind -> fd"
  fi

  # batcat on Ubuntu — symlink to bat
  if command -v batcat &>/dev/null && ! command -v bat &>/dev/null; then
    mkdir -p ~/.local/bin
    ln -sf "$(which batcat)" ~/.local/bin/bat
    echo "  bat: symlinked batcat -> bat"
  fi

  # Cargo-based installs
  if ! command -v cargo &>/dev/null; then
    echo "Installing Rust/Cargo..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
  fi

  local cargo_tools=(eza dust zellij)
  for tool in "${cargo_tools[@]}"; do
    if command -v "$tool" &>/dev/null; then
      echo "  $tool: already installed, skipping"
    else
      cargo install "$tool"
      echo "  $tool: installed"
    fi
  done

  # Zoxide (installer script)
  if command -v zoxide &>/dev/null; then
    echo "  zoxide: already installed, skipping"
  else
    curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
    echo "  zoxide: installed"
  fi

  # Starship (installer script)
  if command -v starship &>/dev/null; then
    echo "  starship: already installed, skipping"
  else
    curl -sS https://starship.rs/install.sh | sh -s -- -y
    echo "  starship: installed"
  fi

  # Ghostty (snap)
  if command -v ghostty &>/dev/null; then
    echo "  ghostty: already installed, skipping"
  else
    sudo snap install ghostty --classic
    echo "  ghostty: installed"
  fi

  # Tailscale (official install script)
  if command -v tailscale &>/dev/null; then
    echo "  tailscale: already installed, skipping"
  else
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "  tailscale: installed"
  fi

  # Node.js + npm
  if command -v node &>/dev/null; then
    echo "  node: already installed, skipping"
  else
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs
    echo "  node: installed"
  fi

  # Enable pnpm via corepack (ships with Node)
  echo "Enabling pnpm via corepack..."
  corepack enable
  corepack prepare pnpm@latest --activate
  echo "  pnpm: enabled"

  # Docker
  if command -v docker &>/dev/null; then
    echo "  docker: already installed, skipping"
  else
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    echo "  docker: installed (log out and back in for group membership)"
  fi

  # Supabase CLI
  if command -v supabase &>/dev/null; then
    echo "  supabase: already installed, skipping"
  else
    curl -sSL https://raw.githubusercontent.com/supabase/cli/main/install.sh | sh
    echo "  supabase: installed"
  fi

  # uv (Python package manager)
  if command -v uv &>/dev/null; then
    echo "  uv: already installed, skipping"
  else
    curl -LsSf https://astral.sh/uv/install.sh | sh
    echo "  uv: installed"
  fi
}

# ─── Main ───
echo "Installing CLI tools..."
if [[ "$OSTYPE" == darwin* ]]; then
  install_macos
else
  install_linux
fi

# ─── Codex config (model + MCP servers) ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_CFG="$SCRIPT_DIR/dotfiles/codex/config.toml"
REPO_SKILLS_SRC="$SCRIPT_DIR/claude/skills"
SHARED_SKILLS_DIR="$HOME/.ai-agent-army/skills"

symlink_path() {
  local src="$1"
  local dest="$2"
  local name
  name="$(basename "$dest")"

  mkdir -p "$(dirname "$dest")"

  if [[ -L "$dest" && "$(readlink "$dest")" = "$src" ]]; then
    echo "  $dest: already symlinked, skipping"
  elif [[ -L "$dest" || -e "$dest" ]]; then
    mv "$dest" "${dest}.bak"
    ln -s "$src" "$dest"
    echo "  $name: symlinked (existing backed up to ${name}.bak)"
  else
    ln -s "$src" "$dest"
    echo "  $name: symlinked"
  fi
}

migrate_non_repo_skills() {
  local source_dir="$1"
  local source_label="$2"
  local entry
  local name
  local target

  [[ -d "$source_dir" ]] || return 0
  [[ -L "$source_dir" ]] && return 0

  mkdir -p "$SHARED_SKILLS_DIR"

  for entry in "$source_dir"/.* "$source_dir"/*; do
    [[ -e "$entry" || -L "$entry" ]] || continue

    name="$(basename "$entry")"
    [[ "$name" = "." || "$name" = ".." ]] && continue

    # Repo-backed skills will be re-symlinked from claude/skills.
    if [[ "$name" != ".system" ]] && ([[ -e "$REPO_SKILLS_SRC/$name" ]] || [[ -L "$REPO_SKILLS_SRC/$name" ]]); then
      continue
    fi

    target="$SHARED_SKILLS_DIR/$name"
    if [[ -e "$target" || -L "$target" ]]; then
      echo "  Preserving existing shared skill entry: $name"
      continue
    fi

    mv "$entry" "$target"
    echo "  migrated $source_label/$name -> $target"
  done
}

if [[ -f "$CODEX_CFG" ]]; then
  mkdir -p ~/.codex
  ln -sf "$CODEX_CFG" "$HOME/.codex/config.toml"
  echo "Symlinked ~/.codex/config.toml -> $CODEX_CFG"
fi

# ─── Unified skills directory (Claude Code + Codex) ───
#
# Both ~/.claude/skills and ~/.codex/skills point at the same shared directory.
# The shared directory is populated from repo-managed skills under claude/skills
# and preserves Codex-managed entries like .system.
if [[ -d "$REPO_SKILLS_SRC" ]]; then
  echo "Building shared skills directory..."
  mkdir -p "$SHARED_SKILLS_DIR"

  migrate_non_repo_skills "$HOME/.claude/skills" "~/.claude/skills"
  migrate_non_repo_skills "$HOME/.codex/skills" "~/.codex/skills"

  for skill in "$REPO_SKILLS_SRC"/*; do
    [[ -e "$skill" || -L "$skill" ]] || continue

    name="$(basename "$skill")"
    target="$SHARED_SKILLS_DIR/$name"

    if [[ -L "$target" && "$(readlink "$target")" = "$skill" ]]; then
      echo "  $target: already linked, skipping"
      continue
    fi

    if [[ -L "$target" || -e "$target" ]]; then
      mv "$target" "${target}.bak"
      echo "  Backed up conflicting shared skill entry: $target.bak"
    fi

    ln -s "$skill" "$target"
    echo "  $target -> $skill"
  done

  symlink_path "$SHARED_SKILLS_DIR" "$HOME/.claude/skills"
  symlink_path "$SHARED_SKILLS_DIR" "$HOME/.codex/skills"
fi

# Install Python via uv
echo "Setting up Python via uv..."
if command -v uv &>/dev/null; then
  uv python install
  echo "  python: installed via uv"
else
  echo "  WARNING: uv not found, skipping Python install"
fi

echo "Done."
