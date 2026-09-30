# llama.cpp SYCL Docker for Intel iGPU / Arc

本项目提供针对 **Intel 12代 (Alder Lake 12700H) 核显 (Iris Xe)** 及 Intel Arc 独立显卡的 `llama.cpp` SYCL 容器化镜像构建方案。

采用 **多阶段构建 (Multi-stage build)**：
1. **构建阶段 (Builder)**：基于 Intel oneAPI 官方镜像编译 SYCL/Level-Zero 加速后端。
2. **运行阶段 (Runner)**：仅提取最小运行时依赖（`libsycl.so`、Level Zero 驱动支持库），镜像体积远小于全量 oneAPI SDK，无需宿主机安装庞大工具链。

---

## 硬件与环境要求

- **CPU/核显**：Intel Core i7-12700H (Intel Iris Xe Graphics 96EU) 或 Intel Arc 显卡
- **宿主机环境**：
  - Linux 内核需支持 i915 / xe
  - 宿主机存在 `/dev/dri/renderD128` 和 `/dev/dri/card0` 设备节点
  - Docker / Docker Compose

---

## 快速使用

### 1. 构建镜像

```bash
docker compose build
```

或使用原生 docker build：

```bash
docker build -t llama-cpp-sycl:latest .
```

### 2. 查看 SYCL 设备识别情况

```bash
docker run --rm --device /dev/dri:/dev/dri llama-cpp-sycl:latest llama-ls-sycl-device
```

### 3. 运行推理服务 (llama-server)

启动自带的 Web UI 及 OpenAI 兼容 API：

```bash
docker run -d \
  --name llama-sycl \
  --restart unless-stopped \
  --device /dev/dri:/dev/dri \
  -v $(pwd)/models:/models \
  -p 8080:8080 \
  -e ONEAPI_DEVICE_SELECTOR=level_zero:0 \
  llama-cpp-sycl:latest \
  --host 0.0.0.0 --port 8080 \
  -m /models/your-model.gguf \
  -ngl 99
```

或直接修改 `docker-compose.yml` 中的模型挂载路径后启动：

```bash
docker compose up -d
```

---

## 常用环境变量说明

| 变量名 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `ONEAPI_DEVICE_SELECTOR` | `level_zero:0` | 指定使用哪个 GPU 设备，默认选择第一张 Level-Zero 支持的设备（核显） |
| `ZES_ENABLE_SYSMAN` | `1` | 开启 Intel Level-Zero Sysman 遥测接口 |
| `GGML_SYCL_F16` | `OFF` | 编译期参数，核显推荐保持 OFF（FP32）；长 prompt 推理若追求吞吐可切 ON |
