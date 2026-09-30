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

运行以下命令验证容器是否能够探测到 12700H 的核显：

```bash
docker run --rm --device /dev/dri:/dev/dri ghcr.io/qq859952722/llama-cpp-sycl-docker:latest llama-ls-sycl-device
```

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
