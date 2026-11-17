#!/usr/bin/env bash
# Role "ci": runs once, as root, at first boot of the CI VM. Installs and registers the
# Gitea Actions runner (jobs run in Docker containers inside this VM).
set -euxo pipefail
source /etc/agentlab/vm.env
set +x  # keep tokens out of the cloud-init log
source /etc/agentlab/secrets.env
set -x

R=/var/lib/gitea-runner
id gitea-runner >/dev/null 2>&1 ||
  useradd --system --create-home --home-dir "$R" --shell /usr/sbin/nologin -G docker gitea-runner

# act_runner >= 6.0 ships as "gitea-runner"
curl -fsSL -o /usr/local/bin/gitea-runner \
  "https://dl.gitea.com/act_runner/$RUNNER_VERSION/gitea-runner-$RUNNER_VERSION-linux-amd64"
chmod 755 /usr/local/bin/gitea-runner

cd "$R"
runuser -u gitea-runner -- /usr/local/bin/gitea-runner generate-config >config.yaml
sed -i -E "s/^(\s*capacity:).*/\1 $RUNNER_CAPACITY/" config.yaml
chown gitea-runner:gitea-runner config.yaml

if [[ ! -f .runner ]]; then
  set +x
  runuser -u gitea-runner -- /usr/local/bin/gitea-runner register --no-interactive \
    --config "$R/config.yaml" \
    --instance "$GITEA_URL" --token "$RUNNER_TOKEN" \
    --name "$(hostname)" --labels "$RUNNER_LABELS"
  set -x
fi

cat >/etc/systemd/system/gitea-runner.service <<EOF
[Unit]
Description=Gitea Actions runner
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
User=gitea-runner
WorkingDirectory=$R
ExecStart=/usr/local/bin/gitea-runner daemon --config $R/config.yaml
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now gitea-runner.service

# Read access to the human-owned checks repo, for the runner only (jobs never see it)
if [[ -n ${CHECKS_TOKEN:-} ]]; then
  set +x
  git config --file "$R/.gitconfig" "http.$GITEA_URL/$CHECKS_ORG/.extraHeader" "Authorization: token $CHECKS_TOKEN"
  chown gitea-runner:gitea-runner "$R/.gitconfig"
  chmod 600 "$R/.gitconfig"
  set -x
fi

# The registration and checks tokens are no longer needed here
shred -u /etc/agentlab/secrets.env || rm -f /etc/agentlab/secrets.env
