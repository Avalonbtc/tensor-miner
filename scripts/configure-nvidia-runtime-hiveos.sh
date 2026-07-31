#!/usr/bin/env bash
# Configure NVIDIA Container Toolkit on a HiveOS/Ubuntu host without replacing Docker.
set -Eeuo pipefail

die() { printf '[lpminer-hive-runtime] ERROR: %s\n' "$*" >&2; exit 2; }
image="avalonbtc/lpminer-tensorcash:1.1.1-overlay7"
while (($#)); do
  case "$1" in
    --image) image="${2:-}"; shift 2 ;;
    -h|--help)
      printf 'Usage: configure-nvidia-runtime-hiveos.sh [--image IMAGE:TAG]\n'
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

run_root() {
  if ((EUID == 0)); then "$@"; else sudo "$@"; fi
}

command -v docker >/dev/null 2>&1 || die "Docker is not installed"
command -v nvidia-smi >/dev/null 2>&1 || die "NVIDIA driver is not installed"
nvidia-smi -L >/dev/null 2>&1 || die "NVIDIA driver cannot see a GPU"

if ! command -v nvidia-ctk >/dev/null 2>&1 || ! command -v nvidia-container-runtime >/dev/null 2>&1; then
  command -v apt-get >/dev/null 2>&1 || die "NVIDIA Container Toolkit is missing and apt-get is unavailable"
  command -v curl >/dev/null 2>&1 || run_root apt-get update
  run_root apt-get install -y ca-certificates curl gnupg
  run_root install -m 0755 -d /usr/share/keyrings
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    run_root gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    run_root tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  run_root apt-get update
  run_root apt-get install -y nvidia-container-toolkit
fi

run_root nvidia-ctk runtime configure --runtime=docker
run_root systemctl restart docker
docker info --format '{{json .Runtimes}}' | grep -q '"nvidia"' ||
  die "Docker restarted but the nvidia runtime is still absent"

if docker image inspect "$image" >/dev/null 2>&1; then
  docker run --rm --runtime=nvidia --entrypoint nvidia-smi "$image" -L
else
  printf '[lpminer-hive-runtime] nvidia runtime is configured; local image test skipped because %s is not loaded\n' "$image"
fi
printf '[lpminer-hive-runtime] ready. Recreate lpminer with menu option 4.\n'
