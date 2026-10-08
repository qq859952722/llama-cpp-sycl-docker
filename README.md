# llama.cpp SYCL Docker for Intel iGPU / Arc (with Autocheck Multi-Model Manager)

[![Build and Publish SYCL Docker Image](https://github.com/qq859952722/llama-cpp-sycl-docker/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/qq859952722/llama-cpp-sycl-docker/actions/workflows/docker-publish.yml)

本项目提供针对 **Intel 12代 (Alder Lake i7-12700H) 核显 (Iris Xe 96EU)** 及 **Intel Arc 系列独立显卡** 深度调优的 `llama.cpp` SYCL 容器化镜像构建方案。

通过 GitHub Actions 自动构建并发布至 GitHub Packages (GHCR)：
- `ghcr.io/qq859952722/llama-cpp-sycl-docker:latest`（常规单模型服务）
- `ghcr.io/qq859952722/llama-cpp-sycl-docker:autocheck`（**支持多模型热插拔自愈管控**）

---

## 🌟 核心特性与架构亮点

### 1. 满血 AOT 与硬件编译优化（实测追平 Vulkan）
- **AOT (Ahead-of-Time) 硬件原生机器码预编译**：构建期集成 `intel-ocloc` + `libigc1`，直接指定 `-DGGML_SYCL_DEVICE_ARCH=adl-p` 针对 Alder Lake-P 核显生成原生机器指令，消除了 JIT 实时编译延迟；
- **全链路 FP16 矩阵计算**：强制开启 `-DGGML_SYCL_F16=ON`，在 96EU 核显上吞吐显著翻倍；
- **编译器极致优化**：指定 `-O3 -fsycl-unnamed-lambda`，开启 `GGML_SYCL_ENABLE_OPT=ON` 与 `GGML_SYCL_ENABLE_FUSION=ON` 算子融合；
- **动态后端符号链接直达**：在镜像内自动软链 `libggml*.so` 直达 `/usr/local/bin`，杜绝动态后端静默回退 CPU（`Available devices: (none)`）问题。

### 2. 上游 llama.cpp 最新 SYCL 特性同步
- **Grouped MoE XMX GEMM (#29245)**：大幅强化了混合专家模型（MoE）在 Intel 硬件上的矩阵乘法性能；
- **Pinned Ring Buffer Bulk Upload (#29608)**：模型载入与大张量传输阶段通过锁定内存环形缓冲区异步分阶段上传，显著缩减大模型预填充（PP）与载入延迟；
- **GLM MLA Prefill Flash Attention (#29171)**：加速 GLM 架构多头潜变量注意力（MLA）在 MKL 闪存注意力下的 Prefill 速度；
- **Fused Delta-Net Alpha Gate (#29687)** 与 **FWHT 算子调优 (#29605)**：端到端加速新架构模型的端侧推理效率。

### 3. Autocheck 多模型动态热插拔管控（`autocheck` 分支专属）
- **文件驱动自动化**：指定扫描目录（默认 `/models`），只要放入 `<model_name>.gguf` 与同名配置文件 `<model_name>.json`（或 `.yaml`），镜像自动拉起对应的 `llama-server` 进程；
- **多模型并行运行**：根据配置分配不同端口，单容器内多模型协同共用 SYCL 核显；
- **热重载与生命周期同步**：
  - 修改配置文件 -> 自动重启该模型实例，载入最新参数；
  - 删除模型或配置 -> 自动优雅停机（SIGTERM -> SIGKILL）释放显存与内存；
  - 进程意外退出 -> 自动检测并清理状态；
- **独立日志切分**：每个模型的运行日志自动定向存放在 `/logs/<model_name>.log`，主容器只打印调度与启停事件。

---

## 🚀 最佳硬件编译与运行参数推荐

经过在 Intel i7-12700H (Iris Xe 96EU) 上的反复梯度压测与基准测试，推荐以下黄金配置组合：

### 编译期黄金参数
```bash
-DGGML_SYCL=ON \
-DGGML_SYCL_F16=ON \
-DGGML_SYCL_DEVICE_ARCH=adl-p \
-DGGML_SYCL_ENABLE_OPT=ON \
-DGGML_SYCL_ENABLE_FUSION=ON \
-DGGML_SYCL_SUPPORT_LEVEL_ZERO_API=ON \
-DGGML_SYCL_DNN=ON \
-DCMAKE_CXX_FLAGS="-fsycl-unnamed-lambda -O3" \
-DCMAKE_C_FLAGS="-O3"
```

### 运行期环境变量（镜像已默认内置）
```bash
ONEAPI_DEVICE_SELECTOR=level_zero:0
ZES_ENABLE_SYSMAN=1
GGML_SYCL_FA_ONEDNN=0       # 禁用 OneDNN Flash Attention 避免死锁
GGML_SYCL_ENABLE_FUSION=1    # 开启核显算子融合
GGML_SYCL_ENABLE_OPT=1       # 开启 SYCL 优化管道
GGML_SYCL_DEV2DEV_MEMCPY=2   # 设备级内存拷贝策略
```

---

## 📦 部署与使用方案 (Docker Compose)

### 推荐部署：`autocheck` 自动多模型镜像

创建部署目录：
```text
/opt/llama-sycl/
├── docker-compose.yml
├── models/                     # 存放模型及同名配置
│   ├── qwen35b.gguf
│   ├── qwen35b.json            # qwen35b 的专属参数配置
│   ├── minicpm.gguf
│   └── minicpm.json            # minicpm 的专属参数配置
└── logs/                       # 存放每个模型的运行日志
    ├── qwen35b.log
    └── minicpm.log
```

#### 1. `docker-compose.yml`
```yaml
services:
  llama-sycl-autocheck:
    image: ghcr.io/qq859952722/llama-cpp-sycl-docker:autocheck
    container_name: llama-sycl-autocheck
    restart: unless-stopped
    devices:
      - /dev/dri:/dev/dri
    volumes:
      - ./models:/models
      - ./logs:/logs
    ports:
      - "8080:8080"
      - "8081:8081"
      - "8082:8082"
      - "8083:8083"
      - "8084:8084"
    environment:
      - ONEAPI_DEVICE_SELECTOR=level_zero:0
      - ZES_ENABLE_SYSMAN=1
      - SCAN_INTERVAL=5.0
      - BASE_PORT=8080
```

#### 2. 模型配置文件模板 (`<model_name>.json`)

在 `/models` 目录下创建与 `.gguf` **完全同名** 的 `.json` 文件即可：

##### 示例 1: `minicpm.json` (对应 `minicpm.gguf`)
```json
{
  "port": 8080,
  "ngl": 99,
  "ctx_size": 16384,
  "batch_size": 2048,
  "ubatch_size": 2048,
  "threads": 6,
  "reasoning_budget": 512,
  "alias": "minicpm5-2b"
}
```

##### 示例 2: `qwen35b.json` (对应 `qwen35b.gguf`)
```json
{
  "port": 8081,
  "ngl": 99,
  "ctx_size": 8192,
  "batch_size": 2048,
  "ubatch_size": 2048,
  "threads": 6,
  "cache_type_k": "q4_0",
  "cache_type_v": "q4_0",
  "ncmoe": 0,
  "alias": "qwen3.6-35b"
}
```

> **配置文件格式支持**：除了标准 JSON 外，也支持简单的 `key: value`（YAML/键值对格式）。未显式指定 `port` 时，管理器将自动从 `BASE_PORT`（默认 8080）依次递增分配。

---

## 🛠️ 设备检测命令

运行以下命令验证容器是否能够探测到核显/独显：

```bash
docker run --rm --device /dev/dri:/dev/dri \
  --entrypoint llama-cli ghcr.io/qq859952722/llama-cpp-sycl-docker:autocheck --list-devices
```

正常输出：
```text
found 1 SYCL devices:
| ID | Device Type        | Name                          | Driver version |
| 0  | [level_zero:gpu:0] | Intel(R) UHD/Iris Xe Graphics | 1.3.xxxxx      |
```
