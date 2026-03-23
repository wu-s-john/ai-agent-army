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
}

# ─── Main ───
echo "Installing CLI tools..."
if [[ "$OSTYPE" == darwin* ]]; then
  install_macos
else
  install_linux
fi
echo "Done."
