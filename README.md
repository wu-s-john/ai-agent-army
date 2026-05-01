# Dotfiles & Shell Config

Cross-platform shell environment setup for macOS and Linux. One command to get an identical terminal experience on any machine.

## Setup

```bash
git clone <this-repo> && cd <this-repo>
./setup.sh
```

This is idempotent — safe to run multiple times. The script will:

1. Install CLI tools (via Homebrew on macOS, apt/cargo on Linux)
2. Build one shared skills directory and symlink both `~/.claude/skills` and `~/.codex/skills` to it
3. Set up your `.zshrc` (with options to replace, merge, or skip if one exists)
4. Install zsh plugins (autosuggestions, syntax highlighting)
5. Symlink zsh completions
6. Configure Claude Code default permissions

The shared skills directory lives at `~/.ai-agent-army/skills`. Repo-managed skills are linked from `claude/skills`, and Codex-managed entries such as `.system` are preserved there so both tools see the same custom skills.

## What gets installed

| Tool | Replaces | Description |
|------|----------|-------------|
| [eza](https://github.com/eza-community/eza) | `ls` | File listing with icons and git status |
| [bat](https://github.com/sharkdp/bat) | `cat` | Syntax-highlighted file viewer |
| [ripgrep](https://github.com/BurntSushi/ripgrep) | `grep` | Fast content search |
| [fd](https://github.com/sharkdp/fd) | `find` | Fast file finder |
| [dust](https://github.com/bootandy/dust) | `du` | Disk usage viewer |
| [zellij](https://github.com/zellij-org/zellij) | tmux | Terminal multiplexer |
| [zoxide](https://github.com/ajeetdsouza/zoxide) | `cd` | Smart directory jumper |
| [fzf](https://github.com/junegunn/fzf) | — | Fuzzy finder |
| [starship](https://starship.rs/) | — | Cross-shell prompt |
| [jq](https://jqlang.github.io/jq/) | — | JSON processor |

## Shell features

The zshrc includes:

- **Aliases** — coreutils replaced with modern alternatives
- **Fuzzy keybindings** — `Ctrl+F` file search, `Ctrl+G` content search, `Ctrl+P` directory jump
- **Git aliases** — `gs` (status), `gd` (diff), `gl` (log), `gp` (push)
- **Zellij helpers** — `zj` alias, `mux` for session attach-or-create

## Secrets

Secrets are managed via [1Password CLI](https://developer.1password.com/docs/cli/):

```bash
./secrets.sh
```

This runs `op inject` against `dotfiles/env-secrets.sh.tmpl` and writes the resolved values to `~/.env-secrets.sh`, which is sourced by the shell and git-ignored.

The template references secrets from your 1Password vault. If any items are missing from your vault, `op inject` will fail and tell you which `op://` reference could not be resolved. You can either:

- Create the missing items in your 1Password vault to match the `op://` paths in the template
- Edit `dotfiles/env-secrets.sh.tmpl` to remove or update references you don't need
