#!/usr/bin/env bash
# Install Docker Engine and configure NVIDIA Container Toolkit on Ubuntu.
set -Eeuo pipefail

die() { printf '[lpminer-prereqs] ERROR: %s\n' "$*" >&2; exit 2; }
[[ -r /etc/os-release ]] || die "this script requires Ubuntu"
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die "this script supports Ubuntu only"
command -v sudo >/dev/null 2>&1 || die "sudo is required"
sudo -v

if ! command -v docker >/dev/null 2>&1; then
  printf '[lpminer-prereqs] installing Docker Engine from Docker official apt repository\n'
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"

if ! command -v nvidia-ctk >/dev/null 2>&1; then
  printf '[lpminer-prereqs] installing NVIDIA Container Toolkit\n'
  sudo install -m 0755 -d /usr/share/keyrings
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y nvidia-container-toolkit
fi

sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi -L || die "NVIDIA driver is installed but no GPU is available"
else
  printf '[lpminer-prereqs] Docker is ready. Install an NVIDIA driver before GPU mining.\n' >&2
fi
printf '[lpminer-prereqs] complete. Log out and back in before using Docker without sudo.\n'
