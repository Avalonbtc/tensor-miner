# Tensor miner Ubuntu scripts

Ubuntu helper scripts for `avalonbtc/nqminer-tensorcash-overlay1:latest`.

The default image is the layer-compatible 1.1.5 overlay. It keeps the official
1.1.5 image as its parent, so machines holding 1.1.1-overlay6 reuse every
shared official layer and download only the official 1.1.5 delta plus the
compiled nqminer patch layers. Its internal labels identify the 1.1.5 upstream
base and the `1.1.5-overlay1` build. The currently published release digest is
`sha256:0f04897f3d99d82b00d64de351a3bd3d3c024c0f8a68b1b8f46387a904f1cf47`.

Every normal or replacement launch now runs `docker pull` before it recreates
the container. This makes the mutable `:latest` tag update reliably while
preserving the local `lpminer-models` cache volume.

Both normal launches and offline-bundle restores explicitly use the image app
directory (`/opt/lpminer/app`). This prevents an empty updater work directory
from hiding the packaged miner binary after an image import.

For the interactive version, run this single command after cloning the repo:

```bash
bash scripts/lpminer-menu-ubuntu.sh
```

The menu covers Docker/NVIDIA runtime setup, image pull, new launch, parameter
replacement, stop/restart/logs, IP-ban proxy configuration, no-GPU preparation,
package, transfer, and bundle installation.

## Prerequisites

Each mining host needs Docker, an NVIDIA driver, and NVIDIA Container Toolkit.
The image uses a persistent Docker volume named `lpminer-models` for model
cache. At least 12 GB of VRAM is required.

## Start one miner

```bash
bash scripts/run-lpminer-ubuntu.sh \
  --wallet tc1yourwallet \
  --label rig-01
```

For four or more GPUs, allocate at least 16 GB shared memory:

```bash
bash scripts/run-lpminer-ubuntu.sh \
  --wallet tc1yourwallet \
  --label rig-8gpu \
  --shm-gib 16
```

## CUDA Graph test for 12 GB FP8 cards

Overlay1 retains the 1.1.5 FP8 profile. The Chinese interactive menu's normal
`N` path therefore starts all available GPUs with the default graph-optimized
profile. Select `y` only to force the graph variables explicitly for a
one-card comparison. The existing `lpminer-models` volume is preserved when
the container is replaced, so the model is not downloaded again.

For a command-line test, use:

```bash
bash scripts/run-lpminer-ubuntu.sh \
  --wallet tc1yourwallet \
  --label graph-test \
  --shm-gib 16 \
  --replace \
  --cuda-graphs \
  --gpu-memory-utilization 0.91 \
  --devices 0
```

After a stable 5-minute comparison of accepted shares and proof/s, replace the
miner again and use `--devices 0,1,2,3,4` for a five-card host. Use
`--enforce-eager` only when a compatibility fallback is required.

Stop and restart an existing miner without re-entering parameters:

```bash
docker stop -t 90 lpminer
docker start lpminer
```

The helper scripts also use a 90-second graceful stop when replacing a
container and set Docker's persistent stop timeout to 90 seconds. This avoids
turning a normal vLLM shutdown into `SIGKILL` / exit code 137.

## Add an IP-ban proxy list to a running miner

Docker cannot change a running container's environment variables. Menu option
`12` therefore recreates `lpminer` from a supplied SOCKS5 proxy text file while keeping
the `lpminer-models` volume and supported runtime tuning variables; models are
not downloaded again. The file is read on the Ubuntu host and is not copied into
the image. Use one proxy per line in this exact format:

```text
203.0.113.10:1080:username:password
203.0.113.11:1080:username:password
```

Blank lines and lines starting with `#` are ignored. Usernames and passwords are
URL-encoded before the SOCKS5 connection is configured. Because `:` is the field
separator, this file format cannot represent a username or password containing
a colon.

The same operation can be run non-interactively:

```bash
bash scripts/run-lpminer-ubuntu.sh \
  --wallet tc1yourwallet \
  --label rig-01 \
  --replace \
  --preserve-runtime-env \
  --proxy-file /home/ubuntu/lpminer-s5.txt
```

Each failed proxy is cooled for 60 seconds by default and the next proxy is
selected. Use `--proxy-failure-threshold` and `--proxy-cooldown-secs` to change
that behavior. Proxy failover also appends a deterministic `-pN` suffix to the
worker label for its following login, so each egress attempt is distinguishable
in pool logs; use `--proxy-worker-rotate 0` to keep the original fixed label.
Run menu option `12` and choose `2` to disable proxy failover.
To change the proxy list later, edit the text file and run option `12` again;
Docker must recreate the container for the new list to take effect. Keep the
file private (for example, `chmod 600 /home/ubuntu/lpminer-s5.txt`) and do not
commit it to Git.

## Offline migration to another Ubuntu machine

Run on the source machine after the miner has downloaded its model:

```bash
bash scripts/transfer-lpminer-ubuntu.sh \
  --target root@target-host \
  --label rig-02
```

In the Chinese menu, option `10` now offers `1` to package the currently
running `lpminer` automatically, or `2` to use a prepared bundle from option
`8` or `9`. A prepared bundle is a directory containing `image.tar`,
`models.tar`, `metadata.env`, `SHA256SUMS`, and the installer; do not enter a
single `.tar` file or an empty download directory.

The target receives the image and `/models` cache, keeps the source wallet and
pool, and starts with its new `LABEL`. The live GPU process is not migrated;
the target starts a new process with the already-copied cache.

Use `--replace` only when it is safe to replace the target's existing
`lpminer` container. It waits up to 90 seconds for a clean shutdown; the model
cache volume is retained unless `--replace-cache` is also supplied during a
bundle restore.

## Prepare on a no-GPU VPS

For a 12 GB or 16 GB target, pre-download the FP8 model without a GPU:

```bash
bash scripts/prepare-lpminer-bundle-ubuntu.sh \
  --wallet tc1yourwallet \
  --profile fp8 \
  --output ~/lpminer-fp8-bundle
```

Use `--profile bf16` for a 24 GB target or `--profile all` for a bundle that
must support both FP8 and BF16 targets. Transfer it in one command while
setting the new worker name:

```bash
bash scripts/transfer-lpminer-ubuntu.sh \
  --bundle ~/lpminer-fp8-bundle \
  --target root@target-host \
  --label rig-02
```

For a four-or-more GPU target, append `--shm-gib 16` to the transfer command.

When `rsync` is installed on both hosts, the transfer uses resumable
`--append-verify` mode. Re-run the exact same command after an interruption;
the stable `/tmp/<bundle-name>` target directory retains partial files. The
SCP fallback cannot resume.
