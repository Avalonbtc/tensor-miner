#!/usr/bin/env bash
# Create an offline Ubuntu-to-Ubuntu bundle from an already working miner.
set -Eeuo pipefail

die() { printf '[lpminer-package] ERROR: %s\n' "$*" >&2; exit 2; }

usage() {
  cat <<'EOF'
Usage:
  package-lpminer-ubuntu.sh [--container lpminer] --output /path/to/bundle

The bundle contains the exact local image, the /models Docker volume cache,
the running container's WALLET/POOL metadata, and a complete tensor-miner
checkout (including .git and every helper/menu script). It does not and cannot
copy the live GPU/vLLM process; the receiving machine starts a new process
using the copied model cache.
EOF
}

container_name=lpminer
output_dir=""
while (($#)); do
  case "$1" in
    --container) container_name="${2:-}"; shift 2 ;;
    --output) output_dir="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$output_dir" ]] || die "--output is required"
[[ "$container_name" =~ ^[[:alnum:]_.-]{1,64}$ ]] || die "container name is invalid"
command -v docker >/dev/null 2>&1 || die "Docker is not installed"
docker container inspect "$container_name" >/dev/null 2>&1 || die "container $container_name does not exist"

output_parent="$(dirname "$output_dir")"
mkdir -p "$output_parent"
output_dir="$(cd "$output_parent" && pwd)/$(basename "$output_dir")"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
repo_parent="$(dirname "$repo_dir")"
repo_name="$(basename "$repo_dir")"
[[ "$output_dir/" != "$repo_dir/"* ]] ||
  die "--output must be outside the tensor-miner checkout"

if [[ -e "$output_dir" ]]; then
  [[ -d "$output_dir" ]] || die "output exists but is not a directory: $output_dir"
  [[ -z "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
    die "output directory must be empty: $output_dir"
else
  mkdir -p "$output_dir"
fi

image="$(docker inspect --format '{{.Config.Image}}' "$container_name")"
environment="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container_name")"
wallet="$(printf '%s\n' "$environment" | sed -n 's/^WALLET=//p' | head -n 1)"
pool="$(printf '%s\n' "$environment" | sed -n 's/^POOL=//p' | head -n 1)"
[[ "$wallet" =~ ^tc1[0-9a-z]+$ ]] || die "could not read a tc1 wallet from $container_name"
[[ "$pool" =~ ^stratum\+(tcp|tls|ssl)://[^/:[:space:]]+:[0-9]+$ ]] ||
  die "could not read a valid pool URL from $container_name"

printf '[lpminer-package] saving image %s\n' "$image"
docker image save --output "$output_dir/image.tar" "$image"

printf '[lpminer-package] archiving lpminer-models volume\n'
docker run --rm \
  --entrypoint /bin/sh \
  --mount type=volume,src=lpminer-models,dst=/models,readonly \
  --mount type=bind,src="$output_dir",dst=/bundle \
  "$image" -c 'tar -C /models -cf /bundle/models.tar .'

printf '[lpminer-package] archiving tensor-miner checkout and .git metadata\n'
tar -C "$repo_parent" -cf "$output_dir/tensor-miner.tar" "$repo_name"

cat >"$output_dir/metadata.env" <<EOF
IMAGE=$image
WALLET=$wallet
POOL=$pool
SOURCE_CONTAINER=$container_name
EOF
install -m 700 "$(dirname "$0")/install-lpminer-bundle-ubuntu.sh" \
  "$output_dir/install-lpminer-bundle-ubuntu.sh"
(cd "$output_dir" && sha256sum image.tar models.tar tensor-miner.tar metadata.env install-lpminer-bundle-ubuntu.sh > SHA256SUMS)

du -sh "$output_dir"
printf '[lpminer-package] bundle ready: %s\n' "$output_dir"
