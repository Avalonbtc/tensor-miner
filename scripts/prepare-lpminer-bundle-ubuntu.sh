#!/usr/bin/env bash
# Pre-download a TensorCash model on a non-GPU Ubuntu VPS and create a bundle.
set -Eeuo pipefail

die() { printf '[lpminer-prepare] ERROR: %s\n' "$*" >&2; exit 2; }
usage() {
  cat <<'EOF'
Usage:
  prepare-lpminer-bundle-ubuntu.sh --wallet tc1... --output /path/to/bundle \
    [--profile fp8|bf16|all] [--pool URL] [--image IMAGE:TAG]

Use fp8 for 12 GB and 16 GB target GPUs, bf16 for 24 GB target GPUs, and all
only when the bundle must support both types. No GPU is needed on this host.
EOF
}

wallet=""
output_dir=""
profile=fp8
pool="stratum+tls://eu.lproute.com:4160"
image="avalonbtc/lpminer-tensorcash:1.1.1-overlay4"
while (($#)); do
  case "$1" in
    --wallet) wallet="${2:-}"; shift 2 ;;
    --output) output_dir="${2:-}"; shift 2 ;;
    --profile) profile="${2:-}"; shift 2 ;;
    --pool) pool="${2:-}"; shift 2 ;;
    --image) image="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$wallet" =~ ^tc1[0-9a-z]+$ ]] || die "--wallet must be a TensorCash tc1... address"
[[ -n "$output_dir" ]] || die "--output is required"
[[ "$profile" == fp8 || "$profile" == bf16 || "$profile" == all ]] || die "profile must be fp8, bf16, or all"
[[ "$pool" =~ ^stratum\+(tcp|tls|ssl)://[^/:[:space:]]+:[0-9]+$ ]] || die "pool is invalid"
[[ "$image" =~ ^[[:alnum:]_./:@-]+$ ]] || die "image reference is invalid"
command -v docker >/dev/null 2>&1 || die "Docker is not installed"
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"

output_parent="$(dirname "$output_dir")"
mkdir -p "$output_parent"
output_dir="$(cd "$output_parent" && pwd)/$(basename "$output_dir")"
if [[ -e "$output_dir" ]]; then
  [[ -d "$output_dir" ]] || die "output exists but is not a directory: $output_dir"
  [[ -z "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die "output directory must be empty"
else
  mkdir -p "$output_dir"
fi

docker pull "$image"
docker volume create lpminer-models >/dev/null

download_model() {
  local repository="$1" revision="$2"
  printf '[lpminer-prepare] downloading %s@%s\n' "$repository" "$revision"
  docker run --rm --user root --entrypoint /bin/bash \
    --mount type=volume,src=lpminer-models,dst=/models \
    "$image" -lc "hf download '$repository' --revision '$revision' --cache-dir /models/hub"
}

if [[ "$profile" == fp8 || "$profile" == all ]]; then
  download_model Qwen/Qwen3-8B-FP8 220b46e3b2180893580a4454f21f22d3ebb187d3
fi
if [[ "$profile" == bf16 || "$profile" == all ]]; then
  download_model Qwen/Qwen3-8B 9c925d64d72725edaf899c6cb9c377fd0709d9c5
fi

printf '[lpminer-prepare] saving image and model cache\n'
docker image save --output "$output_dir/image.tar" "$image"
docker run --rm --entrypoint /bin/sh \
  --mount type=volume,src=lpminer-models,dst=/models,readonly \
  --mount type=bind,src="$output_dir",dst=/bundle \
  "$image" -c 'tar -C /models -cf /bundle/models.tar .'

cat >"$output_dir/metadata.env" <<EOF
IMAGE=$image
WALLET=$wallet
POOL=$pool
PROFILE=$profile
SOURCE_CONTAINER=preloaded-no-gpu-vps
EOF
install -m 700 "$(dirname "$0")/install-lpminer-bundle-ubuntu.sh" \
  "$output_dir/install-lpminer-bundle-ubuntu.sh"
(cd "$output_dir" && sha256sum image.tar models.tar metadata.env install-lpminer-bundle-ubuntu.sh > SHA256SUMS)
du -sh "$output_dir"
printf '[lpminer-prepare] bundle ready: %s\n' "$output_dir"
