#!/usr/bin/env bash
# Pre-download a TensorCash model on a no-GPU Ubuntu VPS and create one archive.
set -Eeuo pipefail

die() { printf '[lpminer-prepare] ERROR: %s\n' "$*" >&2; exit 2; }
usage() {
  cat <<'EOF'
Usage:
  prepare-lpminer-bundle-ubuntu.sh --wallet tc1... --output /path/to/bundle.tar.gz \
    [--profile fp8|bf16|all] [--pool URL] [--image IMAGE:TAG] \
    [--download-retries 0]

Use fp8 for 12 GB and 16 GB target GPUs, bf16 for 24 GB target GPUs, and all
only when the bundle must support both types. No GPU is needed on this host.
The final result is one .tar.gz archive. Its .work directory is retained only
after an interrupted run, so the next run continues from the persistent model
cache. Retry value 0 means retry interrupted pulls/downloads indefinitely.
EOF
}

wallet=""
output_archive=""
profile=fp8
pool="stratum+tls://eu.lproute.com:4160"
image="avalonbtc/lpminer-tensorcash:1.1.1-overlay7"
download_retries=0
while (($#)); do
  case "$1" in
    --wallet) wallet="${2:-}"; shift 2 ;;
    --output) output_archive="${2:-}"; shift 2 ;;
    --profile) profile="${2:-}"; shift 2 ;;
    --pool) pool="${2:-}"; shift 2 ;;
    --image) image="${2:-}"; shift 2 ;;
    --download-retries) download_retries="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$wallet" =~ ^tc1[0-9a-z]+$ ]] || die "--wallet must be a TensorCash tc1... address"
[[ -n "$output_archive" ]] || die "--output is required"
[[ "$profile" == fp8 || "$profile" == bf16 || "$profile" == all ]] || die "profile must be fp8, bf16, or all"
[[ "$pool" =~ ^stratum\+(tcp|tls|ssl)://[^/:[:space:]]+:[0-9]+$ ]] || die "pool is invalid"
[[ "$image" =~ ^[[:alnum:]_./:@-]+$ ]] || die "image reference is invalid"
[[ "$download_retries" =~ ^[0-9]+$ ]] && ((10#$download_retries <= 1000)) ||
  die "download-retries must be an integer from 0 to 1000"
command -v docker >/dev/null 2>&1 || die "Docker is not installed"
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"

[[ "$output_archive" == *.tar.gz ]] || output_archive="${output_archive}.tar.gz"
output_parent="$(dirname "$output_archive")"
mkdir -p "$output_parent"
output_parent="$(cd "$output_parent" && pwd)"
output_archive="$output_parent/$(basename "$output_archive")"
work_dir="${output_archive%.tar.gz}.work"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
repo_parent="$(dirname "$repo_dir")"
repo_name="$(basename "$repo_dir")"
[[ "$output_archive" != "$repo_dir/"* && "$work_dir/" != "$repo_dir/"* ]] ||
  die "--output must be outside the tensor-miner checkout"

bundle_files=(image.tar models.tar tensor-miner.tar metadata.env install-lpminer-bundle-ubuntu.sh SHA256SUMS)
if [[ -f "$output_archive" ]]; then
  if archive_contents="$(tar -tzf "$output_archive")"; then
    archive_complete=1
    for file in "${bundle_files[@]}"; do
      grep -Eq "^\./${file}$" <<<"$archive_contents" || archive_complete=0
    done
  else
    archive_complete=0
  fi
  if ((archive_complete)); then
    printf '[lpminer-prepare] complete bundle already exists: %s\n' "$output_archive"
    exit 0
  fi
  die "output archive exists but is incomplete: $output_archive"
fi
if [[ -e "$work_dir" ]]; then
  [[ -d "$work_dir" ]] || die "temporary work path is not a directory: $work_dir"
else
  mkdir -p "$work_dir"
fi
if [[ -n "$(find "$work_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  printf '[lpminer-prepare] resuming incomplete bundle; cached model chunks are retained\n'
fi

run_with_retry() {
  local description="$1" attempt=0 delay
  shift
  while :; do
    attempt=$((attempt + 1))
    printf '[lpminer-prepare] %s (attempt %s)\n' "$description" "$attempt"
    if "$@"; then
      return 0
    fi
    if ((download_retries != 0 && attempt >= download_retries)); then
      die "$description failed after $attempt attempt(s); rerun this command to resume from the cached chunks"
    fi
    if [[ "$description" == pulling\ image* ]] && ((attempt >= 3 && attempt % 3 == 0)); then
      printf '[lpminer-prepare] repeated image-layer EOF: stop this loop and run scripts/configure-docker-pull-ubuntu.sh, then restart option 8\n' >&2
    fi
    delay=$((attempt * 10))
    ((delay > 300)) && delay=300
    printf '[lpminer-prepare] connection failed; preserving completed cache and retrying in %ss (Ctrl-C is safe)\n' "$delay" >&2
    sleep "$delay"
  done
}

if docker image inspect "$image" >/dev/null 2>&1; then
  printf '[lpminer-prepare] image already exists locally; skipping docker pull: %s\n' "$image"
else
  run_with_retry "pulling image $image" docker pull "$image"
fi
docker volume create lpminer-models >/dev/null

download_model() {
  local repository="$1" revision="$2"
  run_with_retry "downloading $repository@$revision" \
    docker run --rm --user root --entrypoint /bin/bash \
    --mount type=volume,src=lpminer-models,dst=/models \
    --env HF_HOME=/models/hf-home \
    --env HF_XET_CACHE=/models/xet \
    --env HF_HUB_ETAG_TIMEOUT=60 \
    --env HF_HUB_DOWNLOAD_TIMEOUT=600 \
    "$image" -lc "hf download '$repository' --revision '$revision' --cache-dir /models/hub"
}

if [[ "$profile" == fp8 || "$profile" == all ]]; then
  download_model Qwen/Qwen3-8B-FP8 220b46e3b2180893580a4454f21f22d3ebb187d3
fi
if [[ "$profile" == bf16 || "$profile" == all ]]; then
  download_model Qwen/Qwen3-8B 9c925d64d72725edaf899c6cb9c377fd0709d9c5
fi

printf '[lpminer-prepare] saving image and model cache\n'
docker image save --output "$work_dir/image.tar" "$image"
docker run --rm --entrypoint /bin/sh \
  --mount type=volume,src=lpminer-models,dst=/models,readonly \
  --mount type=bind,src="$work_dir",dst=/bundle \
  "$image" -c 'tar -C /models -cf /bundle/models.tar .'

printf '[lpminer-prepare] archiving tensor-miner checkout and .git metadata\n'
tar -C "$repo_parent" -cf "$work_dir/tensor-miner.tar" "$repo_name"
cat >"$work_dir/metadata.env" <<EOF
IMAGE=$image
WALLET=$wallet
POOL=$pool
PROFILE=$profile
SOURCE_CONTAINER=preloaded-no-gpu-vps
EOF
install -m 700 "$script_dir/install-lpminer-bundle-ubuntu.sh" \
  "$work_dir/install-lpminer-bundle-ubuntu.sh"
(cd "$work_dir" && sha256sum image.tar models.tar tensor-miner.tar metadata.env install-lpminer-bundle-ubuntu.sh > SHA256SUMS)

work_bytes="$(du -sb "$work_dir" | awk '{print $1}')"
available_bytes="$(df -PB1 "$output_parent" | awk 'NR == 2 {print $4}')"
required_bytes=$((work_bytes + 1073741824))
if ((available_bytes < required_bytes)); then
  additional_gib=$(((required_bytes - available_bytes + 1073741823) / 1073741824))
  die "not enough free space to create the .tar.gz archive; need another ${additional_gib} GiB on $output_parent. The completed temporary bundle remains at $work_dir; free disk space or move it and use an output path on a larger filesystem."
fi

archive_partial="${output_archive}.partial"
rm -f "$archive_partial"
printf '[lpminer-prepare] creating compressed archive\n'
tar -C "$work_dir" -czf "$archive_partial" .
gzip -t "$archive_partial"
mv "$archive_partial" "$output_archive"
rm -rf "$work_dir"
du -sh "$output_archive"
printf '[lpminer-prepare] bundle ready: %s\n' "$output_archive"
