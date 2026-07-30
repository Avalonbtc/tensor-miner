#!/usr/bin/env bash
# Install an offline lpminer bundle on an Ubuntu target and create the miner.
set -Eeuo pipefail

die() { printf '[lpminer-install] ERROR: %s\n' "$*" >&2; exit 2; }

usage() {
  cat <<'EOF'
Usage:
  install-lpminer-bundle-ubuntu.sh --bundle /path/to/bundle.tar.gz --label new-rig-name \
    [--wallet tc1...] [--pool stratum+tls://eu.lproute.com:4160] \
    [--name lpminer] [--volume lpminer-models] [--shm-gib 6] \
    [--repo-dir ~/tensor-miner] [--replace] [--replace-cache] [--replace-repo]

Without --wallet/--pool, the values captured from the source miner are used.
Docker, NVIDIA driver, and NVIDIA Container Toolkit must already be installed.
The bundled tensor-miner checkout, including .git and all menu/helper scripts,
is restored to --repo-dir. --replace-repo keeps an existing checkout as a
timestamped backup before replacing it.
EOF
}

bundle=""
archive_extract=""
staging_repo=""
label=""
wallet=""
pool=""
container_name=lpminer
volume_name=lpminer-models
shm_gib=6
replace=0
replace_cache=0
repo_dir="$HOME/tensor-miner"
replace_repo=0
stop_timeout_secs=90

cleanup() {
  [[ -z "$staging_repo" ]] || rm -rf "$staging_repo"
  [[ -z "$archive_extract" ]] || rm -rf "$archive_extract"
}
trap cleanup EXIT

stop_and_remove_existing_container() {
  local running
  running="$(docker inspect --format '{{.State.Running}}' "$container_name")"
  if [[ "$running" == true ]]; then
    printf '[lpminer-install] stopping existing %s (up to %ss for a clean vLLM shutdown)\n' \
      "$container_name" "$stop_timeout_secs"
    docker stop --time "$stop_timeout_secs" "$container_name" >/dev/null
  fi
  docker rm "$container_name" >/dev/null
}

while (($#)); do
  case "$1" in
    --bundle) bundle="${2:-}"; shift 2 ;;
    --label) label="${2:-}"; shift 2 ;;
    --wallet) wallet="${2:-}"; shift 2 ;;
    --pool) pool="${2:-}"; shift 2 ;;
    --name) container_name="${2:-}"; shift 2 ;;
    --volume) volume_name="${2:-}"; shift 2 ;;
    --shm-gib) shm_gib="${2:-}"; shift 2 ;;
    --repo-dir) repo_dir="${2:-}"; shift 2 ;;
    --replace) replace=1; shift ;;
    --replace-cache) replace_cache=1; shift ;;
    --replace-repo) replace_repo=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ -f "$bundle" ]]; then
  [[ "$bundle" == *.tar.gz ]] || die "bundle archive must end with .tar.gz"
  if ! tar -tzf "$bundle" | awk '
    /(^|\/)\.\.(\/|$)/ { bad=1; next }
    /^\// { bad=1; next }
    { seen=1 }
    END { exit (seen && !bad) ? 0 : 1 }
  '; then
    die "bundle archive contains unsafe paths"
  fi
  archive_extract="$(mktemp -d)"
  tar -xzf "$bundle" -C "$archive_extract"
  bundle="$archive_extract"
fi
[[ -d "$bundle" ]] || die "bundle directory or .tar.gz archive does not exist: $bundle"
[[ "$label" =~ ^[[:alnum:]_.-]{1,64}$ ]] || die "--label is required and must be safe"
[[ "$container_name" =~ ^[[:alnum:]_.-]{1,64}$ ]] || die "container name is invalid"
[[ "$volume_name" =~ ^[[:alnum:]_.-]{1,64}$ ]] || die "volume name is invalid"
[[ "$shm_gib" =~ ^[0-9]+$ ]] && ((10#$shm_gib >= 4)) || die "shm-gib must be at least 4"
[[ -n "$repo_dir" && "$repo_dir" != / && "$repo_dir" != *$'\n'* && "$repo_dir" != *$'\r'* ]] ||
  die "repo-dir is invalid"
for file in image.tar models.tar tensor-miner.tar metadata.env SHA256SUMS; do
  [[ -f "$bundle/$file" ]] || die "bundle is missing $file"
done

if ! (cd "$bundle" && sha256sum --check --strict SHA256SUMS); then
  printf '%s\n' '[lpminer-install] Bundle integrity check failed; no image or model data was imported.' >&2
  printf '%s\n' '[lpminer-install] Re-transfer the bundle from its source with menu 10, or rerun rsync with --append-verify.' >&2
  exit 2
fi
image="$(sed -n 's/^IMAGE=//p' "$bundle/metadata.env" | head -n 1)"
[[ -n "$wallet" ]] || wallet="$(sed -n 's/^WALLET=//p' "$bundle/metadata.env" | head -n 1)"
[[ -n "$pool" ]] || pool="$(sed -n 's/^POOL=//p' "$bundle/metadata.env" | head -n 1)"
[[ "$image" =~ ^[[:alnum:]_./:@-]+$ ]] || die "bundle image reference is invalid"
[[ "$wallet" =~ ^tc1[0-9a-z]+$ ]] || die "wallet must be a TensorCash tc1... address"
[[ "$pool" =~ ^stratum\+(tcp|tls|ssl)://[^/:[:space:]]+:[0-9]+$ ]] || die "pool must be a raw stratum URL"

if ! tar -tf "$bundle/tensor-miner.tar" | \
  awk 'BEGIN { ok=0; bad=0 }
       /(^|\/)\.\.?(\/|$)/ { bad=1; next }
       /^tensor-miner(\/|$)/ { ok=1; next }
       { bad=1 }
       END { exit (ok && !bad) ? 0 : 1 }'; then
  die "tensor-miner.tar is not a safe complete tensor-miner checkout"
fi

command -v docker >/dev/null 2>&1 || die "Docker is not installed"
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable to this user"
command -v nvidia-smi >/dev/null 2>&1 || die "NVIDIA driver is not installed"
nvidia-smi -L >/dev/null 2>&1 || die "NVIDIA GPU is unavailable"
gpu_count="$(nvidia-smi -L | awk '/^GPU / {count++} END {print count + 0}')"
minimum_shm_gib=4
((gpu_count >= 4)) && minimum_shm_gib=16
((shm_gib >= minimum_shm_gib)) || die "${gpu_count} GPUs require --shm-gib ${minimum_shm_gib} or more"

repo_parent="$(dirname "$repo_dir")"
repo_base="$(basename "$repo_dir")"
[[ "$repo_base" == tensor-miner ]] || die "repo-dir must end with tensor-miner"
mkdir -p "$repo_parent"
if [[ -e "$repo_dir" ]]; then
  ((replace_repo)) || die "repo checkout exists at $repo_dir; pass --replace-repo to back it up and restore the bundled scripts"
  backup_repo="${repo_dir}.before-bundle-$(date +%Y%m%d-%H%M%S)"
  printf '[lpminer-install] backing up existing helper checkout to %s\n' "$backup_repo"
  mv "$repo_dir" "$backup_repo"
fi
staging_repo="$(mktemp -d "$repo_parent/.tensor-miner.bundle.XXXXXX")"
printf '[lpminer-install] restoring tensor-miner scripts to %s\n' "$repo_dir"
tar --no-same-owner -C "$staging_repo" -xf "$bundle/tensor-miner.tar"
[[ -d "$staging_repo/tensor-miner/scripts" && -d "$staging_repo/tensor-miner/.git" ]] ||
  die "restored tensor-miner checkout is incomplete"
mv "$staging_repo/tensor-miner" "$repo_dir"
rm -rf "$staging_repo"
staging_repo=""

if docker container inspect "$container_name" >/dev/null 2>&1; then
  ((replace)) || die "container $container_name exists; use docker start $container_name or pass --replace"
  stop_and_remove_existing_container
fi
if docker volume inspect "$volume_name" >/dev/null 2>&1; then
  ((replace_cache)) || die "volume $volume_name exists; pass --replace-cache only if it is safe to erase"
  docker volume rm "$volume_name" >/dev/null
fi

printf '[lpminer-install] loading image %s\n' "$image"
docker image load --input "$bundle/image.tar" >/dev/null
docker image inspect "$image" >/dev/null 2>&1 || die "loaded archive does not contain $image"
docker volume create "$volume_name" >/dev/null

printf '[lpminer-install] restoring model cache\n'
docker run --rm \
  --entrypoint /bin/sh \
  --mount type=volume,src="$volume_name",dst=/models \
  --mount type=bind,src="$bundle",dst=/bundle,readonly \
  "$image" -c 'tar -C /models -xf /bundle/models.tar'

printf '[lpminer-install] starting %s with LABEL=%s\n' "$container_name" "$label"
docker run -d \
  --name "$container_name" \
  --restart unless-stopped \
  --stop-timeout "$stop_timeout_secs" \
  --gpus all \
  --shm-size="${shm_gib}g" \
  --mount type=volume,src="$volume_name",dst=/models \
  --env "WALLET=$wallet" \
  --env "LABEL=$label" \
  --env "POOL=$pool" \
  "$image" >/dev/null

sleep 2
docker ps --filter "name=^/${container_name}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
docker logs --tail 20 "$container_name" || true
printf '[lpminer-install] started. Follow logs with: docker logs -f %s\n' "$container_name"
printf '[lpminer-install] helper menu restored: bash %s/scripts/lpminer-menu-ubuntu.sh\n' "$repo_dir"
