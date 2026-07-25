# Tensor miner Ubuntu scripts

Ubuntu helper scripts for `avalonbtc/lpminer-tensorcash:1.1.1-overlay3`.

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

Stop and restart an existing miner without re-entering parameters:

```bash
docker stop lpminer
docker start lpminer
```

## Offline migration to another Ubuntu machine

Run on the source machine after the miner has downloaded its model:

```bash
bash scripts/transfer-lpminer-ubuntu.sh \
  --target root@target-host \
  --label rig-02
```

The target receives the image and `/models` cache, keeps the source wallet and
pool, and starts with its new `LABEL`. The live GPU process is not migrated;
the target starts a new process with the already-copied cache.

Use `--replace` only when it is safe to remove the target's existing `lpminer`
container and model-cache volume.
