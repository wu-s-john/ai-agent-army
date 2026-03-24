#!/bin/bash
# Bootstrap script for EC2 macOS instances
# Usage: Pass as user-data when launching, or run manually via SSH
set -euo pipefail

USER_HOME="/Users/ec2-user"
BREW="/opt/homebrew/bin/brew"

echo "=== Installing Homebrew ==="
sudo -u ec2-user /bin/bash -c 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

echo "=== Installing core build tools ==="
sudo -u ec2-user $BREW install git curl wget jq htop cmake llvm

# ─── 1Password CLI (secret management) ───
echo "=== Installing 1Password CLI ==="
sudo -u ec2-user $BREW install --cask 1password-cli

# ─── GitHub CLI ───
echo "=== Installing GitHub CLI ==="
sudo -u ec2-user $BREW install gh

# ─── Rust ───
echo "=== Installing Rust ==="
sudo -u ec2-user bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
sudo -u ec2-user bash -c 'source ~/.cargo/env && rustup component add rust-analyzer clippy rustfmt'

# ─── Node.js ───
echo "=== Installing Node.js ==="
sudo -u ec2-user $BREW install node@22
sudo -u ec2-user $BREW link node@22
sudo -u ec2-user /opt/homebrew/bin/npm install -g typescript ts-node

# ─── AWS CLI ───
echo "=== Installing AWS CLI ==="
sudo -u ec2-user $BREW install awscli

# ─── Python ───
echo "=== Installing Python ==="
sudo -u ec2-user $BREW install python@3

# ─── Claude Code ───
echo "=== Installing Claude Code ==="
sudo -u ec2-user bash -c 'curl -fsSL https://claude.ai/install.sh | bash'

# ─── Zed Editor ───
echo "=== Installing Zed ==="
sudo -u ec2-user $BREW install --cask zed

# ─── Zellij (terminal multiplexer) ───
echo "=== Installing Zellij ==="
sudo -u ec2-user $BREW install zellij

# ─── Modern CLI tools ───
echo "=== Installing modern CLI tools ==="
sudo -u ec2-user $BREW install ripgrep fd bat fzf eza zoxide dust starship

# ─── Shell config (.zshrc) ───
echo "=== Writing shell config ==="
cat > "$USER_HOME/.zshrc" << 'ZSHRC'
# Homebrew
eval "$(/opt/homebrew/bin/brew shellenv)"

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
source <(fzf --zsh) 2>/dev/null
export FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"

# Starship prompt
eval "$(starship init zsh)"

# Terminal — enable truecolor and OSC 52 clipboard
export COLORTERM=truecolor
export TERM=xterm-256color
ZSHRC
chown ec2-user:staff "$USER_HOME/.zshrc"

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
chown -R ec2-user:staff "$USER_HOME/.config/zellij"

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
chown -R ec2-user:staff "$USER_HOME/.config"

# ─── SSH hardening for agent access ───
echo "=== Configuring SSH ==="
sed -i '' 's/^#\{0,1\}MaxSessions.*/MaxSessions 20/' /etc/ssh/sshd_config
sed -i '' 's/^#\{0,1\}MaxStartups.*/MaxStartups 10:30:60/' /etc/ssh/sshd_config
sed -i '' 's/^#\{0,1\}ClientAliveInterval.*/ClientAliveInterval 60/' /etc/ssh/sshd_config
sed -i '' 's/^#\{0,1\}ClientAliveCountMax.*/ClientAliveCountMax 10/' /etc/ssh/sshd_config
launchctl stop com.openssh.sshd 2>/dev/null || true
launchctl start com.openssh.sshd 2>/dev/null || true

# ─── Summary ───
echo ""
echo "============================================"
echo "  Bootstrap complete! (macOS)"
echo "============================================"
echo "Rust:    $(sudo -u ec2-user bash -c 'source ~/.cargo/env && rustc --version')"
echo "Node:    $(/opt/homebrew/bin/node --version)"
echo "Python:  $(/opt/homebrew/bin/python3 --version)"
echo "Zellij:  $(/opt/homebrew/bin/zellij --version)"
echo "Claude:  $(sudo -u ec2-user bash -c 'claude --version 2>/dev/null || echo "run claude to authenticate"')"
echo "1Pass:   $(/opt/homebrew/bin/op --version)"
echo "GH CLI:  $(/opt/homebrew/bin/gh --version | head -1)"
echo ""
echo "SSH in and run: zellij"
echo "============================================"
