#!/usr/bin/env bash
# Prepare the Debian 13 host: KVM/libvirt, Docker, lab network + storage pool, firewall, /etc/hosts.
# Run as your normal user; it calls sudo where needed. Idempotent.
source "$(dirname "$0")/../lib/common.sh"
[[ $EUID -ne 0 ]] || die "run as your normal user, not root (sudo is used internally)"
ME=$(id -un)

log "Installing host packages"
sudo apt-get update
sudo apt-get install -y \
  git curl jq ca-certificates gnupg nftables openssh-client \
  qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients dnsmasq-base \
  virtinst virt-manager

if ! command -v docker >/dev/null; then
  log "Installing Docker Engine (official repository)"
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $codename stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

log "Configuring Docker so it does not break libvirt VM forwarding"
# Docker normally sets the iptables FORWARD policy to DROP, which cuts VM traffic.
tmp=$(mktemp)
if sudo test -s /etc/docker/daemon.json; then
  sudo cat /etc/docker/daemon.json | jq '. + {"ip-forward-no-drop": true}' >"$tmp"
else
  echo '{ "ip-forward-no-drop": true }' | jq . >"$tmp"
fi
sudo install -D -m 0644 "$tmp" /etc/docker/daemon.json
rm -f "$tmp"

# Let Docker bind published ports to $LAB_GW_IP even if the bridge is not up yet at boot.
echo "net.ipv4.ip_nonlocal_bind = 1" | sudo tee /etc/sysctl.d/90-agentlab.conf >/dev/null
sudo sysctl -q --system

sudo systemctl enable --now docker.service
sudo systemctl restart docker.service
sudo systemctl enable --now libvirtd.service 2>/dev/null || true

log "Adding $ME to groups libvirt, kvm, docker (log out/in afterwards)"
sudo usermod -aG libvirt,kvm,docker "$ME"

log "Adding lab host names to /etc/hosts"
if ! grep -q '# agentlab$' /etc/hosts; then
  echo "$LAB_GW_IP gitea.$LAB_DOMAIN registry.$LAB_DOMAIN ollama.$LAB_DOMAIN # agentlab" | sudo tee -a /etc/hosts >/dev/null
fi

"$LAB_ROOT/host/network.sh"
"$LAB_ROOT/host/firewall.sh"

if [[ ! -f $SSH_PUBKEY_FILE ]]; then
  warn "No SSH public key at $SSH_PUBKEY_FILE. Create one with: ssh-keygen -t ed25519"
fi

log "Host ready. Log out and back in (or reboot) so the libvirt/docker groups apply."
log "Next: lab services up"
