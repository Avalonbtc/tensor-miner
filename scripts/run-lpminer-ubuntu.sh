#!/usr/bin/env bash
# Create and start one lpminer container on Ubuntu.
set -Eeuo pipefail

die() { printf '[lpminer-run] ERROR: %s\n' "$*" >&2; exit 2; }
usage() {
  cat <<'EOF'
Usage:
  run-lpminer-ubuntu.sh --wallet tc1... [--label rig01] [--pool URL] \
    [--image IMAGE:TAG] [--name lpminer] [--shm-gib 6] [--replace] \
    [--cuda-graphs] [--gpu-memory-utilization 0.91] [--devices 0,1] \
    [--proxy-pool URI,...] [--proxy-rotate sequential|random] \
    [--proxy-failure-threshold 1] [--proxy-cooldown-secs 60] \
    [--preserve-runtime-env] [--disable-proxy-failover]

For four or more GPUs, --shm-gib must be at least 16.

--cuda-graphs is an experimental FP8 optimization. It removes --enforce-eager
and enables vLLM CUDA Graph capture sizes 1,2,4,8,16,32. On 12 GB cards,
use 0.91 or higher to retain enough KV cache for a 2048-token context.

--proxy-pool enables optional IP-ban proxy failover. Updating Docker
environment requires recreating the miner container; --preserve-runtime-env
keeps the supported existing tuning and failover variables while doing so.
EOF
}

wallet=""
label="$(hostname)"
pool="stratum+tls://eu.lproute.com:4160"
image="avalonbtc/lpminer-tensorcash:1.1.1-overlay5"
container_name=lpminer
shm_gib=6
replace=0
cuda_graphs=0
gpu_memory_utilization=""
devices=""
proxy_pool=""
proxy_rotate=sequential
proxy_failure_threshold=1
proxy_cooldown_secs=60
preserve_runtime_env=0
disable_proxy_failover=0
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
    --proxy-pool) proxy_pool="${2:-}"; shift 2 ;;
    --proxy-rotate) proxy_rotate="${2:-}"; shift 2 ;;
    --proxy-failure-threshold) proxy_failure_threshold="${2:-}"; shift 2 ;;
    --proxy-cooldown-secs) proxy_cooldown_secs="${2:-}"; shift 2 ;;
    --preserve-runtime-env) preserve_runtime_env=1; shift ;;
    --disable-proxy-failover) disable_proxy_failover=1; shift ;;
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
[[ "$proxy_rotate" == sequential || "$proxy_rotate" == random ]] ||
  die "proxy-rotate must be sequential or random"
[[ "$proxy_failure_threshold" =~ ^[1-9][0-9]*$ ]] &&
  ((10#$proxy_failure_threshold <= 100)) ||
  die "proxy-failure-threshold must be an integer from 1 to 100"
[[ "$proxy_cooldown_secs" =~ ^[1-9][0-9]*$ ]] &&
  ((10#$proxy_cooldown_secs <= 86400)) ||
  die "proxy-cooldown-secs must be an integer from 1 to 86400"
[[ "$proxy_pool" != *$'\n'* && "$proxy_pool" != *$'\r'* ]] ||
  die "proxy-pool must be a single comma-separated line"
[[ -z "$proxy_pool" || "$disable_proxy_failover" == 0 ]] ||
  die "proxy-pool and disable-proxy-failover cannot be used together"

command -v docker >/dev/null 2>&1 || die "Docker is not installed"
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
gpu_count="$(nvidia-smi -L 2>/dev/null | awk '/^GPU / {count++} END {print count + 0}')"
((gpu_count > 0)) || die "no NVIDIA GPU is available"
minimum_shm_gib=4
((gpu_count >= 4)) && minimum_shm_gib=16
((shm_gib >= minimum_shm_gib)) || die "${gpu_count} GPUs require --shm-gib ${minimum_shm_gib} or more"

preserved_env=()
container_env_value() {
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container_name" 2>/dev/null |
    sed -n "s/^${1}=//p" | head -n 1
}
if docker container inspect "$container_name" >/dev/null 2>&1; then
  ((replace)) || die "container $container_name exists; use docker start $container_name or pass --replace"
  if ((preserve_runtime_env)); then
    preserve_keys=(
      CUDA_VISIBLE_DEVICES
      LP_TSC_FP8_ENFORCE_EAGER LP_TSC_CUDA_GRAPH_SIZES
      LP_TSC_GPU_MEMORY_UTILIZATION LP_TSC_BATCH_SIZE
      LP_TSC_INFLIGHT_REQUESTS LP_TSC_MAX_MODEL_LEN LP_TSC_REQUEST_TOKENS
      LP_TSC_STRATUM_FAILOVER LP_TSC_PROXY_POOL LP_TSC_PROXY_ROTATE
      LP_TSC_PROXY_FAILURE_THRESHOLD LP_TSC_PROXY_COOLDOWN_SECS
      LP_TSC_STRATUM_LOCAL_REDIRECT LP_TSC_POOL_REAL_IP
    )
    for key in "${preserve_keys[@]}"; do
      case "$key" in
        CUDA_VISIBLE_DEVICES) [[ -n "$devices" ]] && continue ;;
        LP_TSC_GPU_MEMORY_UTILIZATION) [[ -n "$gpu_memory_utilization" ]] && continue ;;
        LP_TSC_FP8_ENFORCE_EAGER|LP_TSC_CUDA_GRAPH_SIZES) ((cuda_graphs)) && continue ;;
        LP_TSC_STRATUM_FAILOVER|LP_TSC_PROXY_POOL|LP_TSC_PROXY_ROTATE|LP_TSC_PROXY_FAILURE_THRESHOLD|LP_TSC_PROXY_COOLDOWN_SECS)
          [[ -n "$proxy_pool" || "$disable_proxy_failover" == 1 ]] && continue ;;
      esac
      value="$(container_env_value "$key")"
      [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] &&
        preserved_env+=(--env "$key=$value")
    done
  fi
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
if [[ -n "$proxy_pool" ]]; then
  extra_env+=(
    --env 'LP_TSC_STRATUM_FAILOVER=1'
    --env "LP_TSC_PROXY_POOL=$proxy_pool"
    --env "LP_TSC_PROXY_ROTATE=$proxy_rotate"
    --env "LP_TSC_PROXY_FAILURE_THRESHOLD=$proxy_failure_threshold"
    --env "LP_TSC_PROXY_COOLDOWN_SECS=$proxy_cooldown_secs"
  )
elif ((disable_proxy_failover)); then
  extra_env+=(--env 'LP_TSC_STRATUM_FAILOVER=0')
fi

docker run -d \
  --name "$container_name" \
  --restart unless-stopped \
  --gpus all \
  --shm-size="${shm_gib}g" \
  --mount type=volume,src=lpminer-models,dst=/models \
  --env "WALLET=$wallet" \
  --env "LABEL=$label" \
  --env "POOL=$pool" \
  "${preserved_env[@]}" \
  "${extra_env[@]}" \
  "$image" >/dev/null

sleep 2
docker ps --filter "name=^/${container_name}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
docker logs --tail 20 "$container_name" || true
printf '[lpminer-run] started. Follow logs with: docker logs -f %s\n' "$container_name"
if ((cuda_graphs)); then
  printf '[lpminer-run] CUDA Graph test enabled; compare accepted shares and 5-minute average proof/s before keeping it.\n'
fi
