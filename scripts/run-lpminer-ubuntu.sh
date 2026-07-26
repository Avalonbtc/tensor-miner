#!/usr/bin/env bash
# Create and start one lpminer container on Ubuntu.
set -Eeuo pipefail

die() { printf '[lpminer-run] ERROR: %s\n' "$*" >&2; exit 2; }
usage() {
  cat <<'EOF'
Usage:
  run-lpminer-ubuntu.sh --wallet tc1... [--label rig01] [--pool URL] \
    [--image IMAGE:TAG] [--name lpminer] [--shm-gib 6] [--replace] \
    [--cuda-graphs] [--gpu-memory-utilization 0.90] [--devices 0,1]

For four or more GPUs, --shm-gib must be at least 16.

--cuda-graphs is an experimental FP8 optimization. It removes --enforce-eager
and enables vLLM CUDA Graph capture sizes 1,2,4,8,16,32.
EOF
}

wallet=""
label="$(hostname)"
pool="stratum+tls://eu.lproute.com:4160"
image="avalonbtc/lpminer-tensorcash:1.1.1-overlay3"
container_name=lpminer
shm_gib=6
replace=0
cuda_graphs=0
gpu_memory_utilization=""
devices=""
while (($#)); do
  case "$1" in
    --wallet) wallet="${2:-}"; shift 2 ;;
    --label) label="${2:-}"; shift 2 ;;
    --pool) pool="${2:-}"; shift 2 ;;
    --image) image="${2:-}"; shift 2 ;;
    --name) container_name="${2:-}"; shift 2 ;;
    --shm-gib) shm_gib="${2:-}"; shift 2 ;;
    --replace) replace=1; shift ;;
    --cuda-graphs) cuda_graphs=1; shift ;;
    --gpu-memory-utilization) gpu_memory_utilization="${2:-}"; shift 2 ;;
    --devices) devices="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$wallet" =~ ^tc1[0-9a-z]+$ ]] || die "--wallet must be a TensorCash tc1... address"
[[ "$label" =~ ^[[:alnum:]_.-]{1,64}$ ]] || die "label is invalid"
[[ "$pool" =~ ^stratum\+(tcp|tls|ssl)://[^/:[:space:]]+:[0-9]+$ ]] || die "pool is invalid"
[[ "$image" =~ ^[[:alnum:]_./:@-]+$ ]] || die "image reference is invalid"
[[ "$container_name" =~ ^[[:alnum:]_.-]{1,64}$ ]] || die "container name is invalid"
[[ "$shm_gib" =~ ^[1-9][0-9]*$ ]] || die "shm-gib must be a positive integer"
if [[ -n "$gpu_memory_utilization" ]]; then
  [[ "$gpu_memory_utilization" =~ ^0\.[0-9]+$|^1\.0+$ ]] ||
    die "gpu-memory-utilization must be a decimal from 0 to 1"
fi
if [[ -n "$devices" ]]; then
  [[ "$devices" =~ ^[0-9]+(,[0-9]+)*$ ]] ||
    die "devices must be one or more comma-separated GPU indices"
fi

command -v docker >/dev/null 2>&1 || die "Docker is not installed"
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
gpu_count="$(nvidia-smi -L 2>/dev/null | awk '/^GPU / {count++} END {print count + 0}')"
((gpu_count > 0)) || die "no NVIDIA GPU is available"
minimum_shm_gib=4
((gpu_count >= 4)) && minimum_shm_gib=16
((shm_gib >= minimum_shm_gib)) || die "${gpu_count} GPUs require --shm-gib ${minimum_shm_gib} or more"

if docker container inspect "$container_name" >/dev/null 2>&1; then
  ((replace)) || die "container $container_name exists; use docker start $container_name or pass --replace"
  docker rm -f "$container_name" >/dev/null
fi

extra_env=()
if ((cuda_graphs)); then
  extra_env+=(
    --env 'LP_TSC_FP8_ENFORCE_EAGER=0'
    --env 'LP_TSC_CUDA_GRAPH_SIZES=1,2,4,8,16,32'
  )
fi
[[ -z "$gpu_memory_utilization" ]] ||
  extra_env+=(--env "LP_TSC_GPU_MEMORY_UTILIZATION=$gpu_memory_utilization")
[[ -z "$devices" ]] || extra_env+=(--env "CUDA_VISIBLE_DEVICES=$devices")

docker run -d \
  --name "$container_name" \
  --restart unless-stopped \
  --gpus all \
  --shm-size="${shm_gib}g" \
  --mount type=volume,src=lpminer-models,dst=/models \
  --env "WALLET=$wallet" \
  --env "LABEL=$label" \
  --env "POOL=$pool" \
  "${extra_env[@]}" \
  "$image" >/dev/null

sleep 2
docker ps --filter "name=^/${container_name}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
docker logs --tail 20 "$container_name" || true
printf '[lpminer-run] started. Follow logs with: docker logs -f %s\n' "$container_name"
if ((cuda_graphs)); then
  printf '[lpminer-run] CUDA Graph test enabled; compare accepted shares and 5-minute average proof/s before keeping it.\n'
fi
