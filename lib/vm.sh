#!/usr/bin/env bash
# VM helpers (cloud-init rendering, image lookup). Source after lib/common.sh.

BASE_VOL="debian-13-base.qcow2"

latest_golden() {
  vsh vol-list --pool "$LAB_POOL_NAME" | awk '$1 ~ /^golden-.*\.qcow2$/ {print $1}' | sort | tail -n1 | grep .
}

reserved_ips() { # IPs with a DHCP reservation in the lab network
  vsh net-dumpxml "$LAB_NET_NAME" | grep -oP "<host mac='[^']+' name='[^']+' ip='\K[0-9.]+" || true
}

# name|ip lines for every reserved VM
reserved_hosts() {
  vsh net-dumpxml "$LAB_NET_NAME" | grep -oP "<host mac='[^']+' name='\K[^']+' ip='[0-9.]+" \
    | sed "s/' ip='/|/" || true
}

# Non-secret settings shipped to every VM as /etc/agentlab/vm.env
write_vm_env() {
  cat >"$1" <<EOF
VM_USER=$VM_USER
LAB_DOMAIN=$LAB_DOMAIN
GITEA_URL=$GITEA_INTERNAL_URL
GITEA_SSH_PORT=$GITEA_SSH_PORT
REGISTRY_MIRROR=registry.$LAB_DOMAIN:$REGISTRY_PORT
TEA_VERSION=$TEA_VERSION
RUNNER_VERSION=$RUNNER_VERSION
RUNNER_CAPACITY=$RUNNER_CAPACITY
RUNNER_LABELS="$RUNNER_LABELS"
NODE_VERSION=$NODE_VERSION
AI_CLIS="$AI_CLIS"
EOF
}

# cloudinit_user_data OUT HOSTNAME "src|dest|mode"...
# Writes a #cloud-config with the dev user and the given files embedded (base64).
# Callers append their own runcmd: section.
cloudinit_user_data() {
  local out=$1 host=$2
  shift 2
  [[ -f $SSH_PUBKEY_FILE ]] || die "SSH public key $SSH_PUBKEY_FILE not found (ssh-keygen -t ed25519)"
  {
    cat <<EOF
#cloud-config
hostname: $host
fqdn: $host.$LAB_DOMAIN
prefer_fqdn_over_hostname: false
timezone: $LAB_TZ
ssh_pwauth: false
users:
  - name: $VM_USER
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - $(<"$SSH_PUBKEY_FILE")
write_files:
EOF
    local spec src dest mode
    for spec in "$@"; do
      IFS='|' read -r src dest mode <<<"$spec"
      cat <<EOF
  - path: $dest
    permissions: '$mode'
    encoding: b64
    content: $(base64 -w0 "$src")
EOF
    done
  } >"$out"
}

cloudinit_meta_data() { # OUT HOSTNAME
  printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$2" "$(date +%s)" "$2" >"$1"
}

wait_for_state() { # DOMAIN STATE TIMEOUT_SECONDS
  local dom=$1 want=$2 t=$3 i
  for ((i = 0; i < t; i += 10)); do
    [[ $(vsh domstate "$dom" 2>/dev/null) == "$want" ]] && return 0
    printf '.' >&2
    sleep 10
  done
  echo >&2
  return 1
}
