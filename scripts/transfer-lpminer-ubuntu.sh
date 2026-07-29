#!/usr/bin/env bash
# Package a source Ubuntu miner, transfer it by SSH, and start it on Ubuntu.
set -Eeuo pipefail

die() { printf '[lpminer-transfer] ERROR: %s\n' "$*" >&2; exit 2; }
usage() {
  cat <<'EOF'
Usage:
  transfer-lpminer-ubuntu.sh --target user@host --label target-rig-name \
    [--bundle /path/to/prepared-bundle] [--port 22] [--container lpminer] \
    [--output /path/to/bundle] [--remote-dir /tmp/lpminer-bundle] \
    [--shm-gib 6] [--replace]

The target uses the source wallet/pool by default. Use the bundle installer on
the target directly when you need to override WALLET or POOL.
EOF
}

target=""
label=""
port=22
container_name=lpminer
output_dir=""
bundle=""
remote_dir=""
replace=0
shm_gib=6
while (($#)); do
  case "$1" in
    --target) target="${2:-}"; shift 2 ;;
    --label) label="${2:-}"; shift 2 ;;
    --port) port="${2:-}"; shift 2 ;;
    --container) container_name="${2:-}"; shift 2 ;;
    --output) output_dir="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --remote-dir) remote_dir="${2:-}"; shift 2 ;;
    --replace) replace=1; shift ;;
    --shm-gib) shm_gib="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" ]] || die "--target is required"
[[ "$label" =~ ^[[:alnum:]_.-]{1,64}$ ]] || die "--label is required and must be safe"
[[ "$port" =~ ^[0-9]+$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || die "port is invalid"
[[ "$container_name" =~ ^[[:alnum:]_.-]{1,64}$ ]] || die "container name is invalid"
[[ "$shm_gib" =~ ^[0-9]+$ ]] && ((10#$shm_gib >= 4)) || die "shm-gib must be at least 4"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "$bundle" ]]; then
  [[ -d "$bundle" ]] || die "--bundle must be a directory, not a .tar file: $bundle"
  missing=()
  for file in image.tar models.tar tensor-miner.tar metadata.env SHA256SUMS install-lpminer-bundle-ubuntu.sh; do
    [[ -f "$bundle/$file" ]] || missing+=("$file")
  done
  ((${#missing[@]} == 0)) || die "--bundle is incomplete (${missing[*]} missing). Create it first with menu 8 or 9."
  output_dir="$bundle"
else
  if [[ -z "$output_dir" ]]; then
    output_dir="${PWD}/lpminer-bundle-$(date +%Y%m%d-%H%M%S)"
  fi
  bash "$script_dir/package-lpminer-ubuntu.sh" --container "$container_name" --output "$output_dir"
fi
(cd "$output_dir" && sha256sum --check --strict SHA256SUMS) ||
  die "source bundle integrity check failed; rebuild the bundle before transferring it"
if [[ -z "$remote_dir" ]]; then
  remote_dir="/tmp/$(basename "$output_dir")"
fi
[[ "$remote_dir" == /tmp/* && "$remote_dir" != *$'\n'* && "$remote_dir" != *$'\r'* ]] || die "remote-dir must be below /tmp"
ssh -p "$port" "$target" "mkdir -p $(printf '%q' "$remote_dir")"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --checksum --partial --info=progress2 -e "ssh -p $port" "$output_dir/" "$target:$remote_dir/"
else
  printf '[lpminer-transfer] rsync is unavailable; SCP fallback cannot resume interrupted files\n' >&2
  scp -P "$port" -r "$output_dir/." "$target:$remote_dir/"
fi

remote_verify_command="cd $(printf '%q' "$remote_dir") && sha256sum --check --strict SHA256SUMS"
ssh -p "$port" "$target" "$remote_verify_command" ||
  die "target bundle integrity check failed; rerun the transfer to repair it"

remote_command="bash $(printf '%q' "$remote_dir/install-lpminer-bundle-ubuntu.sh") --bundle $(printf '%q' "$remote_dir") --label $(printf '%q' "$label") --shm-gib $(printf '%q' "$shm_gib") --replace-repo"
if ((replace)); then remote_command+=" --replace --replace-cache"; fi
ssh -p "$port" "$target" "$remote_command"
printf '[lpminer-transfer] complete. Local bundle kept at: %s\n' "$output_dir"
