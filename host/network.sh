#!/usr/bin/env bash
# Create the dedicated libvirt NAT network and storage pool for the lab. Idempotent.
source "$(dirname "$0")/../lib/common.sh"

if ! vsh net-info "$LAB_NET_NAME" >/dev/null 2>&1; then
  log "Defining libvirt network $LAB_NET_NAME ($LAB_SUBNET_PREFIX.0/24)"
  xml=$(mktemp)
  cat >"$xml" <<EOF
<network>
  <name>$LAB_NET_NAME</name>
  <forward mode='nat'/>
  <bridge name='$LAB_BRIDGE' stp='on' delay='0'/>
  <domain name='$LAB_DOMAIN' localOnly='yes'/>
  <dns>
    <host ip='$LAB_GW_IP'>
      <hostname>gitea.$LAB_DOMAIN</hostname>
      <hostname>registry.$LAB_DOMAIN</hostname>
      <hostname>ollama.$LAB_DOMAIN</hostname>
    </host>
  </dns>
  <ip address='$LAB_GW_IP' netmask='255.255.255.0'>
    <dhcp>
      <range start='$LAB_SUBNET_PREFIX.100' end='$LAB_SUBNET_PREFIX.199'/>
    </dhcp>
  </ip>
</network>
EOF
  vsh net-define "$xml"
  rm -f "$xml"
fi
vsh net-autostart "$LAB_NET_NAME" >/dev/null
if ! vsh net-info "$LAB_NET_NAME" | grep -qE '^Active:\s+yes'; then vsh net-start "$LAB_NET_NAME"; fi

if ! vsh pool-info "$LAB_POOL_NAME" >/dev/null 2>&1; then
  log "Defining storage pool $LAB_POOL_NAME at $LAB_POOL_DIR"
  vsh pool-define-as "$LAB_POOL_NAME" dir --target "$LAB_POOL_DIR"
  vsh pool-build "$LAB_POOL_NAME"
fi
vsh pool-autostart "$LAB_POOL_NAME" >/dev/null
if ! vsh pool-info "$LAB_POOL_NAME" | grep -qE '^State:\s+running'; then vsh pool-start "$LAB_POOL_NAME"; fi
log "Network $LAB_NET_NAME and pool $LAB_POOL_NAME are up"
