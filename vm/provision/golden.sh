#!/usr/bin/env bash
# Runs ONCE, as root, inside the golden build VM (via cloud-init). Installs everything common
# to all lab VMs, then resets cloud-init and powers off so the disk can be cloned.
set -euxo pipefail
source /etc/agentlab/vm.env
export DEBIAN_FRONTEND=noninteractive
U=$VM_USER
H=/home/$U
as_user() { runuser -u "$U" -- env HOME="$H" bash -lc "$1"; }

# --- base packages ---------------------------------------------------------------------------
apt-get update
apt-get -y full-upgrade
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg git git-lfs tmux jq unzip zip make build-essential pkg-config \
  direnv ripgrep fd-find htop tree vim less bash-completion rsync openssh-server \
  python3 python3-venv python3-pip pipx qemu-guest-agent extrepo
systemctl enable qemu-guest-agent || true

# --- Docker (uses the host's registry mirror) ------------------------------------------------
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<EOF
{
  "registry-mirrors": ["http://$REGISTRY_MIRROR"],
  "insecure-registries": ["$REGISTRY_MIRROR"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  >/etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker "$U"
cat >/etc/cron.weekly/agentlab-docker-prune <<'EOF'
#!/bin/sh
docker system prune -af --filter until=168h >/dev/null 2>&1
docker builder prune -af --filter until=168h >/dev/null 2>&1
EOF
chmod 755 /etc/cron.weekly/agentlab-docker-prune

# --- mise (per-project toolchains) -----------------------------------------------------------
extrepo enable mise
apt-get update
apt-get install -y mise

# --- tea (Gitea CLI, used by agents to open PRs) ---------------------------------------------
curl -fsSL -o /usr/local/bin/tea "https://dl.gitea.com/tea/$TEA_VERSION/tea-$TEA_VERSION-linux-amd64"
chmod 755 /usr/local/bin/tea

# --- agt (worktree + tmux task helper) -------------------------------------------------------
install -m 0755 /opt/agentlab/tools/agt /usr/local/bin/agt

# --- user environment ------------------------------------------------------------------------
cat >>"$H/.profile" <<'EOF'

# --- agentlab: make mise tools visible to non-interactive shells (ssh cmd, VS Code) ---
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
EOF
cat >>"$H/.bashrc" <<'EOF'

# --- agentlab ---
export PATH="$HOME/.local/bin:$PATH"
eval "$(mise activate bash)"
eval "$(direnv hook bash)"
alias fd=fdfind
EOF
cat >"$H/.tmux.conf" <<'EOF'
set -g mouse on
set -g history-limit 100000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -g default-terminal "tmux-256color"
set -g status-right "#S | %H:%M"
EOF
install -d -m 700 -o "$U" -g "$U" "$H/.ssh" "$H/.ssh/config.d" "$H/.ssh/agentlab"
printf 'Include config.d/*\n' >"$H/.ssh/config"
install -d -o "$U" -g "$U" "$H/work"
chown "$U:$U" "$H/.profile" "$H/.bashrc" "$H/.tmux.conf" "$H/.ssh/config"
chmod 600 "$H/.ssh/config"

as_user 'git config --global init.defaultBranch main
git config --global pull.rebase true
git config --global push.autoSetupRemote true
git config --global fetch.prune true
git config --global rerere.enabled true'

# --- Node + AI coding CLIs ---------------------------------------------------------------------
as_user "mise use -g node@$NODE_VERSION"
for cli in $AI_CLIS; do
  case $cli in
    claude) as_user 'curl -fsSL https://claude.ai/install.sh | bash' ;;
    codex) as_user 'mise exec -- npm install -g @openai/codex' ;;
    gemini) as_user 'mise exec -- npm install -g @google/gemini-cli' ;;
    *) echo "unknown AI CLI '$cli' — skipped" ;;
  esac
done
as_user 'mise reshim'

# --- seal the image ------------------------------------------------------------------------------
apt-get -y autoremove
apt-get clean
date -Is >/etc/agentlab/golden-built
fstrim -av || true
cloud-init clean --logs --machine-id
systemd-run --on-active=5 --unit=agentlab-poweroff systemctl poweroff
