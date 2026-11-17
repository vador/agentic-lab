#!/usr/bin/env bash
# Create a lab VM as a thin clone of the latest golden image.
source "$(dirname "$0")/../lib/common.sh"
source "$LAB_ROOT/lib/vm.sh"

usage() {
  cat <<EOF
Usage: lab vm new <name> [--role agent|ci|base] [--cpus N] [--ram MB] [--disk GB] [--ip N]

  --role agent  dev VM for AI agents + VS Code Remote-SSH (default)
  --role ci     Gitea Actions runner VM
  --role base   golden image only, no role setup (e.g. a per-client project VM: add agent role later)
  --ip N        last octet of the fixed IP ($LAB_SUBNET_PREFIX.N); default: first free in 10-99

The VM is reachable as 'ssh <name>' and in VS Code Remote-SSH as host '<name>'.
EOF
}

name=${1:-}
[[ -n $name && $name != -* ]] || { usage; exit 1; }
shift
[[ $name =~ ^[a-z][a-z0-9-]{0,30}$ ]] || die "invalid VM name '$name' (lowercase letters, digits, dashes)"
role=agent cpus="" ram="" disk="" octet=""
while (($#)); do
  case $1 in
    --role) role=$2; shift 2 ;;
    --cpus) cpus=$2; shift 2 ;;
    --ram) ram=$2; shift 2 ;;
    --disk) disk=$2; shift 2 ;;
    --ip) octet=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done
case $role in
  agent) : "${cpus:=$AGENT_VM_CPUS}" "${ram:=$AGENT_VM_RAM_MB}" "${disk:=$AGENT_VM_DISK_GB}" ;;
  ci) : "${cpus:=$CI_VM_CPUS}" "${ram:=$CI_VM_RAM_MB}" "${disk:=$CI_VM_DISK_GB}" ;;
  base) : "${cpus:=4}" "${ram:=4096}" "${disk:=40}" ;;
  *) die "unknown role '$role'" ;;
esac
need virt-install ssh

dom="$VM_PREFIX$name"
if vsh dominfo "$dom" >/dev/null 2>&1; then die "VM $dom already exists"; fi
golden=$(latest_golden) || die "no golden image yet: run lab vm golden"
if [[ $role == ci && ! -s $SECRETS_DIR/runner-token ]]; then die "no runner token: run lab services up first"; fi

# Fixed IP via DHCP reservation
used=$(reserved_ips)
if [[ -z $octet ]]; then
  for i in $(seq 10 99); do
    if ! grep -qx "$LAB_SUBNET_PREFIX.$i" <<<"$used"; then octet=$i; break; fi
  done
fi
ip="$LAB_SUBNET_PREFIX.$octet"
if grep -qx "$ip" <<<"$used"; then die "IP $ip is already reserved"; fi
mac=$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))

log "Creating $dom: role=$role cpus=$cpus ram=${ram}MB disk=${disk}G ip=$ip (from $golden)"
vsh net-update "$LAB_NET_NAME" add ip-dhcp-host "<host mac='$mac' name='$name' ip='$ip'/>" --live --config >/dev/null
vsh vol-create-as "$LAB_POOL_NAME" "$dom.qcow2" "${disk}G" --format qcow2 \
  --backing-vol "$golden" --backing-vol-format qcow2 >/dev/null

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
write_vm_env "$tmp/vm.env"
files=("$tmp/vm.env|/etc/agentlab/vm.env|0644")
if [[ $role != base ]]; then
  files+=("$LAB_ROOT/vm/provision/$role.sh|/opt/agentlab/provision/role.sh|0755")
fi
if [[ $role == ci ]]; then
  printf 'RUNNER_TOKEN=%s\n' "$(<"$SECRETS_DIR/runner-token")" >"$tmp/secrets.env"
  files+=("$tmp/secrets.env|/etc/agentlab/secrets.env|0600")
fi
cloudinit_user_data "$tmp/user-data" "$name" "${files[@]}"
if [[ $role != base ]]; then
  printf 'runcmd:\n  - [/opt/agentlab/provision/role.sh]\n' >>"$tmp/user-data"
fi
cloudinit_meta_data "$tmp/meta-data" "$name"

vinst --name "$dom" --memory "$ram" --vcpus "$cpus" --cpu host-passthrough \
  --osinfo linux2022 --import \
  --disk "vol=$LAB_POOL_NAME/$dom.qcow2,bus=virtio,discard=unmap" \
  --network "network=$LAB_NET_NAME,model=virtio,mac=$mac" \
  --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
  --graphics none --console pty,target_type=serial \
  --cloud-init "user-data=$tmp/user-data,meta-data=$tmp/meta-data" \
  --autostart --noautoconsole >/dev/null

"$LAB_ROOT/vm/vmctl.sh" ssh-config

log "Waiting for $name to come up and finish provisioning"
for _ in $(seq 1 60); do
  ssh -o BatchMode=yes -o ConnectTimeout=3 "$name" true 2>/dev/null && break
  sleep 5
done
if ssh "$name" 'sudo cloud-init status --wait >/dev/null'; then
  log "$name is ready: ssh $name   (VS Code: Remote-SSH → $name)"
else
  warn "provisioning reported errors — see: ssh $name sudo cat /var/log/cloud-init-output.log"
fi
