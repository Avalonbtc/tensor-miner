#!/usr/bin/env bash
# Interactive front-end for all Ubuntu lpminer tasks.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image_default="avalonbtc/lpminer-tensorcash:1.1.1-overlay3"
pool_default="stratum+tls://eu.lproute.com:4160"

pause() { read -rp 'Press Enter to continue... ' _; }
ask() {
  local prompt="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " value
    printf '%s' "${value:-$default}"
  else
    read -rp "$prompt: " value
    printf '%s' "$value"
  fi
}
container_env() {
  local key="$1"
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' lpminer 2>/dev/null |
    sed -n "s/^${key}=//p" | head -n 1
}
gpu_default_shm() {
  local count=0
  if command -v nvidia-smi >/dev/null 2>&1; then
    count="$(nvidia-smi -L 2>/dev/null | awk '/^GPU / {n++} END {print n + 0}')"
  fi
  ((count >= 4)) && printf '16' || printf '6'
}
start_miner() {
  local replace="$1" wallet label pool image shm old_label old_pool args=()
  old_label="$(container_env LABEL || true)"
  old_pool="$(container_env POOL || true)"
  wallet="$(ask 'Wallet (tc1...)' "$(container_env WALLET)")"
  label="$(ask 'Miner label' "${old_label:-$(hostname)}")"
  pool="$(ask 'Pool URL' "${old_pool:-$pool_default}")"
  image="$(ask 'Image' "$image_default")"
  shm="$(ask 'Shared memory GiB' "$(gpu_default_shm)")"
  [[ "$replace" == 1 ]] && args+=(--replace)
  bash "$script_dir/run-lpminer-ubuntu.sh" \
    --wallet "$wallet" --label "$label" --pool "$pool" --image "$image" --shm-gib "$shm" "${args[@]}"
}
prepare_bundle() {
  local wallet profile output
  wallet="$(ask 'Wallet (tc1...)')"
  profile="$(ask 'Target profile: fp8, bf16, or all' fp8)"
  output="$(ask 'Bundle output directory' "$HOME/lpminer-${profile}-bundle")"
  bash "$script_dir/prepare-lpminer-bundle-ubuntu.sh" --wallet "$wallet" --profile "$profile" --output "$output"
}
transfer_bundle() {
  local bundle target label shm
  bundle="$(ask 'Prepared bundle directory' "$HOME/lpminer-fp8-bundle")"
  target="$(ask 'Target SSH user@host')"
  label="$(ask 'Target miner label' "$(hostname)-copy")"
  shm="$(ask 'Target shared memory GiB' 6)"
  bash "$script_dir/transfer-lpminer-ubuntu.sh" --bundle "$bundle" --target "$target" --label "$label" --shm-gib "$shm"
}
install_bundle() {
  local bundle label shm
  bundle="$(ask 'Local bundle directory' /tmp/lpminer-bundle)"
  label="$(ask 'Miner label' "$(hostname)")"
  shm="$(ask 'Shared memory GiB' "$(gpu_default_shm)")"
  bash "$script_dir/install-lpminer-bundle-ubuntu.sh" --bundle "$bundle" --label "$label" --shm-gib "$shm"
}

while true; do
  clear 2>/dev/null || true
  cat <<'EOF'
=== Tensor miner Ubuntu menu ===
1) Install Docker + NVIDIA Container Toolkit
2) Pull miner image
3) Start new miner
4) Replace miner wallet / label / pool parameters
5) Stop miner
6) Restart miner
7) Follow miner logs
8) Pre-download image + model on a no-GPU VPS
9) Package the current working miner
10) Transfer a prepared bundle to another Ubuntu server
11) Install a bundle on this GPU server
0) Exit
EOF
  read -rp 'Select: ' selection
  case "$selection" in
    1) bash "$script_dir/install-docker-nvidia-ubuntu.sh" ;;
    2) docker pull "$(ask 'Image' "$image_default")" ;;
    3) start_miner 0 ;;
    4) start_miner 1 ;;
    5) docker stop lpminer ;;
    6) docker restart lpminer ;;
    7) docker logs -f lpminer ;;
    8) prepare_bundle ;;
    9) bash "$script_dir/package-lpminer-ubuntu.sh" --output "$(ask 'Bundle output directory' "$HOME/lpminer-bundle")" ;;
    10) transfer_bundle ;;
    11) install_bundle ;;
    0) exit 0 ;;
    *) printf 'Invalid selection.\n' ;;
  esac
  pause
done
