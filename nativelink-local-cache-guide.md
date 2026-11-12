# 本地 NativeLink 缓存搭建手册（Docker Hub 不可 pull 环境专用）

> **版本基线**：NativeLink **v1.8.3**（2026-10 实测：GitHub Release 提供 `x86_64-unknown-linux-musl` / `aarch64-unknown-linux-musl` 静态包，x86_64 包约 **20.6 MB**）
> **目标**：在一台 Ubuntu 机器上跑起一个常驻的 Bazel 远程缓存服务，供本机 / 局域网内同事 / CI 共享编译产物。
> **核心约束**：全程**不使用任何容器镜像仓库**。

配套文件（同一目录）：

| 文件 | 用途 |
|---|---|
| `install-nativelink.sh` | 一键部署脚本（离线优先，自动探测架构 / 多源下载 / 装 systemd） |
| `cas.json5` | 纯缓存服务配置（可直接改） |
| `nativelink-cas.service` | systemd unit |

---

## 0. 先做三个决策

### 决策 1：**不要为了上 NativeLink 而上 Docker**

Docker Hub 拉不动时，最容易卡死的地方是"想办法把镜像搞进来"。但 NativeLink 官方 Release 直接给 **musl 静态二进制**——单个可执行文件，无动态库依赖，不需要 docker、不需要 `apt install` 任何包。

| 方案 | 是否需要镜像仓库 | 需要外网 | 复杂度 | 结论 |
|---|---|---|---|---|
| **A. Release 静态二进制 + systemd** | ❌ 不需要 | 仅下载一次 20MB | 低 | ✅ **本手册主线** |
| B. 内网 Harbor 中转镜像 | 需要内网 registry | 一次性 pull | 中 | 仅当你坚持用容器时 |
| C. `docker save` / `load` 离线搬运 | 不需要 | 需要一台外网机 | 中 | B 的轻量替代 |
| D. 源码 cargo 编译 | 不需要 | 需要 crates.io 或镜像 | 高（编译久） | 最后一招 |
| E. 源码 Bazel 编译 | 不需要（可离线 vendor BCR） | 需要 BCR | 高 | 与既有 Bazel 离线 vendor 能力契合，兜底用 |

### 决策 2：**先确认"共享"是否真的成立**

只有你一个人、一台机器时，`--disk_cache` 更简单、更快、零运维。NativeLink 的增量价值来自：

- 多台开发机 / CI runner 命中同一份产物（换分支、新机器 clone 后首次构建直接命中）
- 缓存容量与生命周期独立于任意一台机器的 `bazel clean`

**如果答案是"就我自己"，看到第 6 章就够了，服务可以只监听 `127.0.0.1`。**

### 决策 3：**Bazel 和 NativeLink 放在同一个 Linux 里**

若你的 Bazel 跑在 Windows 原生、NativeLink 跑在 WSL2，会撞上 WSL2 每次重启 IP 变化的问题，得不偿失。**让两者同居一个 Ubuntu（物理机 / 虚拟机 / WSL2 皆可）**，用 `localhost` 直连。

---

## 1. 前置检查清单

```bash
cat /etc/os-release | grep -E "^(NAME|VERSION)"   # Ubuntu 20.04/22.04/24.04 均可
uname -m                                           # x86_64 或 aarch64
df -h /var/lib                                     # 建议 ≥ 100GB 可用，越快越好（SSD/NVMe）
ulimit -n                                          # 默认 1024，必须调大
ss -lntp | grep -E "50051|50052|50061" || echo "端口空闲"
```

**端口约定**（先记住，后面全程用）：

| 端口 | 服务 | 谁能访问 |
|---|---|---|
| **50051** | CAS / AC / ByteStream / Capabilities | 构建客户端（本手册只用这个） |
| 50052 | Scheduler 客户端面 | 构建客户端（远程执行才需要，本手册不用） |
| 50061 | worker API | **仅内网**，无认证（本手册不用） |

---

## 2. 第 1 章：拿到二进制（四条路径，按网络从好到差）

### 路径 A：直连 GitHub Release（网络通时的首选）

```bash
V=1.8.3
ARCH=$(uname -m)                                   # x86_64 | aarch64
case "$ARCH" in x86_64|amd64) T=x86_64-unknown-linux-musl;; aarch64|arm64) T=aarch64-unknown-linux-musl;; esac
curl -fsSL -o nativelink.tar.gz \
  "https://github.com/TraceMachina/nativelink/releases/download/v${V}/nativelink-${V}-${T}.tar.gz"
ls -la nativelink.tar.gz                           # x86_64 约 20592651 bytes，明显偏小就是错误页
```

### 路径 B：GitHub 加速镜像（直连不稳时）

下载源换成"镜像前缀 + 原始 URL"，例如：

```bash
BASE="https://ghfast.top/https://github.com"       # 也可试 gh-proxy.com / gh.llkk.cc / hub.gitmirror.com
curl -fsSL -o nativelink.tar.gz \
  "${BASE}/TraceMachina/nativelink/releases/download/v${V}/nativelink-${V}-${T}.tar.gz"
```

> ⚠️ 公共加速服务不可信且随时失效，只当作"下载通道"。**落盘后必须做校验**（见 2.5）。

### 路径 C：完全离线搬运（内网车间 / 无出口）

在任意一台能上网的机器上：

```bash
# 1) 下载（同上）
# 2) 记录校验和 —— 这张纸条和 U 盘一起带走
sha256sum nativelink-1.8.3-x86_64-unknown-linux-musl.tar.gz | tee SHA256SUMS
# 3) 可选：额外下载签名与证明，供内网侧验证
curl -fsSLO "https://github.com/TraceMachina/nativelink/releases/download/v1.8.3/nativelink-1.8.3-x86_64-unknown-linux-musl.tar.gz.sig"
curl -fsSLO "https://github.com/TraceMachina/nativelink/releases/download/v1.8.3/nativelink-1.8.3.intoto.jsonl"
```

搬到目标机后：

```bash
sha256sum -c SHA256SUMS          # 必须 OK
```

然后用脚本离线安装（**这是推荐姿势**）：

```bash
sudo ./install-nativelink.sh \
  --tarball ./nativelink-1.8.3-x86_64-unknown-linux-musl.tar.gz \
  --sha256  <上面那条 sha256>
```

### 路径 D：源码自编译（以上全不通时的兜底）

**D1 — Cargo**（需要 crates.io，国内可换镜像）：

```bash
mkdir -p ~/.cargo && cat > ~/.cargo/config.toml <<'EOF'
[source.crates-io]
replace-with = "rsproxy-sparse"
[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/crates.io-index/"
# 备选：sparse+https://mirrors.ustc.edu.cn/crates.io-index/
EOF

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh     # 或 apt install cargo
cargo install --git https://github.com/TraceMachina/nativelink --tag v1.8.3
```

> `--git` 拉的是 GitHub，不通时把 URL 换成加速镜像前缀。首次编译耗时较长，仅当二进制实在拿不到时用。

**D2 — Bazel**（与"离线 vendor 依赖"的既有能力契合）：

```bash
git clone -b v1.8.3 https://github.com/TraceMachina/nativelink.git
cd nativelink
bazel run -c opt //:nativelink -- $(pwd)/nativelink-config/examples/basic_cas.json5
```

> 官方要求 Bazel 7.0.2+、C++ 工具链 + LLD；首次构建 10–20 分钟。BCR 依赖可按既有做法做离线 vendor / 内网 registry。

**D3 — Nix**（需要 flakes 与 substituter，国内需配镜像）：

```bash
nix run github:TraceMachina/nativelink/v1.8.3 ./basic_cas.json5
```

### 2.5 完整性校验（离线搬运必做）

```bash
sha256sum nativelink-1.8.3-*.tar.gz
# 有 gh CLI 且能连 GitHub 时，可做来源证明校验：
# gh attestation verify nativelink-1.8.3-x86_64-unknown-linux-musl.tar.gz --repo TraceMachina/nativelink
```

**体积参考（v1.8.3）**：x86_64 musl 包 = **20,592,651 bytes**。差一个量级就说明下到了错误页/代理拦截页。

---

## 3. 第 2 章：安装（两种方式，选一）

### 方式一：脚本一键（推荐）

```bash
cd nativelink-local-cache
chmod +x install-nativelink.sh
sudo ./install-nativelink.sh --tarball ./nativelink-1.8.3-x86_64-unknown-linux-musl.tar.gz
```

脚本会依次完成：架构探测 → 获取/校验 tarball → 装 `/usr/local/bin/nativelink` → 建 `nativelink` 系统用户与数据目录 → 写 `/etc/nativelink/cas.json5` → 装 systemd unit 并 `enable --now` → 端口冒烟。

常用开关：`--listen 127.0.0.1:50051`（只本机）、`--dir /data/nativelink`（换数据盘）、`--no-systemd`（WSL2/容器）。

### 方式二：手工逐步（想搞清楚每一步时）

```bash
# 1) 解包安装
tar -xzf nativelink-1.8.3-x86_64-unknown-linux-musl.tar.gz
sudo install -m 0755 nativelink /usr/local/bin/nativelink
nativelink --version

# 2) 用户与目录
sudo useradd --system --home-dir /var/lib/nativelink --shell /usr/sbin/nologin nativelink
sudo mkdir -p /var/lib/nativelink/{cas,ac}/{content,tmp}
sudo chown -R nativelink:nativelink /var/lib/nativelink

# 3) 文件描述符（C++ 大规模并行构建的隐性杀手）
sudo tee /etc/security/limits.d/99-nativelink.conf >/dev/null <<'EOF'
nativelink soft nofile 524288
nativelink hard nofile 524288
EOF

# 4) 配置
sudo mkdir -p /etc/nativelink
sudo cp cas.json5 /etc/nativelink/cas.json5
sudo chown root:nativelink /etc/nativelink/cas.json5 && sudo chmod 0640 /etc/nativelink/cas.json5

# 5) systemd
sudo cp nativelink-cas.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nativelink-cas
sudo systemctl --no-pager status nativelink-cas
```

---

## 4. 第 3 章：配置文件逐段讲解

`cas.json5` 只有两个顶层键 —— `stores`（存储）和 `servers`（监听 + 服务）。**没有 `schedulers`、没有 `workers`**，所以它只做缓存。

| 段 | 作用 | 关键取值 |
|---|---|---|
| `global.max_open_files` | 进程可打开文件数 | `524288`（二进制默认仅 24576；且只会用到系统上限的 80%，所以 `limits.d` 必须同步调） |
| `stores[0] CAS_MAIN_STORE` | 存真实字节（.o、产物、头文件快照） | `filesystem` + `compression{lz4}` + `eviction_policy.max_bytes` |
| `stores[1] AC_MAIN_STORE` | 存 action 结果元数据 | 500MB 起；丢了只是重算，不致命 |
| `servers[0].listener` | `0.0.0.0:50051`（共享）/ `127.0.0.1:50051`（仅本机） | 需要 TLS 时加 `tls{cert_file,key_file,client_ca_file}` |
| `services.cas` / `ac` / `bytestream` | 三个必需的缓存面 | 同时注册 `""` 与 `"main"` 两个 instance_name |
| `services.capabilities` | 告诉客户端支持什么 | 配 `remote_cache_compression: true` 才能配合 Bazel 的 `--remote_cache_compression`（zstd） |

**为什么同时注册 `""` 和 `"main"`**：Bazel 的 `--remote_instance_name` 默认值是空字符串。服务端若只注册了 `main`，客户端不显式指定就会出现"写入成功但永远读不命中"——这是最高频的故障。两个都注册，从根上消掉。

**为什么不直接用仓库自带的 `basic_cas.json5`**：v1.8.3 里那份其实是 **all-in-one**（内含 `workers`、`schedulers` 与 `execution` 服务，本机会真的去跑 action）。本手册要的是纯缓存，所以重写了一份精简版。

> 配置解析用 `serde(deny_unknown_fields)`：**字段名写错 = 启动即非零退出**，不会静默降级。所以"进程还活着"就是配置正确的充分证据。

改完必须重启才生效（配置只在启动时整体解析一次）：

```bash
sudo systemctl restart nativelink-cas && sudo journalctl -u nativelink-cas -n 20 --no-pager
```

---

## 5. 第 4 章：启动与冒烟验证

```bash
# 服务状态
sudo systemctl --no-pager status nativelink-cas

# 端口连通性（返回 gRPC 错误码是正常的 —— / 不是 gRPC 路由，能建连即通过）
curl -v http://127.0.0.1:50051/

# 日志
sudo journalctl -u nativelink-cas -f

# 期望看到类似：
# INFO nativelink: Ready, listening on 0.0.0.0:50051
```

**首次人工验证（不用 Bazel 也能做）**：随便往 CAS 写个 blob 再读回来，看日志里有没有 `get`/`update` 记录。更简单的做法是跳过，直接用 Bazel 验证（第 6 章）。

---

## 6. 第 5 章：让局域网同事和 CI 也能用

### 6.1 监听地址

`cas.json5` 里保持 `0.0.0.0:50051`；只本机自用则改 `127.0.0.1:50051`。

### 6.2 防火墙

```bash
sudo ufw allow proto tcp from 192.168.1.0/24 to any port 50051 comment 'nativelink cas'
sudo ufw reload
sudo ufw status numbered
```

### 6.3 安全边界（重要）

**CAS 默认没有身份认证**。任何能连到 50051 的人都能读写缓存 —— 在内网这是可接受的（最坏情况是缓存被投毒，需要重新构建），但**不要把它暴露到公网或办公网全域**。需要认证就上 mTLS（`listener.http.tls.client_ca_file`）。

---

## 7. 第 6 章：Bazel 接入与验收

### 7.1 `.bazelrc`

```python
build:nlc --remote_cache=grpc://192.168.1.50:50051   # 换成缓存机 IP
build:nlc --remote_instance_name=main
build:nlc --remote_cache_compression                  # 服务端 capabilities 已开启 zstd
build:nlc --remote_download_outputs=toplevel          # 中间 .o 留在 CAS，只下载顶层产物
build:nlc --remote_upload_local_results
build:nlc --experimental_remote_cache_eviction_retries=5   # 缓存被驱逐时重试，避免 exit 39
build:nlc --remote_timeout=600

# 断网/缓存机不可用时的兜底：本机仍有一级缓存
build --disk_cache=/home/$USER/.cache/bazel-disk
```

用法：`bazel build --config=nlc //...`

### 7.2 验收（必须有数字，别凭感觉）

```bash
# 基线：无任何缓存
bazel clean --expunge && time bazel build //...

# 接缓存后第一次（写入，会比本地略慢，正常）
time bazel build --config=nlc //...

# 接缓存后第二次（换台机器做才有意义 —— 这才是"共享缓存"的证明）
bazel clean --expunge
bazel build --config=nlc //... --execution_log_json_file=/tmp/exec.json
grep -c '"remoteCacheHit": true'  /tmp/exec.json     # 命中数
grep -c '"remoteCacheHit": false' /tmp/exec.json     # 未命中数
```

看 summary 行：

```
INFO: 1234 processes: 1000 remote cache hit, 50 internal, 184 linux-sandbox.
                      ^^^^^^^^^^^^^^^^^^^^ 这个数就是收益
```

**验收门槛**：同工作区二次构建命中率 > 90%；CI 全新容器 > 70%（取决于当次改动面）。

### 7.3 命中率为 0 时的三查

1. **`--remote_instance_name` 是否与服务端注册的一致**（服务端注册了 `""` 和 `main`，两者都行；填了别的就完蛋）
2. **Bazel 版本 / 工具链是否一致** —— 工具链不同 = action hash 永不碰撞（团队务必用 `.bazelversion` 锁版本）
3. **端口/防火墙是否真的通** —— `curl -v http://<ip>:50051/`

---

## 8. 第 7 章：团队共享的三条硬约束

| 约束 | 说明 | 做法 |
|---|---|---|
| **同一个 `instance_name`** | 不一致 = 各写各的，命中率永远 0 | 全员统一 `main` |
| **同一个 Bazel 版本** | 版本变了 action hash 可能变 | 仓库根 `.bazelversion` + bazelisk |
| **同一套工具链** | 系统 gcc 版本、`/usr/include`、环境差异都会进 hash | 统一基础镜像 / 统一 Ubuntu 版本 + 包版本 |

不满足这三条，缓存会变成"能写不能读"的摆设。**这也是为什么第一步先做缓存、而不是一步跳到远程执行**：远程执行会把工具链不一致一次性放大成硬失败。

---

## 9. 第 8 章：日常运维

### 9.1 容量与驱逐

```bash
du -sh /var/lib/nativelink/cas /var/lib/nativelink/ac
```

- CAS 按**工作集**定容（一次全量构建的去重字节 × 2~3），超了只降命中率，不会构建失败。
- 满了就调大 `max_bytes` 后 `systemctl restart`；或换更大的盘后用 `--dir` 重装。
- AC 只存元数据，500MB 通常够。

### 9.2 备份与迁移

```bash
sudo systemctl stop nativelink-cas
sudo tar -C /var/lib -czf nativelink-data-$(date +%F).tar.gz nativelink
sudo systemctl start nativelink-cas
```

迁移到新机器：解包到 `/var/lib/nativelink` → `chown -R nativelink:nativelink` → 装同版本二进制与配置 → 启动。

### 9.3 升级

```bash
sudo systemctl stop nativelink-cas
sudo install -m 0755 <新版本 nativelink> /usr/local/bin/nativelink
sudo systemctl start nativelink-cas          # 配置不兼容会立即退出，旧二进制还在，可回滚
```

> **只有 CAS 进程是有状态的**，升级本身不涉及数据迁移。跨大版本升级前在测试机上先跑一遍。

### 9.4 卸载

```bash
sudo systemctl disable --now nativelink-cas
sudo rm -f /etc/systemd/system/nativelink-cas.service /usr/local/bin/nativelink
sudo rm -rf /etc/nativelink /var/lib/nativelink
sudo userdel nativelink
```

---

## 10. 第 9 章：将来要上远程执行，镜像从哪来

本手册只做缓存，**不需要任何容器镜像**。若后续要开远程执行（worker 跑 action），worker 需要带工具链的执行环境，那时才必须解决镜像问题：

```bash
# 在一台能上网的机器上
docker pull ghcr.io/tracemachina/nativelink:v1.8.3
docker pull <你的工具链基础镜像>
docker save -o nl-images.tar ghcr.io/tracemachina/nativelink:v1.8.3 <工具链镜像>

# 搬到内网
docker load -i nl-images.tar
docker tag ghcr.io/tracemachina/nativelink:v1.8.3 harbor.internal/build/nativelink:v1.8.3
docker push harbor.internal/build/nativelink:v1.8.3     # 推内网 Harbor，之后全队可拉
```

另一条路：**worker 不用容器**，直接 systemd 跑原生 worker 进程（与本文同样的套路），工具链用宿主机自带的 Ubuntu 环境 —— 内网小规模起步最省事，代价是工具链一致性靠人肉保证。

> 另注：仓库 `deployment-examples/docker-compose` 里的验证脚本会拉 `gcr.io/bazel-public/bazel`，在内网环境不要照抄 compose 流程。

---

## 11. 第 10 章：故障排查

| 现象 | 原因 | 处置 |
|---|---|---|
| `curl` 连不上 50051 | 服务没起 / 监听 127.0.0.1 / 防火墙 | `systemctl status`；`ss -lntp \| grep 50051`；`ufw status` |
| 服务起不来，日志报未知字段 | 配置字段名拼错（`deny_unknown_fields`） | 对照 §4 逐键检查；看日志报的是哪个 key |
| 启动报 `Permission denied` | 数据目录属主不对 | `chown -R nativelink:nativelink /var/lib/nativelink` |
| 构建命中率永远是 0 | instance_name 不一致 / Bazel 或工具链版本不同 | §7.3 三查 |
| 构建以 **exit 39** 结束 | 缓存 blob 被驱逐 | `--experimental_remote_cache_eviction_retries=5`；Bazel 9.1+ 加 `--rewind_lost_inputs` |
| 莫名变慢、无报错 | 打开文件数达到上限 | 调 `ulimit` + `global.max_open_files`（两者都要） |
| 下载下来只有几十 KB | 命中了错误页 / 代理拦截页 | 换下载源；核对体积应约 20.6MB |
| `tar` 解压后找不到二进制 | 下错文件（`*.sig` / `*.pem` 等） | 确认文件名以 `.tar.gz` 结尾 |
| WSL2 里 systemd 不可用 | WSL2 默认不启用 systemd | 用 `--no-systemd`，或 `sudo -u nativelink nativelink /etc/nativelink/cas.json5 &` |
| 磁盘写满 | 工作集超出容量 | 调大 `max_bytes` 或换盘 |

---

## 12. 附录 A：申请外网白名单时的域名清单

如果走"申请出口放行"这条路，把这些交给网络管理员（只放行下载所需，不必全开）：

```
github.com
codeload.github.com
objects.githubusercontent.com
release-assets.githubusercontent.com
raw.githubusercontent.com
ghcr.io
pkg-containers.githubusercontent.com
crates.io          （仅路径 D1 需要）
static.crates.io   （仅路径 D1 需要）
index.crates.io    （仅路径 D1 需要）
```

## 13. 附录 B：文件清单与落位

```
/usr/local/bin/nativelink                      # musl 静态二进制
/etc/nativelink/cas.json5                      # 配置（改完要 restart）
/etc/systemd/system/nativelink-cas.service     # systemd unit
/etc/security/limits.d/99-nativelink.conf      # nofile 524288
/var/lib/nativelink/cas/{content,tmp}          # CAS 数据（快盘）
/var/lib/nativelink/ac/{content,tmp}           # AC 数据
```

## 14. 附录 C：一句话 recap

> 拉不动镜像就不拉 —— **用 20MB 的静态二进制 + systemd 起一个 50051 的 CAS**，`.bazelrc` 加三行 flag，`grep -c remoteCacheHit` 数出命中率。缓存服务的价值不在"本机更快"，而在**换机器、换分支、CI 全新容器时依然命中**。
