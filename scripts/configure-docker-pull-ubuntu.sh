#!/usr/bin/env bash
# Make Docker Hub image pulls reliable on unstable or low-bandwidth links.
set -Eeuo pipefail

die() { printf '[docker-pull-config] ERROR: %s\n' "$*" >&2; exit 2; }
usage() {
  cat <<'EOF'
Usage:
  configure-docker-pull-ubuntu.sh [--concurrent 1] [--attempts 100]

Updates /etc/docker/daemon.json without removing existing Docker settings,
backs it up, and reloads Docker. Use concurrent=1 for large image layers on an
unstable connection.
EOF
}

concurrent=1
attempts=100
while (($#)); do
  case "$1" in
    --concurrent) concurrent="${2:-}"; shift 2 ;;
    --attempts) attempts="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$concurrent" =~ ^[1-9][0-9]*$ ]] && ((10#$concurrent <= 10)) ||
  die "concurrent must be an integer from 1 to 10"
[[ "$attempts" =~ ^[1-9][0-9]*$ ]] && ((10#$attempts <= 1000)) ||
  die "attempts must be an integer from 1 to 1000"
command -v docker >/dev/null 2>&1 || die "Docker is not installed"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

run_root() {
  if ((EUID == 0)); then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || die "sudo is required"
    sudo "$@"
  fi
}

config=/etc/docker/daemon.json
if [[ -f "$config" ]]; then
  backup="${config}.before-pull-tuning-$(date +%Y%m%d-%H%M%S)"
  run_root cp -a "$config" "$backup"
  printf '[docker-pull-config] backup: %s\n' "$backup"
fi

run_root python3 - "$config" "$concurrent" "$attempts" <<'PY'
import json
import os
import sys
import tempfile

path, concurrent, attempts = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = {}
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
if not isinstance(data, dict):
    raise SystemExit("daemon.json must contain a JSON object")
data["max-concurrent-downloads"] = concurrent
data["max-download-attempts"] = attempts
directory = os.path.dirname(path)
fd, temporary = tempfile.mkstemp(prefix=".daemon.json.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.chmod(temporary, 0o644)
    os.replace(temporary, path)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY

if command -v systemctl >/dev/null 2>&1; then
  run_root systemctl reload docker || run_root systemctl restart docker
else
  die "systemctl is required to reload Docker"
fi
docker info >/dev/null
printf '[docker-pull-config] enabled: max-concurrent-downloads=%s, max-download-attempts=%s\n' \
  "$concurrent" "$attempts"
