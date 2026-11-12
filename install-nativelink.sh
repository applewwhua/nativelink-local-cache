#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# NativeLink 本地缓存服务 —— 一键部署脚本（离线优先，不依赖任何镜像仓库）
#
# 设计前提：Docker Hub / ghcr.io 不可达。主线做法是直接用 GitHub Release 的
# musl 静态二进制 + systemd，全程不需要 docker、不需要 apt install 任何东西。
#
# 用法：
#   # 1) 已把 tarball 放到脚本同目录（离线场景，推荐）
#   sudo ./install-nativelink.sh --tarball ./nativelink-1.8.3-x86_64-unknown-linux-musl.tar.gz
#
#   # 2) 在线直接拉（脚本会依次尝试多个源）
#   sudo ./install-nativelink.sh
#
#   # 3) 指定版本 / 校验和 / 监听地址
#   sudo ./install-nativelink.sh --version 1.8.3 \
#        --sha256 <下载机算出的 sha256> \
#        --listen 0.0.0.0:50051
#
# 可选参数：
#   --version V      版本号，默认 1.8.3
#   --tarball PATH   使用本地已有 tarball，跳过下载
#   --sha256  HEX    校验下载/本地文件的 sha256（强烈建议离线搬运时给出）
#   --listen  ADDR   监听地址，默认 0.0.0.0:50051
#   --dir     PATH   数据根目录，默认 /var/lib/nativelink
#   --no-systemd     不安装 systemd unit，仅做二进制 + 配置 + 前台启动提示
# ---------------------------------------------------------------------------
set -euo pipefail

VERSION="1.8.3"
TARBALL=""
SHA256_EXPECT=""
LISTEN="0.0.0.0:50051"
DATA_DIR="/var/lib/nativelink"
USE_SYSTEMD=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# `bazel run //tools/nativelink:install` 场景：脚本经 bazel-bin 下的软链执行，
# 它的同目录里没有 cas.json5 / nativelink-cas.service —— 这两个文件作为 data
# 放在 runfiles 的同一包目录下，这里回退过去（直接执行脚本时行为不变）。
# sudo 会清掉 RUNFILES_DIR，所以同时也按 `<脚本名>.runfiles` 相对推导。
if [[ ! -f "${SCRIPT_DIR}/cas.json5" ]]; then
  for root in "${RUNFILES_DIR:-}" "${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}").runfiles"; do
    [[ -n "${root}" ]] || continue
    for workspace in _main igloo; do
      candidate="${root}/${workspace}/tools/nativelink"
      if [[ -f "${candidate}/cas.json5" ]]; then
        SCRIPT_DIR="${candidate}"
        break 2
      fi
    done
  done
fi

log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)    VERSION="$2"; shift 2 ;;
    --tarball)    TARBALL="$2"; shift 2 ;;
    --sha256)     SHA256_EXPECT="$2"; shift 2 ;;
    --listen)     LISTEN="$2"; shift 2 ;;
    --dir)        DATA_DIR="$2"; shift 2 ;;
    --no-systemd) USE_SYSTEMD=0; shift ;;
    -h|--help)    sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)            die "未知参数: $1" ;;
  esac
done

# 非 root 时自动通过 sudo 重新执行，`bazel run //tools/nativelink:install`
# 因此可以一条命令装完。sudo 会清掉环境变量（RUNFILES_DIR 等），脚本已按
# `<脚本名>.runfiles` 相对推导，重新执行后仍能定位 cas.json5 与 unit。
if [[ $EUID -ne 0 ]]; then
  SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  log "需要 root，通过 sudo 重新执行: sudo bash ${SELF}"
  exec sudo bash "${SELF}" "$@"
fi

# --------------------------------------------------------------------------
# 0. 环境探测
# --------------------------------------------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)   TARGET="x86_64-unknown-linux-musl" ;;
  aarch64|arm64)  TARGET="aarch64-unknown-linux-musl" ;;
  *)              die "不支持的架构: $ARCH（Release 仅提供 x86_64 / aarch64 的 musl 包）" ;;
esac
FILE="nativelink-${VERSION}-${TARGET}.tar.gz"
log "架构: ${ARCH} → ${TARGET}；版本: ${VERSION}"

# --------------------------------------------------------------------------
# 1. 获取 tarball：本地优先 → 多源下载
# --------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -n "$TARBALL" ]]; then
  [[ -f "$TARBALL" ]] || die "指定的 tarball 不存在: $TARBALL"
  log "使用本地 tarball: $TARBALL"
  cp "$TARBALL" "${WORK}/${FILE}"
else
  # 直连 + 常见 GitHub 加速镜像（公共加速服务可用性随时变化，逐个试）
  MIRRORS=(
    "https://gh-proxy.com/https://github.com"
    "https://github.com"
    "https://ghfast.top/https://github.com"
    "https://gh.llkk.cc/https://github.com"
    "https://hub.gitmirror.com/https://github.com"
  )
  URL_PATH="/TraceMachina/nativelink/releases/download/v${VERSION}/${FILE}"
  OK=0
  for base in "${MIRRORS[@]}"; do
    url="${base}${URL_PATH}"
    log "尝试下载: ${url}"
    if curl -fsSL --connect-timeout 10 --max-time 300 -o "${WORK}/${FILE}" "$url"; then
      # 下载到的必须是 gzip，且大小合理（远小于 1MB 说明是错误页）
      sz=$(stat -c%s "${WORK}/${FILE}" 2>/dev/null || echo 0)
      if [[ "$sz" -lt 1048576 ]]; then
        warn "下载内容异常（${sz} bytes），换下一个源"
        continue
      fi
      if command -v file >/dev/null 2>&1; then
        file "${WORK}/${FILE}" | grep -qi 'gzip' || { warn "不是 gzip 归档，换下一个源"; continue; }
      fi
      log "下载完成: ${sz} bytes"
      OK=1
      break
    fi
    warn "该源失败，换下一个"
  done
  [[ $OK -eq 1 ]] || die "所有下载源均失败。请在一台能上网的机器上手动下载后传入内网：
    https://github.com/TraceMachina/nativelink/releases/download/v${VERSION}/${FILE}
  然后： sudo $0 --tarball /path/to/${FILE}"
fi

# --------------------------------------------------------------------------
# 2. 完整性校验
# --------------------------------------------------------------------------
if [[ -n "$SHA256_EXPECT" ]]; then
  got="$(sha256sum "${WORK}/${FILE}" | awk '{print $1}')"
  [[ "$got" == "$SHA256_EXPECT" ]] || die "sha256 不匹配！
    期望: ${SHA256_EXPECT}
    实际: ${got}"
  log "sha256 校验通过: ${got}"
else
  got="$(sha256sum "${WORK}/${FILE}" | awk '{print $1}')"
  warn "未提供 --sha256，无法校验完整性。建议记录此值供内网其他机器比对："
  warn "    ${FILE}  sha256=${got}"
fi

# --------------------------------------------------------------------------
# 3. 安装二进制
# --------------------------------------------------------------------------
tar -xzf "${WORK}/${FILE}" -C "$WORK"
BIN="$(find "$WORK" -maxdepth 2 -type f -name nativelink -perm -u+x | head -n1)"
[[ -n "$BIN" ]] || die "解压后未找到 nativelink 可执行文件"
install -m 0755 "$BIN" /usr/local/bin/nativelink
log "已安装: /usr/local/bin/nativelink"
/usr/local/bin/nativelink --version || warn "无法获取版本号（不影响使用）"

# --------------------------------------------------------------------------
# 4. 用户 / 目录 / 文件描述符上限
# --------------------------------------------------------------------------
if ! id -u nativelink >/dev/null 2>&1; then
  useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin nativelink
  log "已创建系统用户 nativelink"
fi

mkdir -p "${DATA_DIR}/cas/content" "${DATA_DIR}/cas/tmp" \
         "${DATA_DIR}/ac/content"  "${DATA_DIR}/ac/tmp"
chown -R nativelink:nativelink "$DATA_DIR"

cat >/etc/security/limits.d/99-nativelink.conf <<'EOF'
# NativeLink：C++ 大规模并行构建需要大量文件描述符
nativelink soft nofile 524288
nativelink hard nofile 524288
EOF
log "已写入 /etc/security/limits.d/99-nativelink.conf"

# --------------------------------------------------------------------------
# 5. 配置文件
# --------------------------------------------------------------------------
mkdir -p /etc/nativelink
if [[ -n "$TARBALL" ]]; then
  # 离线场景：优先用脚本同目录里手工改过的配置
  SRC_CFG="${SCRIPT_DIR}/cas.json5"
else
  SRC_CFG="${SCRIPT_DIR}/cas.json5"
fi
[[ -f "$SRC_CFG" ]] || die "缺少配置文件: ${SRC_CFG}"

if [[ -f /etc/nativelink/cas.json5 ]]; then
  cp /etc/nativelink/cas.json5 "/etc/nativelink/cas.json5.bak.$(date +%s)"
  warn "已备份旧配置"
fi
sed -e "s#0\.0\.0\.0:50051#${LISTEN}#" \
    -e "s#/var/lib/nativelink#${DATA_DIR}#g" \
    "$SRC_CFG" >/etc/nativelink/cas.json5
chown root:nativelink /etc/nativelink/cas.json5
chmod 0640 /etc/nativelink/cas.json5
log "已写入配置: /etc/nativelink/cas.json5（监听 ${LISTEN}）"

# --------------------------------------------------------------------------
# 6. 启动
# --------------------------------------------------------------------------
if [[ $USE_SYSTEMD -eq 1 ]] && [[ "$(ps -p 1 -o comm= 2>/dev/null || echo unknown)" == "systemd" ]]; then
  install -m 0644 "${SCRIPT_DIR}/nativelink-cas.service" /etc/systemd/system/nativelink-cas.service
  sed -i "s#/var/lib/nativelink#${DATA_DIR}#g" /etc/systemd/system/nativelink-cas.service
  systemctl daemon-reload
  systemctl enable --now nativelink-cas
  sleep 2
  systemctl --no-pager status nativelink-cas || true
  log "服务已启动并设置开机自启"
  LOG_HINT="journalctl -u nativelink-cas -f"
else
  warn "未检测到 systemd（WSL2 / 容器场景），改为前台/后台直接运行："
  warn "    sudo -u nativelink /usr/local/bin/nativelink /etc/nativelink/cas.json5"
  if command -v runuser >/dev/null; then
    runuser -u nativelink -- /usr/local/bin/nativelink /etc/nativelink/cas.json5 \
      >/var/log/nativelink.log 2>&1 &
    sleep 2
  fi
  LOG_HINT="tail -f /var/log/nativelink.log"
fi

# --------------------------------------------------------------------------
# 7. 冒烟测试
# --------------------------------------------------------------------------
PORT="${LISTEN##*:}"
if command -v curl >/dev/null; then
  # 能建连即算通过（返回 gRPC 错误码是正常的，因为 / 不是 gRPC 路由）
  curl -sS --max-time 5 -o /dev/null "http://127.0.0.1:${PORT}/" \
    && log "端口 ${PORT} 可连通（返回错误码属正常）" \
    || warn "端口 ${PORT} 未能连通，请检查：${LOG_HINT}"
fi

cat <<EOF

─────────────────────────────────────────────────────────────
NativeLink 缓存已就绪

  监听      : ${LISTEN}
  数据目录  : ${DATA_DIR}
  配置      : /etc/nativelink/cas.json5
  日志      : ${LOG_HINT}

下一步（在构建机上）：
  bazel build //... \\
    --remote_cache=grpc://<本机IP>:${PORT} \\
    --remote_instance_name=main \\
    --remote_cache_compression

验收：
  bazel build --remote_cache=grpc://<本机IP>:${PORT} --remote_instance_name=main //... \\
    --execution_log_json_file=/tmp/exec.json
  grep -c '"remoteCacheHit": true' /tmp/exec.json

开放局域网访问（Ubuntu 防火墙）：
  sudo ufw allow proto tcp from 192.168.1.0/24 to any port ${PORT}
─────────────────────────────────────────────────────────────
EOF
