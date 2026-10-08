ARG UBUNTU_VERSION=24.04

# ----------------- Stage 1: Build -----------------
FROM ubuntu:${UBUNTU_VERSION} AS builder

ARG LLAMA_CPP_BRANCH=master
ARG GGML_SYCL_F16=ON
ARG LEVEL_ZERO_VERSION=1.33.1
ARG LEVEL_ZERO_UBUNTU_VERSION=u24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    curl \
    gnupg \
    ca-certificates \
    git \
    cmake \
    ninja-build \
    build-essential \
    pkg-config \
    libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Intel oneAPI APT repository & DPC++ compiler + MKL
RUN wget -O- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB | gpg --dearmor -o /usr/share/keyrings/oneapi-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" > /etc/apt/sources.list.d/oneAPI.list && \
    apt-get update && apt-get install -y --no-install-recommends \
        intel-ocloc libigc1 \
        intel-oneapi-compiler-dpcpp-cpp \
        intel-oneapi-mkl-devel \
    && rm -rf /var/lib/apt/lists/*

# Install Level Zero SDK
RUN cd /tmp && \
    wget -q "https://github.com/oneapi-src/level-zero/releases/download/v${LEVEL_ZERO_VERSION}/libze1_${LEVEL_ZERO_VERSION}%2B${LEVEL_ZERO_UBUNTU_VERSION}_amd64.deb" -O libze1.deb || \
    wget -q "https://github.com/oneapi-src/level-zero/releases/download/v${LEVEL_ZERO_VERSION}/libze1_${LEVEL_ZERO_VERSION}+${LEVEL_ZERO_UBUNTU_VERSION}_amd64.deb" -O libze1.deb && \
    wget -q "https://github.com/oneapi-src/level-zero/releases/download/v${LEVEL_ZERO_VERSION}/libze-dev_${LEVEL_ZERO_VERSION}%2B${LEVEL_ZERO_UBUNTU_VERSION}_amd64.deb" -O libze-dev.deb || \
    wget -q "https://github.com/oneapi-src/level-zero/releases/download/v${LEVEL_ZERO_VERSION}/libze-dev_${LEVEL_ZERO_VERSION}+${LEVEL_ZERO_UBUNTU_VERSION}_amd64.deb" -O libze-dev.deb && \
    apt-get install -y --no-install-recommends ./libze1.deb ./libze-dev.deb && \
    rm -f /tmp/*.deb

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
        -DGGML_BACKEND_DL=ON \
        -DGGML_CPU_ALL_VARIANTS=ON \
        -DGGML_SYCL_F16=${GGML_SYCL_F16} \
        -DGGML_SYCL_DEVICE_ARCH=adl-p \
        -DGGML_SYCL_ENABLE_OPT=ON \
        -DGGML_SYCL_ENABLE_FUSION=ON \
        -DGGML_SYCL_SUPPORT_LEVEL_ZERO_API=ON \
        -DGGML_SYCL_DNN=ON \
        -DCMAKE_CXX_FLAGS="-fsycl-unnamed-lambda -O3" \
        -DCMAKE_C_FLAGS="-O3" \
        -DCMAKE_EXE_LINKER_FLAGS="-fsycl-unnamed-lambda" \
        -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=ON && \
    cmake --build build --config Release -j$(nproc) --target llama-server llama-cli'

RUN mkdir -p /app/dist/bin /app/dist/lib && \
    cp build/bin/llama-server /app/dist/bin/ && \
    cp build/bin/llama-cli /app/dist/bin/ && \
    find build -name "*.so*" -exec cp -P {} /app/dist/lib/ \; && \
    find /opt/intel/oneapi/compiler/latest/lib -name "*.so*" -exec cp -P {} /app/dist/lib/ \; 2>/dev/null || true && \
    find /opt/intel/oneapi/mkl/latest/lib -name "*.so*" -exec cp -P {} /app/dist/lib/ \; 2>/dev/null || true && \
    find /opt/intel/oneapi/tbb/latest/lib -name "*.so*" -exec cp -P {} /app/dist/lib/ \; 2>/dev/null || true && \
    find /opt/intel/oneapi -name "libumf.so*" -exec cp -P {} /app/dist/lib/ \; 2>/dev/null || true && \
    find /opt/intel/oneapi -name "libhwloc.so*" -exec cp -P {} /app/dist/lib/ \; 2>/dev/null || true

# ----------------- Stage 2: Runtime -----------------
FROM ubuntu:${UBUNTU_VERSION} AS runner

LABEL org.opencontainers.image.source="https://github.com/qq859952722/llama-cpp-sycl-docker"
LABEL org.opencontainers.image.description="llama.cpp with Intel SYCL/Level-Zero GPU acceleration & autocheck multi-model manager"

ENV DEBIAN_FRONTEND=noninteractive
ENV ONEAPI_DEVICE_SELECTOR=level_zero:0
ENV ZES_ENABLE_SYSMAN=1
ENV LD_LIBRARY_PATH=/app/lib:$LD_LIBRARY_PATH
# Intel Iris Xe iGPU 运行时黄金优化配置 (官方文档与实测验证)
ENV GGML_SYCL_FA_ONEDNN=0
ENV GGML_SYCL_ENABLE_FUSION=1
ENV GGML_SYCL_ENABLE_OPT=1
ENV GGML_SYCL_DEV2DEV_MEMCPY=2

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    curl \
    gnupg \
    ca-certificates \
    libcurl4 \
    libgomp1 \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Install Intel GPU compute runtime (Level Zero / OpenCL ICD drivers)
RUN wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | gpg --dearmor --output /usr/share/keyrings/intel-graphics.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu noble client" > /etc/apt/sources.list.d/intel-gpu.list && \
    apt-get update && apt-get install -y --no-install-recommends \
        intel-opencl-icd \
        intel-level-zero-gpu \
        level-zero \
        libze1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app/dist/bin/ /usr/local/bin/
COPY --from=builder /app/dist/lib/ /app/lib/

# 确保动态后端符号链接直达可执行文件目录，解决 (none) 设备退化
RUN ln -sf /app/lib/libggml*.so /usr/local/bin/

ENV GGML_BACKEND_DIR=/app/lib
ENV GGML_BACKEND_SEARCH_PATH=/app/lib

RUN ldconfig

# 安装 autocheck 多模型动态热加载管理器
COPY autocheck_manager.py /usr/local/bin/autocheck-manager
RUN chmod +x /usr/local/bin/autocheck-manager

WORKDIR /models
VOLUME ["/models", "/logs"]
EXPOSE 8080-8099

ENTRYPOINT ["autocheck-manager"]
