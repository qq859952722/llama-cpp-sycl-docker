ARG ONEAPI_VERSION=2025.1.0-devel-ubuntu24.04

# ----------------- Stage 1: Build -----------------
FROM docker.io/intel/oneapi-basekit:${ONEAPI_VERSION} AS builder

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
    libcurl4-openssl-dev \
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
        -DGGML_BACKEND_DL=ON \
        -DGGML_CPU_ALL_VARIANTS=ON \
        -DGGML_SYCL_F16=${GGML_SYCL_F16} \
        -DLLAMA_BUILD_TESTS=OFF && \
    cmake --build build --config Release -j$(nproc) --target llama-server llama-cli llama-ls-sycl-device'

RUN mkdir -p /app/dist/bin /app/dist/lib && \
    cp build/bin/llama-server /app/dist/bin/ && \
    cp build/bin/llama-cli /app/dist/bin/ && \
    cp build/bin/llama-ls-sycl-device /app/dist/bin/ && \
    find build -name "*.so*" -exec cp -P {} /app/dist/lib/ \;

# ----------------- Stage 2: Runtime -----------------
FROM docker.io/intel/oneapi-basekit:${ONEAPI_VERSION} AS runner

LABEL org.opencontainers.image.source="https://github.com/qq859952722/llama-cpp-sycl-docker"
LABEL org.opencontainers.image.description="llama.cpp with Intel SYCL/Level-Zero GPU acceleration"

ENV DEBIAN_FRONTEND=noninteractive
ENV LLAMA_ARG_HOST=0.0.0.0
ENV ONEAPI_DEVICE_SELECTOR=level_zero:0
ENV ZES_ENABLE_SYSMAN=1
ENV LD_LIBRARY_PATH=/app/lib:$LD_LIBRARY_PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    libcurl4 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app/dist/bin/ /usr/local/bin/
COPY --from=builder /app/dist/lib/ /app/lib/

WORKDIR /models
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

ENTRYPOINT ["llama-server"]
CMD ["--host", "0.0.0.0", "--port", "8080"]
