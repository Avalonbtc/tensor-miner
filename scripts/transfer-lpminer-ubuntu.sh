#!/usr/bin/env bash
# Package a source Ubuntu miner, transfer one compressed archive, and install it.
set -Eeuo pipefail

die() { printf '[lpminer-transfer] ERROR: %s\n' "$*" >&2; exit 2; }
usage() {
  cat <<'EOF'
Usage:
  transfer-lpminer-ubuntu.sh --target user@host --label target-rig-name \
    [--bundle /path/to/bundle.tar.gz] [--port 22] [--container lpminer] \
    [--output /path/to/bundle.tar.gz] [--remote-dir /tmp/lpminer-bundle] \
    [--shm-gib 6] [--replace]

The target uses the source wallet/pool by default. rsync transfers the single
archive with --append-verify, so an interrupted archive upload resumes.
EOF
}

target=""
label=""
port=22
container_name=lpminer
output_archive=""
bundle=""
remote_dir=""
replace=0
shm_gib=6
temporary_archive=""
while (($#)); do
  case "$1" in
    --target) target="${2:-}"; shift 2 ;;
    --label) label="${2:-}"; shift 2 ;;
    --port) port="${2:-}"; shift 2 ;;
    --container) container_name="${2:-}"; shift 2 ;;
    --output) output_archive="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --remote-dir) remote_dir="${2:-}"; shift 2 ;;
    --replace) replace=1; shift ;;
    --shm-gib) shm_gib="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

cleanup() { [[ -z "$temporary_archive" ]] || rm -f "$temporary_archive"; }
trap cleanup EXIT
[[ -n "$target" ]] || die "--target is required"
[[ "$label" =~ ^[[:alnum:]_.-]{1,64}$ ]] || die "--label is required and must be safe"
[[ "$port" =~ ^[0-9]+$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || die "port is invalid"
[[ "$container_name" =~ ^[[:alnum:]_.-]{1,64}$ ]] || die "container name is invalid"
[[ "$shm_gib" =~ ^[0-9]+$ ]] && ((10#$shm_gib >= 4)) || die "shm-gib must be at least 4"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "$bundle" ]]; then
  if [[ -f "$bundle" ]]; then
    [[ "$bundle" == *.tar.gz ]] || die "--bundle archive must end with .tar.gz"
    archive="$bundle"
  elif [[ -d "$bundle" ]]; then
    temporary_archive="$(mktemp "${TMPDIR:-/tmp}/lpminer-bundle.XXXXXX")"
    mv "$temporary_archive" "${temporary_archive}.tar.gz"
    temporary_archive="${temporary_archive}.tar.gz"
    tar -C "$bundle" -czf "$temporary_archive" .
    archive="$temporary_archive"
  else
    die "--bundle must be a .tar.gz archive or an existing legacy bundle directory"
  fi
else
  [[ -n "$output_archive" ]] || output_archive="${PWD}/lpminer-bundle-$(date +%Y%m%d-%H%M%S).tar.gz"
  bash "$script_dir/package-lpminer-ubuntu.sh" --container "$container_name" --output "$output_archive"
  [[ "$output_archive" == *.tar.gz ]] || output_archive="${output_archive}.tar.gz"
  archive="$output_archive"
fi

gzip -t "$archive" >/dev/null || die "bundle archive is incomplete: $archive"
if [[ -z "$remote_dir" ]]; then
  remote_dir="/tmp/lpminer-bundle-$(date +%Y%m%d-%H%M%S)"
fi
[[ "$remote_dir" == /tmp/* && "$remote_dir" != *$'\n'* && "$remote_dir" != *$'\r'* ]] || die "remote-dir must be below /tmp"
remote_archive="$remote_dir/bundle.tar.gz"
remote_installer="$remote_dir/install-lpminer-bundle-ubuntu.sh"
ssh -p "$port" "$target" "mkdir -p $(printf '%q' "$remote_dir")"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --append-verify --partial --info=progress2 -e "ssh -p $port" "$archive" "$target:$remote_archive"
  rsync -a --checksum -e "ssh -p $port" "$script_dir/install-lpminer-bundle-ubuntu.sh" "$target:$remote_installer"
else
  printf '[lpminer-transfer] rsync is unavailable; SCP fallback cannot resume interrupted archives\n' >&2
  scp -P "$port" "$archive" "$target:$remote_archive"
  scp -P "$port" "$script_dir/install-lpminer-bundle-ubuntu.sh" "$target:$remote_installer"
fi

remote_command="bash $(printf '%q' "$remote_installer") --bundle $(printf '%q' "$remote_archive") --label $(printf '%q' "$label") --shm-gib $(printf '%q' "$shm_gib") --replace-repo"
if ((replace)); then remote_command+=" --replace --replace-cache"; fi
ssh -p "$port" "$target" "$remote_command"
printf '[lpminer-transfer] complete. Local archive kept at: %s\n' "$archive"
