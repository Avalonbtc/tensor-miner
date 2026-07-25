#!/usr/bin/env bash
# Package a source Ubuntu miner, transfer it by SSH, and start it on Ubuntu.
set -Eeuo pipefail

die() { printf '[lpminer-transfer] ERROR: %s\n' "$*" >&2; exit 2; }
usage() {
  cat <<'EOF'
Usage:
  transfer-lpminer-ubuntu.sh --target user@host --label target-rig-name \
    [--bundle /path/to/prepared-bundle] [--port 22] [--container lpminer] \
    [--output /path/to/bundle] [--replace]

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
replace=0
while (($#)); do
  case "$1" in
    --target) target="${2:-}"; shift 2 ;;
    --label) label="${2:-}"; shift 2 ;;
    --port) port="${2:-}"; shift 2 ;;
    --container) container_name="${2:-}"; shift 2 ;;
    --output) output_dir="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --replace) replace=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$target" ]] || die "--target is required"
[[ "$label" =~ ^[[:alnum:]_.-]{1,64}$ ]] || die "--label is required and must be safe"
[[ "$port" =~ ^[0-9]+$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || die "port is invalid"
[[ "$container_name" =~ ^[[:alnum:]_.-]{1,64}$ ]] || die "container name is invalid"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "$bundle" ]]; then
  [[ -d "$bundle" && -f "$bundle/SHA256SUMS" ]] || die "--bundle must be a prepared bundle directory"
  output_dir="$bundle"
else
  if [[ -z "$output_dir" ]]; then
    output_dir="${PWD}/lpminer-bundle-$(date +%Y%m%d-%H%M%S)"
  fi
  bash "$script_dir/package-lpminer-ubuntu.sh" --container "$container_name" --output "$output_dir"
fi
remote_dir="/tmp/lpminer-bundle-$(date +%Y%m%d-%H%M%S)"
ssh -p "$port" "$target" "mkdir -p $(printf '%q' "$remote_dir")"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --partial --info=progress2 -e "ssh -p $port" "$output_dir/" "$target:$remote_dir/"
else
  scp -P "$port" -r "$output_dir/." "$target:$remote_dir/"
fi

remote_command="bash $(printf '%q' "$remote_dir/install-lpminer-bundle-ubuntu.sh") --bundle $(printf '%q' "$remote_dir") --label $(printf '%q' "$label")"
if ((replace)); then remote_command+=" --replace --replace-cache"; fi
ssh -p "$port" "$target" "$remote_command"
printf '[lpminer-transfer] complete. Local bundle kept at: %s\n' "$output_dir"
