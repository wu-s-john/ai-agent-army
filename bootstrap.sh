#!/bin/bash
# Bootstrap script for EC2 Ubuntu instances
# Usage: Pass as user-data when launching, or run manually via SSH
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
USER_HOME="/home/ubuntu"

echo "=== Updating system ==="
apt-get update && apt-get upgrade -y

echo "=== Installing core build tools ==="
apt-get install -y \
  build-essential \
  git \
  curl \
  wget \
  unzip \
  jq \
  htop \
  pkg-config \
  libssl-dev \
  cmake \
  clang \
  lldb \
  lld \
  zsh

# ─── 1Password CLI (secret management) ───
echo "=== Installing 1Password CLI ==="
curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
  gpg --dearmor -o /usr/share/keyrings/1password.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/1password.gpg] \
  https://downloads.1password.com/linux/debian/amd64 stable main" | \
  tee /etc/apt/sources.list.d/1password.list
apt-get update && apt-get install -y 1password-cli

# ─── GitHub CLI ───
echo "=== Installing GitHub CLI ==="
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
  dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
  https://cli.github.com/packages stable main" | \
  tee /etc/apt/sources.list.d/github-cli.list
apt-get update && apt-get install -y gh

# ─── Rust ───
echo "=== Installing Rust ==="
sudo -u ubuntu bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
sudo -u ubuntu bash -c 'source ~/.cargo/env && rustup component add rust-analyzer clippy rustfmt'

# ─── Node.js (for TypeScript) ───
echo "=== Installing Node.js ==="
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
npm install -g typescript ts-node

# ─── AWS CLI v2 ───
echo "=== Installing AWS CLI ==="
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

# ─── Python ───
echo "=== Installing Python ==="
apt-get install -y python3 python3-pip python3-venv

# ─── Claude Code ───
echo "=== Installing Claude Code ==="
sudo -u ubuntu bash -c 'curl -fsSL https://claude.ai/install.sh | bash'

# ─── Zed Editor ───
echo "=== Installing Zed ==="
sudo -u ubuntu bash -c 'curl -fsSL https://zed.dev/install.sh | bash'

# ─── Zellij (terminal multiplexer) ───
echo "=== Installing Zellij ==="
ZELLIJ_VERSION=$(curl -s https://api.github.com/repos/zellij-org/zellij/releases/latest | jq -r .tag_name)
curl -fsSL "https://github.com/zellij-org/zellij/releases/download/${ZELLIJ_VERSION}/zellij-x86_64-unknown-linux-musl.tar.gz" | tar xz -C /usr/local/bin

# ─── Modern CLI tools ───
echo "=== Installing modern CLI tools ==="
# ripgrep
apt-get install -y ripgrep

# fd-find
apt-get install -y fd-find
ln -sf /usr/bin/fdfind /usr/local/bin/fd

# bat
apt-get install -y bat
ln -sf /usr/bin/batcat /usr/local/bin/bat

# fzf
sudo -u ubuntu bash -c 'git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf && ~/.fzf/install --all --no-bash --no-fish'

# eza (modern ls)
apt-get install -y gpg
mkdir -p /etc/apt/keyrings
wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc | gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" | tee /etc/apt/sources.list.d/gierens.list
apt-get update && apt-get install -y eza

# zoxide (smart cd)
sudo -u ubuntu bash -c 'curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash'

# dust (disk usage)
DUST_VERSION=$(curl -s https://api.github.com/repos/bootandy/dust/releases/latest | jq -r .tag_name)
curl -fsSL "https://github.com/bootandy/dust/releases/download/${DUST_VERSION}/dust-${DUST_VERSION}-x86_64-unknown-linux-musl.tar.gz" | tar xz --strip-components=1 -C /usr/local/bin --wildcards '*/dust'

# ─── Starship prompt ───
echo "=== Installing Starship ==="
curl -sS https://starship.rs/install.sh | sh -s -- -y

# ─── Zsh as default shell ───
echo "=== Configuring zsh ==="
chsh -s /usr/bin/zsh ubuntu

# ─── Shell config (.zshrc) ───
echo "=== Writing shell config ==="
cat > "$USER_HOME/.zshrc" << 'ZSHRC'
# History
HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE

# Key bindings
bindkey -e
bindkey '^[[A' history-beginning-search-backward
bindkey '^[[B' history-beginning-search-forward

# Completion
autoload -Uz compinit && compinit
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'
zstyle ':completion:*' menu select

# Aliases — modern replacements
alias ls='eza --icons --group-directories-first'
alias ll='eza -la --icons --group-directories-first'
alias lt='eza --tree --level=3 --icons'
alias cat='bat --paging=never'
alias grep='rg'
alias find='fd'
alias du='dust'

# Git aliases
alias gs='git status'
alias gd='git diff'
alias gl='git log --oneline -20'
alias gp='git push'

# Rust
source "$HOME/.cargo/env" 2>/dev/null

# Zoxide (smart cd)
eval "$(zoxide init zsh)"

# fzf
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
export FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"

# Starship prompt
eval "$(starship init zsh)"

# Terminal — enable truecolor and OSC 52 clipboard
export COLORTERM=truecolor
export TERM=xterm-256color
ZSHRC
chown ubuntu:ubuntu "$USER_HOME/.zshrc"

# ─── Zellij config ───
echo "=== Configuring Zellij ==="
mkdir -p "$USER_HOME/.config/zellij"
cat > "$USER_HOME/.config/zellij/config.kdl" << 'ZELLIJ_CFG'
// Auto-attach to existing session or create new one
on_force_close "detach"
default_shell "zsh"
copy_on_select true
scrollback_editor "zed"

// OSC 52 clipboard passthrough (works over SSH with Blink)
copy_command "cat"
copy_clipboard "system"

ui {
    pane_frames {
        rounded_corners true
    }
}
ZELLIJ_CFG
chown -R ubuntu:ubuntu "$USER_HOME/.config/zellij"

# ─── Starship config (minimal, fast) ───
mkdir -p "$USER_HOME/.config"
cat > "$USER_HOME/.config/starship.toml" << 'STARSHIP_CFG'
format = "$hostname$directory$git_branch$git_status$rust$python$nodejs$cmd_duration$line_break$character"

[hostname]
ssh_only = true
format = "[$hostname]($style) "
style = "bold green"

[directory]
truncation_length = 3

[git_branch]
format = "[$branch]($style) "

[rust]
format = "[$version]($style) "

[cmd_duration]
min_time = 2000
format = "[$duration]($style) "
STARSHIP_CFG
chown -R ubuntu:ubuntu "$USER_HOME/.config"

# ─── SSH hardening for agent access ───
echo "=== Configuring SSH ==="
sed -i 's/^#\?MaxSessions.*/MaxSessions 20/' /etc/ssh/sshd_config
sed -i 's/^#\?MaxStartups.*/MaxStartups 10:30:60/' /etc/ssh/sshd_config
sed -i 's/^#\?ClientAliveInterval.*/ClientAliveInterval 60/' /etc/ssh/sshd_config
sed -i 's/^#\?ClientAliveCountMax.*/ClientAliveCountMax 10/' /etc/ssh/sshd_config
systemctl restart sshd

# ─── Summary ───
echo ""
echo "============================================"
echo "  Bootstrap complete!"
echo "============================================"
echo "Rust:    $(sudo -u ubuntu bash -c 'source ~/.cargo/env && rustc --version')"
echo "Node:    $(node --version)"
echo "Python:  $(python3 --version)"
echo "Zellij:  $(zellij --version)"
echo "Zed:     $(sudo -u ubuntu bash -c '~/.local/bin/zed --version 2>/dev/null || echo "installed"')"
echo "Claude:  $(sudo -u ubuntu bash -c 'claude --version 2>/dev/null || echo "run claude to authenticate"')"
echo "1Pass:   $(op --version)"
echo "GH CLI:  $(gh --version | head -1)"
echo ""
echo "SSH in and run: zellij"
echo "============================================"
