#!/usr/bin/env bash
# Interactive front-end for all Ubuntu lpminer tasks.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image_default="avalonbtc/lpminer-tensorcash:1.1.1-overlay3"
pool_default="stratum+tls://eu.lproute.com:4160"

pause() { read -rp '按 Enter 继续... ' _; }
ask() {
  local prompt="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " value
    printf '%s' "${value:-$default}"
  else
    read -rp "$prompt: " value
    printf '%s' "$value"
  fi
}
container_env() {
  local key="$1"
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' lpminer 2>/dev/null |
    sed -n "s/^${key}=//p" | head -n 1
}
gpu_default_shm() {
  local count=0
  if command -v nvidia-smi >/dev/null 2>&1; then
    count="$(nvidia-smi -L 2>/dev/null | awk '/^GPU / {n++} END {print n + 0}')"
  fi
  ((count >= 4)) && printf '16' || printf '6'
}
start_miner() {
  local replace="$1" wallet label pool image shm old_label old_pool graph_mode graph_mem graph_devices args=()
  old_label="$(container_env LABEL || true)"
  old_pool="$(container_env POOL || true)"
  wallet="$(ask '钱包地址 (tc1...)' "$(container_env WALLET)")"
  label="$(ask '矿工名' "${old_label:-$(hostname)}")"
  pool="$(ask '矿池地址' "${old_pool:-$pool_default}")"
  image="$(ask '镜像' "$image_default")"
  shm="$(ask '共享内存 GiB' "$(gpu_default_shm)")"
  graph_mode="$(ask '启用 CUDA Graph 图优化测试？(y/N)' N)"
  case "$graph_mode" in
    y|Y|yes|YES)
      graph_mem="$(ask '图模式显存比例（12G 推荐 0.91）' 0.91)"
      graph_devices="$(ask '测试 GPU（0=仅第1张，all=全部）' 0)"
      args+=(--cuda-graphs --gpu-memory-utilization "$graph_mem")
      if [[ "$graph_devices" != all ]]; then
        args+=(--devices "$graph_devices")
      fi
      ;;
    n|N|no|NO|'') ;;
    *)
      printf '无效选择，已保持稳定模式。\n'
      ;;
  esac
  [[ "$replace" == 1 ]] && args+=(--replace)
  bash "$script_dir/run-lpminer-ubuntu.sh" \
    --wallet "$wallet" --label "$label" --pool "$pool" --image "$image" --shm-gib "$shm" "${args[@]}"
}
prepare_bundle() {
  local wallet profile output
  wallet="$(ask '钱包地址 (tc1...)')"
  profile="$(ask '目标显卡档位：fp8、bf16 或 all' fp8)"
  output="$(ask '打包输出目录' "$HOME/lpminer-${profile}-bundle")"
  bash "$script_dir/prepare-lpminer-bundle-ubuntu.sh" --wallet "$wallet" --profile "$profile" --output "$output"
}
transfer_bundle() {
  local bundle target label shm
  bundle="$(ask '已准备好的 bundle 目录' "$HOME/lpminer-fp8-bundle")"
  target="$(ask '目标 SSH 用户@主机')"
  label="$(ask '目标矿工名' "$(hostname)-copy")"
  shm="$(ask '目标共享内存 GiB' 6)"
  bash "$script_dir/transfer-lpminer-ubuntu.sh" --bundle "$bundle" --target "$target" --label "$label" --shm-gib "$shm"
}
install_bundle() {
  local bundle label shm
  bundle="$(ask '本地 bundle 目录' /tmp/lpminer-bundle)"
  label="$(ask '矿工名' "$(hostname)")"
  shm="$(ask '共享内存 GiB' "$(gpu_default_shm)")"
  bash "$script_dir/install-lpminer-bundle-ubuntu.sh" --bundle "$bundle" --label "$label" --shm-gib "$shm"
}

while true; do
  clear 2>/dev/null || true
  cat <<'EOF'
=== Tensor Miner Ubuntu 管理菜单 ===
1) 安装 Docker 和 NVIDIA Container Toolkit
2) 拉取矿机镜像
3) 新建并启动矿机
4) 替换钱包、矿工名或矿池参数并重启
5) 停止矿机
6) 重启矿机
7) 实时查看矿机日志
8) 在无 GPU VPS 预下载镜像和模型
9) 打包当前已正常运行的矿机
10) 将已准备好的 bundle 迁移到另一台 Ubuntu
11) 在本 GPU 服务器恢复并安装 bundle
0) 退出
EOF
  read -rp '请选择：' selection
  case "$selection" in
    1) bash "$script_dir/install-docker-nvidia-ubuntu.sh" ;;
    2) docker pull "$(ask '镜像' "$image_default")" ;;
    3) start_miner 0 ;;
    4) start_miner 1 ;;
    5) docker stop lpminer ;;
    6) docker restart lpminer ;;
    7) docker logs -f lpminer ;;
    8) prepare_bundle ;;
    9) bash "$script_dir/package-lpminer-ubuntu.sh" --output "$(ask '打包输出目录' "$HOME/lpminer-bundle")" ;;
    10) transfer_bundle ;;
    11) install_bundle ;;
    0) exit 0 ;;
    *) printf '无效选择，请重新输入。\n' ;;
  esac
  pause
done
