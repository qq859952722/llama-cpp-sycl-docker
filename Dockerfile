# Multi-stage Dockerfile for llama.cpp with Intel SYCL / oneAPI acceleration
# Optimized for Intel Alder Lake iGPU (12700H Iris Xe) and Arc GPUs

ARG ONEAPI_VERSION=2025.1.0-devel-ubuntu24.04
ARG RUNTIME_BASE=ubuntu:24.04

# ----------------- Stage 1: Build -----------------
FROM intel/oneapi-basekit:${ONEAPI_VERSION} AS builder

ARG LLAMA_CPP_BRANCH=master
ARG GGML_SYCL_F16=OFF

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    cmake \
    ninja-build \
    build-essential \
    pkg-config \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN git clone --depth 1 --branch ${LLAMA_CPP_BRANCH} https://github.com/ggml-org/llama.cpp.git .

RUN bash -c 'source /opt/intel/oneapi/setvars.sh && \
    cmake -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_SYCL=ON \
        -DCMAKE_C_COMPILER=icx \
        -DCMAKE_CXX_COMPILER=icpx \
        -DGGML_NATIVE=OFF \
        -DLLAMA_OPENSSL=OFF \
        -DLLAMA_CURL=ON \
        -DGGML_SYCL_F16=${GGML_SYCL_F16} \
        -DBUILD_SHARED_LIBS=OFF && \
    cmake --build build --config Release -j$(nproc) --target llama-server llama-cli llama-ls-sycl-device'

# ----------------- Stage 2: Minimal Runtime -----------------
FROM ${RUNTIME_BASE} AS runner

ENV DEBIAN_FRONTEND=noninteractive

# Install Intel GPU compute runtime & level zero drivers
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    libgomp1 \
    && curl -fsSL https://repositories.intel.com/gpu/intel-graphics.key | gpg --dearmor -o /etc/apt/keyrings/intel-gpu.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/intel-gpu.gpg] https://repositories.intel.com/gpu/ubuntu noble client" > /etc/apt/sources.list.d/intel-gpu.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        intel-opencl-icd \
        intel-level-zero-gpu \
        level-zero \
        libze1 \
    && rm -rf /var/lib/apt/lists/*

# Copy SYCL runtime libraries from builder
COPY --from=builder /opt/intel/oneapi/compiler/latest/lib/libsycl.so* /usr/local/lib/
COPY --from=builder /opt/intel/oneapi/compiler/latest/lib/libur_adapter_level_zero.so* /usr/local/lib/
COPY --from=builder /opt/intel/oneapi/compiler/latest/lib/libpi_level_zero.so* /usr/local/lib/

# Copy binaries
COPY --from=builder /app/build/bin/llama-server /usr/local/bin/
COPY --from=builder /app/build/bin/llama-cli /usr/local/bin/
COPY --from=builder /app/build/bin/llama-ls-sycl-device /usr/local/bin/

RUN ldconfig

# Default device: level-zero 0 (iGPU)
ENV ONEAPI_DEVICE_SELECTOR=level_zero:0
ENV ZES_ENABLE_SYSMAN=1

WORKDIR /models
EXPOSE 8080

ENTRYPOINT ["llama-server"]
CMD ["--host", "0.0.0.0", "--port", "8080"]
