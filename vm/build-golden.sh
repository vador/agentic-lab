#!/usr/bin/env bash
# Build a "golden" image: Debian 13 cloud image + all common tooling (Docker, mise, Node,
# AI CLIs, tea...). Every lab VM is a thin copy-on-write clone of the latest golden image.
# Each build creates a new golden-<date>.qcow2; existing VMs keep using the one they were cloned from.
source "$(dirname "$0")/../lib/common.sh"
source "$LAB_ROOT/lib/vm.sh"
need virt-install curl sha512sum

ensure_base_image() {
  vsh vol-info --pool "$LAB_POOL_NAME" "$BASE_VOL" >/dev/null 2>&1 && return 0
  log "Downloading Debian 13 cloud image"
  local dl file expected actual
  dl=$(mktemp -d)
  file=$(basename "$DEBIAN_IMAGE_URL")
  curl -fL --progress-bar -o "$dl/$file" "$DEBIAN_IMAGE_URL"
  curl -fsSL -o "$dl/SHA512SUMS" "$DEBIAN_SUMS_URL"
  expected=$(awk -v f="$file" '$2 == f {print $1}' "$dl/SHA512SUMS")
  actual=$(sha512sum "$dl/$file" | cut -d' ' -f1)
  [[ -n $expected && $expected == "$actual" ]] || { rm -rf "$dl"; die "checksum mismatch for $file"; }
  log "Uploading base image into pool $LAB_POOL_NAME"
  vsh vol-create-as "$LAB_POOL_NAME" "$BASE_VOL" "$(stat -c%s "$dl/$file")" --format qcow2 >/dev/null
  vsh vol-upload --pool "$LAB_POOL_NAME" "$BASE_VOL" "$dl/$file"
  vsh pool-refresh "$LAB_POOL_NAME" >/dev/null
  rm -rf "$dl"
}

ensure_base_image
ensure_uefi_firmware
mapfile -t UEFI < <(uefi_args)

build="${VM_PREFIX}golden-build"
if vsh dominfo "$build" >/dev/null 2>&1; then
  die "a previous build VM '$build' exists. Inspect it (virsh console $build) or remove it:
   virsh destroy $build; virsh undefine $build --nvram --remove-all-storage"
fi

vol="golden-$(date +%Y%m%d-%H%M).qcow2"
log "Creating $vol (backed by $BASE_VOL)"
vsh vol-create-as "$LAB_POOL_NAME" "$vol" "${GOLDEN_DISK_GB}G" --format qcow2 \
  --backing-vol "$BASE_VOL" --backing-vol-format qcow2 >/dev/null

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
write_vm_env "$tmp/vm.env"
cloudinit_user_data "$tmp/user-data" golden \
  "$tmp/vm.env|/etc/agentlab/vm.env|0644" \
  "$LAB_ROOT/vm/provision/golden.sh|/opt/agentlab/provision/golden.sh|0755" \
  "$LAB_ROOT/vm/tools/agt|/opt/agentlab/tools/agt|0755"
cat >>"$tmp/user-data" <<'EOF'
runcmd:
  - [/opt/agentlab/provision/golden.sh]
EOF
cloudinit_meta_data "$tmp/meta-data" golden

log "Booting build VM (provisioning takes ~5-15 min; it powers off when done)"
vinst --name "$build" --memory 4096 --vcpus 4 --cpu host-passthrough \
  --osinfo linux2022 --import "${UEFI[@]}" \
  --disk "vol=$LAB_POOL_NAME/$vol,bus=virtio" \
  --network "network=$LAB_NET_NAME,model=virtio" \
  --graphics none --console pty,target_type=serial \
  --cloud-init "user-data=$tmp/user-data,meta-data=$tmp/meta-data" \
  --noautoconsole >/dev/null

if ! wait_for_state "$build" "shut off" 2700; then
  die "build did not finish in 45 min. Debug with: virsh console $build  (log: /var/log/cloud-init-output.log)"
fi

# A crashed/failed qemu also ends in "shut off": only a guest-initiated shutdown counts,
# and the provisioning must have actually written to the disk.
reason=$(vsh domstate "$build" --reason)
vsh pool-refresh "$LAB_POOL_NAME" >/dev/null
alloc=$(vsh vol-dumpxml --pool "$LAB_POOL_NAME" "$vol" | grep -oP '<allocation unit=.bytes.>\K[0-9]+')
if [[ $reason != *"(shutdown)"* || ${alloc:-0} -lt 500000000 ]]; then
  die "build FAILED: VM state '$reason', disk written $((${alloc:-0} / 1024 / 1024)) MiB.
   QEMU log:  sudo tail -n 50 /var/log/libvirt/qemu/$build.log
   Clean up:  virsh undefine $build --nvram; virsh vol-delete --pool $LAB_POOL_NAME $vol"
fi
vsh undefine "$build" --nvram >/dev/null
log "Golden image ready: $vol ($((alloc / 1024 / 1024)) MiB)"
log "Next: lab vm new agent   and   lab vm new ci --role ci"
