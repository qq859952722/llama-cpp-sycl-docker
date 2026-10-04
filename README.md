# llama.cpp SYCL Docker for Intel iGPU / Arc

[![Build and Publish SYCL Docker Image](https://github.com/qq859952722/llama-cpp-sycl-docker/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/qq859952722/llama-cpp-sycl-docker/actions/workflows/docker-publish.yml)

本项目提供针对 **Intel 12代 (Alder Lake 12700H) 核显 (Iris Xe 96EU)** 及 Intel Arc 系列独立显卡的 `llama.cpp` SYCL 容器化镜像构建方案，并通过 GitHub Actions 自动编译发布至 GitHub Packages (GHCR)。

---

## 硬件与环境要求

- **CPU / GPU**：Intel Core i7-12700H (Intel Iris Xe Graphics 96EU) 或 Intel Arc 显卡
- **宿主机环境**：
  - Linux 内核需支持 i915 或 xe 驱动
  - 宿主机存在 `/dev/dri/renderD128` 和 `/dev/dri/card0` 设备节点
  - Docker & Docker Compose

---

## 快速使用

### 1. 启动推理服务 (Docker Compose)

创建 `docker-compose.yml`（或直接使用本仓库自带的）：

```yaml
services:
  llama-sycl:
    image: ghcr.io/qq859952722/llama-cpp-sycl-docker:latest
    container_name: llama-sycl
    restart: unless-stopped
    devices:
      - /dev/dri:/dev/dri
    volumes:
      - ./models:/models
    ports:
      - "8080:8080"
    environment:
      - ONEAPI_DEVICE_SELECTOR=level_zero:0
      - ZES_ENABLE_SYSMAN=1
      - LD_LIBRARY_PATH=/app/lib
      - GGML_BACKEND_DIR=/app/lib
      - GGML_BACKEND_SEARCH_PATH=/app/lib
    # ggml 在可执行文件同目录或 cwd 中查找动态后端，二者任一即可
    working_dir: /app/lib
    entrypoint: ["sh", "-c", "ln -sf /app/lib/libggml*.so /usr/local/bin/ 2>/dev/null || true; exec llama-server \"$@\"", "--"]
    command:
      - "--host"
      - "0.0.0.0"
      - "--port"
      - "8080"
      - "-m"
      - "/models/your-model.gguf"
      - "-ngl"
      - "99"
```

拉取并启动：

```bash
docker compose pull
docker compose up -d
```

### 2. 检查 SYCL 设备识别情况

> **重要修复说明（2026-10-04）**
>
> 早期镜像存在**动态后端发现（backend discovery）缺陷**：`llama-cli --list-devices` 会输出
>
> ```text
> Available devices:
>   (none)
> ```
>
> 导致容器**静默回退到纯 CPU 推理**，核显完全不参与，表现为生成极慢、GPU 占用为 0。
>
> **根因**：构建启用了 `-DGGML_BACKEND_DL=ON`，动态后端 `libggml-sycl.so` / `libggml-cpu-*.so` 被安装到 `/app/lib`，但可执行文件位于 `/usr/local/bin`。ggml 只在**可执行文件同目录**或**当前工作目录**中查找后端。
>
> **实测对照（Intel i7-12700H / Iris Xe 96EU）**：
>
> | 修复方式 | `--list-devices` 结果 |
> |---|---|
> | 未修复（默认） | `(none)` ❌ |
> | 仅 `GGML_BACKEND_DIR=/app/lib` | `(none)` ❌ |
> | 仅 `GGML_BACKEND_SEARCH_PATH=/app/lib` | `(none)` ❌ |
> | 两个环境变量同时设置 | `(none)` ❌ |
> | 软链到 `/usr/local/lib` + `ldconfig` | `(none)` ❌ |
> | **软链到 `/usr/local/bin`（二进制同目录）** | **`SYCL0: Intel(R) Iris(R) Xe Graphics`** ✅ |
> | **`WORKDIR /app/lib`（后端在 cwd）** | **`SYCL0: Intel(R) Iris(R) Xe Graphics`** ✅ |
>
> 当前镜像已在 Dockerfile 中内置 `ln -sf /app/lib/libggml*.so /usr/local/bin/`，无需额外配置。
> 如使用旧镜像，可在 `docker-compose.yml` 中通过 `working_dir` + 自定义 `entrypoint` 临时规避（见下方示例）。


运行以下命令验证容器是否能够探测到 12700H 的核显：

```bash
docker run --rm --device /dev/dri:/dev/dri \
  --entrypoint llama-cli ghcr.io/qq859952722/llama-cpp-sycl-docker:latest --list-devices
```

> 注：镜像只构建了 `llama-server` 与 `llama-cli`，旧文档中的 `llama-ls-sycl-device` 并不存在，会报 `executable file not found`。

若输出 `(none)`，说明动态后端未被发现（参见上方「重要修复说明」）。

正常输出示例：
```text
found 1 SYCL devices:
| ID | Device Type        | Name                      | Driver version |
| 0  | [level_zero:gpu:0] | Intel(R) UHD/Iris Xe Graphics | 1.3.xxxxx      |
```

### 3. 本地手动构建镜像

如需在本地根据特定分支或编译选项自定义构建：

```bash
docker build -t llama-cpp-sycl:latest \
  --build-arg ONEAPI_VERSION=2025.1.0-devel-ubuntu24.04 \
  --build-arg LLAMA_CPP_BRANCH=master \
  --build-arg GGML_SYCL_F16=OFF \
  .
```

---

## GitHub Actions 自动构建与发布

本仓库已配置 CI/CD 流程（`.github/workflows/docker-publish.yml`）：
- 触发分支：`main` 分支 push / PR / tag 发布 / 手动 `workflow_dispatch`。
- 自动化：构建多阶段镜像并推送至 `ghcr.io/qq859952722/llama-cpp-sycl-docker:latest`。
- 自动清理 Runner 磁盘空间（避免 oneAPI 大镜像导致磁盘耗尽），使用 GitHub Actions Cache 加速后续构建。
