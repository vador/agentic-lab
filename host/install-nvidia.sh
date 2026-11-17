#!/usr/bin/env bash
# OPTIONAL: replace nouveau with the proprietary NVIDIA driver + NVIDIA Container Toolkit,
# so Ollama can use the RTX 4070 Super from Docker (`lab services up --gpu`).
# This changes your host's graphics driver and needs a reboot.
source "$(dirname "$0")/../lib/common.sh"
[[ $EUID -ne 0 ]] || die "run as your normal user"

cat <<'EOF'
This will:
  1. enable the contrib/non-free/non-free-firmware APT components
  2. install nvidia-driver (DKMS) + firmware + kernel headers
  3. install nvidia-container-toolkit and configure Docker for it
If Secure Boot is enabled you will be asked to enroll a MOK key at next boot.
EOF
command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null || true
confirm "Continue?" || exit 1

log "Enabling non-free components"
if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
  sudo sed -i -E 's/^Components:.*/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources
fi
if [[ -f /etc/apt/sources.list ]]; then
  sudo sed -i -E \
    -e '/^deb(-src)? .*debian/ { / contrib( |$)/! s/ main( |$)/ main contrib\1/ }' \
    -e '/^deb(-src)? .*debian/ { / non-free( |$)/! s/ contrib( |$)/ contrib non-free\1/ }' \
    -e '/^deb(-src)? .*debian/ { / non-free-firmware/! s/$/ non-free-firmware/ }' \
    /etc/apt/sources.list
fi
sudo apt-get update
sudo apt-get install -y linux-headers-amd64 nvidia-kernel-dkms nvidia-driver firmware-misc-nonfree

log "Installing NVIDIA Container Toolkit"
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

log "Done. Reboot, check with 'nvidia-smi', then: lab services up --gpu"
