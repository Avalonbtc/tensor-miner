#!/usr/bin/env bash
# Interactive front-end for all Ubuntu lpminer tasks.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image_default="avalonbtc/lpminer-tensorcash:1.1.1-overlay6"
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
container_shm_gib() {
  local bytes
  bytes="$(docker inspect --format '{{.HostConfig.ShmSize}}' lpminer 2>/dev/null || true)"
  if [[ "$bytes" =~ ^[0-9]+$ ]] && ((bytes > 0)); then
    printf '%s' $(((bytes + 1073741823) / 1073741824))
  else
    gpu_default_shm
  fi
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
  graph_mode="$(ask 'CUDA Graph 已默认开启；使用保守单卡测试参数？(y/N)' N)"
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
  [[ "$replace" == 1 ]] && args+=(--replace --preserve-runtime-env)
  bash "$script_dir/run-lpminer-ubuntu.sh" \
    --wallet "$wallet" --label "$label" --pool "$pool" --image "$image" --shm-gib "$shm" "${args[@]}"
}
configure_proxy_failover() {
  local action wallet label pool image shm proxy_file rotate worker_rotate threshold cooldown args=()
  docker inspect lpminer >/dev/null 2>&1 || {
    printf '未找到正在运行或已停止的 lpminer 容器，请先通过菜单 3 启动。\n'
    return
  }
  action="$(ask '代理故障切换：1=读取 S5 代理 txt，2=关闭' 1)"
  wallet="$(container_env WALLET)"
  label="$(container_env LABEL)"
  pool="$(container_env POOL)"
  image="$(ask '镜像（建议使用 1.1.1-overlay6）' "$image_default")"
  shm="$(container_shm_gib)"
  [[ -n "$wallet" && -n "$label" && -n "$pool" && -n "$image" ]] || {
    printf '无法读取当前矿机的完整启动参数，未进行修改。\n'
    return
  }
  case "$action" in
    1)
      proxy_file="$(ask 'S5 代理 txt 路径（每行 IP:端口:用户名:密码）' "$(container_env LP_TSC_PROXY_SOURCE_FILE)")"
      [[ -n "$proxy_file" ]] || {
        printf '代理 txt 路径不能为空，未进行修改。\n'
        return
      }
      rotate="$(ask '轮换方式（sequential 或 random）' "$(container_env LP_TSC_PROXY_ROTATE)")"
      rotate="${rotate:-sequential}"
      worker_rotate="$(ask '切换代理时自动更换矿工名（1=开启，0=关闭）' "$(container_env LP_TSC_PROXY_WORKER_ROTATE)")"
      worker_rotate="${worker_rotate:-1}"
      threshold="$(ask '单个代理失败几次后切换' "$(container_env LP_TSC_PROXY_FAILURE_THRESHOLD)")"
      threshold="${threshold:-1}"
      cooldown="$(ask '坏代理冷却秒数' "$(container_env LP_TSC_PROXY_COOLDOWN_SECS)")"
      cooldown="${cooldown:-60}"
      args+=(
        --proxy-file "$proxy_file"
        --proxy-rotate "$rotate"
        --proxy-worker-rotate "$worker_rotate"
        --proxy-failure-threshold "$threshold"
        --proxy-cooldown-secs "$cooldown"
      )
      ;;
    2)
      args+=(--disable-proxy-failover)
      ;;
    *)
      printf '无效选择，未进行修改。\n'
      return
      ;;
  esac
  printf '将重建 lpminer 以更新环境变量；lpminer-models 模型缓存会保留。\n'
  bash "$script_dir/run-lpminer-ubuntu.sh" \
    --wallet "$wallet" --label "$label" --pool "$pool" --image "$image" \
    --shm-gib "$shm" --replace --preserve-runtime-env "${args[@]}"
}
prepare_bundle() {
  local wallet profile output
  wallet="$(ask '钱包地址 (tc1...)')"
  profile="$(ask '目标显卡档位：fp8、bf16 或 all' fp8)"
  output="$(ask '打包输出文件 (.tar.gz)' "$HOME/lpminer-${profile}-bundle.tar.gz")"
  bash "$script_dir/prepare-lpminer-bundle-ubuntu.sh" --wallet "$wallet" --profile "$profile" --output "$output"
  quark_upload_prompt "${output%.tar.gz}.tar.gz"
}
package_bundle() {
  local output
  output="$(ask '打包输出文件 (.tar.gz)' "$HOME/lpminer-bundle.tar.gz")"
  bash "$script_dir/package-lpminer-ubuntu.sh" --output "$output"
  quark_upload_prompt "${output%.tar.gz}.tar.gz"
}
quark_upload_prompt() {
  local bundle="$1" enable cookie parent share args=()
  [[ -e "$bundle" ]] || {
    printf '未找到可上传的 bundle：%s\n' "$bundle" >&2
    return
  }
  enable="$(ask '上传到夸克网盘？(y/N)' N)"
  case "$enable" in
    y|Y|yes|YES)
      parent="$(ask '夸克目标目录 ID（0 为根目录）' 0)"
      share="$(ask '上传后创建分享链接？(y/N)' N)"
      read -rsp '粘贴夸克 Cookie（输入不回显）：' cookie
      printf '\n'
      [[ -n "$cookie" ]] || {
        printf 'Cookie 不能为空。\n' >&2
        return
      }
      if ! python3 -c 'import requests' >/dev/null 2>&1; then
        python3 -m pip install --user requests
      fi
      [[ "$share" =~ ^(y|Y|yes|YES)$ ]] && args+=(--share)
      printf '%s' "$cookie" | python3 "$script_dir/upload-quark-bundle.py" --file "$bundle" --cookie-stdin --parent-id "$parent" "${args[@]}"
      unset cookie
      ;;
    n|N|no|NO|'') ;;
    *) printf '无效选择，跳过夸克上传。\n' ;;
  esac
}
upload_existing_quark() {
  local bundle
  bundle="$(ask 'bundle 压缩包 (.tar.gz) 或 .work 文件夹' "$HOME/lpminer-bundle.tar.gz")"
  quark_upload_prompt "$bundle"
}
transfer_bundle() {
  local source bundle target label shm args=()
  source="$(ask '传输来源：1=自动打包当前运行矿机，2=使用已准备 bundle' 1)"
  target="$(ask '目标 SSH 用户@主机')"
  label="$(ask '目标矿工名' "$(hostname)-copy")"
  shm="$(ask '目标共享内存 GiB' 6)"
  case "$source" in
    1)
      ;;
    2)
      bundle="$(ask 'bundle 压缩包 (.tar.gz) 或未完成的 .work 目录' "$HOME/lpminer-fp8-bundle.tar.gz")"
      args+=(--bundle "$bundle")
      ;;
    *)
      printf '无效选择，未开始传输。\n'
      return
      ;;
  esac
  bash "$script_dir/transfer-lpminer-ubuntu.sh" \
    --target "$target" --label "$label" --shm-gib "$shm" "${args[@]}"
}
install_bundle() {
  local bundle label shm
  bundle="$(ask '本地 bundle 压缩包 (.tar.gz)' /tmp/lpminer-bundle.tar.gz)"
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
10) 自动打包或迁移 bundle 到另一台 Ubuntu
11) 在本 GPU 服务器恢复并安装 bundle
12) 读取 S5 代理 txt 并配置 IP ban 切换（保留模型缓存并重建矿机）
13) 修复 Docker Hub 大镜像断线下载
14) 上传 bundle 到夸克网盘（支持断点续传）
0) 退出
EOF
  read -rp '请选择：' selection
  case "$selection" in
    1) bash "$script_dir/install-docker-nvidia-ubuntu.sh" ;;
    2) docker pull "$(ask '镜像' "$image_default")" ;;
    3) start_miner 0 ;;
    4) start_miner 1 ;;
    5) docker stop --time 90 lpminer ;;
    6) docker restart --time 90 lpminer ;;
    7) docker logs -f lpminer ;;
    8) prepare_bundle ;;
    9) package_bundle ;;
    10) transfer_bundle ;;
    11) install_bundle ;;
    12) configure_proxy_failover ;;
    13) bash "$script_dir/configure-docker-pull-ubuntu.sh" ;;
    14) upload_existing_quark ;;
    0) exit 0 ;;
    *) printf '无效选择，请重新输入。\n' ;;
  esac
  pause
done
