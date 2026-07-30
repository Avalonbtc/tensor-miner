# Tensor miner Ubuntu scripts

Ubuntu helper scripts for `avalonbtc/lpminer-tensorcash:1.1.1-overlay6`.

The default image is the validated `1.1.1-overlay6` release. It is used by all
normal launches, offline preparation bundles, and the interactive menu unless
an explicit `--image` value is supplied.

Every normal or replacement launch runs `docker pull` before it recreates the
container while preserving the local `lpminer-models` cache volume.

The image retains its application layout after an offline bundle restore.

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

Every bundle is one compressed `.tar.gz` archive. Inside it, `tensor-miner.tar`
contains the complete checkout with `.git`, every helper script, and the
Chinese menu. Transfer restores it to `~/tensor-miner` on the target and backs
up an older target checkout with a timestamp before replacement.

Creating the final archive temporarily needs one additional copy of the staged
`image.tar` and `models.tar`. Keep at least the displayed work-directory size
plus 1 GiB free on the filesystem selected for the output archive. The scripts
now stop before compression with the exact extra capacity required.
If the source host has no spare space for that extra copy, option `10` also
accepts the retained `.work` directory and transfers its files directly with
resumable rsync; the target installer accepts that legacy directory layout.

Menu option `8` is resumable. Hugging Face and Xet cache data is kept in the
persistent `lpminer-models` volume; a broken connection retries automatically
and a later rerun continues from the cached chunks. Pressing `Ctrl-C` is safe.
Use `--download-retries N` only when a finite retry limit is wanted; `0` is the
default and retries indefinitely.
If the requested image tag has already been pulled manually, option `8` detects
it with `docker image inspect`, skips the image pull, and starts the model
download immediately.

For repeated `short read ... unexpected EOF` errors while pulling the large
Docker image layer, select menu option `13` once, then rerun option `8`. It
sets Docker to one concurrent layer download and raises its per-pull retry
limit without replacing existing daemon settings.

## Upload a completed bundle to Quark Drive

Menu option `14` uploads an existing `.tar.gz` archive. Options `8` and `9`
also ask whether to upload immediately after a successful bundle is created.
Paste the Quark browser cookie only when the menu asks for it; the terminal
input is hidden and the cookie is piped to the uploader rather than saved to a
file or passed on the command line. Option `14` also accepts an unfinished
`.work` folder when a source VPS lacks enough space to build its `.tar.gz`.

The uploader uses the selected Quark parent directory ID (`0` means root),
streams each multipart upload from disk, and records completed part ETags in
`<bundle>.quark-upload-state.json`. Directory uploads retain a separate
`<folder>.quark-folder-state.json` beside the source folder. Re-run option
`14` after a network break to resume unfinished parts. State files are ignored
by Git.

For non-interactive use:

```bash
read -rsp 'Quark Cookie: ' cookie; printf '\n'
printf '%s' "$cookie" | python3 scripts/upload-quark-bundle.py \
  --file ~/lpminer-bf16-bundle.tar.gz \
  --cookie-stdin --parent-id 0
unset cookie
```

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

Overlay6 retains the validated FP8 profile. The Chinese interactive menu's normal
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
running `lpminer` automatically, or `2` to use a prepared `.tar.gz` bundle
from option `8` or `9`. Its contents are `image.tar`, `models.tar`,
`tensor-miner.tar`, `metadata.env`, `SHA256SUMS`, and the installer.

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
  --output ~/lpminer-fp8-bundle.tar.gz
```

Use `--profile bf16` for a 24 GB target or `--profile all` for a bundle that
must support both FP8 and BF16 targets. Transfer it in one command while
setting the new worker name:

```bash
bash scripts/transfer-lpminer-ubuntu.sh \
  --bundle ~/lpminer-fp8-bundle.tar.gz \
  --target root@target-host \
  --label rig-02
```

For a four-or-more GPU target, append `--shm-gib 16` to the transfer command.

When `rsync` is installed on both hosts, the transfer uses resumable
`--append-verify` mode. Re-run the exact same command after an interruption;
the target's partial archive is retained. The SCP fallback cannot resume.
