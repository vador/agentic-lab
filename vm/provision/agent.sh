#!/usr/bin/env bash
# Role "agent": runs once, as root, at first boot of an agent VM (on top of the golden image).
set -euxo pipefail
source /etc/agentlab/vm.env
U=$VM_USER
H=/home/$U

# Trust the lab Gitea SSH host key
ssh-keyscan -p "$GITEA_SSH_PORT" "gitea.$LAB_DOMAIN" >>"$H/.ssh/known_hosts" 2>/dev/null || true
chown "$U:$U" "$H/.ssh/known_hosts" 2>/dev/null || true

# Pick up any tool updates since the golden image was built
runuser -u "$U" -- env HOME="$H" bash -lc 'command -v claude >/dev/null && claude update || true'

cat >/etc/motd <<EOF

  agentlab agent VM — everything here is disposable; code lives in Gitea ($GITEA_URL).
  Projects: ~/work/<org>/<repo>/main     New task: agt new <org>[/<repo>] <branch>
  Snapshot from the host before long autonomous runs: lab vm snapshot $(hostname)

EOF
