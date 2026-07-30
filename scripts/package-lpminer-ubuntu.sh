#!/usr/bin/env bash
# Create one compressed offline Ubuntu-to-Ubuntu bundle from a working miner.
set -Eeuo pipefail

die() { printf '[lpminer-package] ERROR: %s\n' "$*" >&2; exit 2; }
usage() {
  cat <<'EOF'
Usage:
  package-lpminer-ubuntu.sh [--container lpminer] --output /path/to/bundle.tar.gz

Creates one compressed .tar.gz bundle containing the exact local image, the
/models Docker volume cache, metadata, and the complete tensor-miner checkout
including .git and all helper/menu scripts. If --output lacks .tar.gz, the
suffix is added automatically.
EOF
}

container_name=lpminer
output_archive=""
while (($#)); do
  case "$1" in
    --container) container_name="${2:-}"; shift 2 ;;
    --output) output_archive="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$output_archive" ]] || die "--output is required"
[[ "$container_name" =~ ^[[:alnum:]_.-]{1,64}$ ]] || die "container name is invalid"
[[ "$output_archive" == *.tar.gz ]] || output_archive="${output_archive}.tar.gz"
command -v docker >/dev/null 2>&1 || die "Docker is not installed"
docker container inspect "$container_name" >/dev/null 2>&1 || die "container $container_name does not exist"

output_parent="$(dirname "$output_archive")"
mkdir -p "$output_parent"
output_parent="$(cd "$output_parent" && pwd)"
output_archive="$output_parent/$(basename "$output_archive")"
[[ ! -e "$output_archive" ]] || die "output archive already exists: $output_archive"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
repo_parent="$(dirname "$repo_dir")"
repo_name="$(basename "$repo_dir")"
[[ "$output_archive" != "$repo_dir/"* ]] || die "--output must be outside the tensor-miner checkout"

stage_dir="$(mktemp -d "$output_parent/.lpminer-bundle.XXXXXX")"
archive_partial="${output_archive}.partial"
cleanup() { rm -rf "$stage_dir" "$archive_partial"; }
trap cleanup EXIT

image="$(docker inspect --format '{{.Config.Image}}' "$container_name")"
environment="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container_name")"
wallet="$(printf '%s\n' "$environment" | sed -n 's/^WALLET=//p' | head -n 1)"
pool="$(printf '%s\n' "$environment" | sed -n 's/^POOL=//p' | head -n 1)"
[[ "$wallet" =~ ^tc1[0-9a-z]+$ ]] || die "could not read a tc1 wallet from $container_name"
[[ "$pool" =~ ^stratum\+(tcp|tls|ssl)://[^/:[:space:]]+:[0-9]+$ ]] ||
  die "could not read a valid pool URL from $container_name"

printf '[lpminer-package] saving image %s\n' "$image"
docker image save --output "$stage_dir/image.tar" "$image"

printf '[lpminer-package] archiving lpminer-models volume\n'
docker run --rm \
  --entrypoint /bin/sh \
  --mount type=volume,src=lpminer-models,dst=/models,readonly \
  --mount type=bind,src="$stage_dir",dst=/bundle \
  "$image" -c 'tar -C /models -cf /bundle/models.tar .'

printf '[lpminer-package] archiving tensor-miner checkout and .git metadata\n'
tar -C "$repo_parent" -cf "$stage_dir/tensor-miner.tar" "$repo_name"

cat >"$stage_dir/metadata.env" <<EOF
IMAGE=$image
WALLET=$wallet
POOL=$pool
SOURCE_CONTAINER=$container_name
EOF
install -m 700 "$script_dir/install-lpminer-bundle-ubuntu.sh" \
  "$stage_dir/install-lpminer-bundle-ubuntu.sh"
(cd "$stage_dir" && sha256sum image.tar models.tar tensor-miner.tar metadata.env install-lpminer-bundle-ubuntu.sh > SHA256SUMS)

printf '[lpminer-package] creating compressed archive\n'
tar -C "$stage_dir" -czf "$archive_partial" .
gzip -t "$archive_partial"
mv "$archive_partial" "$output_archive"
du -sh "$output_archive"
printf '[lpminer-package] bundle ready: %s\n' "$output_archive"
trap - EXIT
rm -rf "$stage_dir"
